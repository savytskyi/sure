# frozen_string_literal: true

# Pulls COIN-M futures account data: coin-margined wallets (BTC, ETH, ...)
# with their unrealized P&L, and the open contract positions.
# Returns normalized asset list with source tag "coin_futures".
#
# Everything here is denominated in the margin coin: a BTC wallet's balance
# and unrealized P&L are BTC, and are valued like any other BTC the account
# holds. A position is a number of contracts, each worth contractSize USD of
# the underlying (100 for BTC, 10 for most others), read from exchangeInfo.
class BinanceItem::CoinFuturesImporter
  include BinanceItem::FuturesWallet

  MARKET = "coin_m"

  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  # @return [Hash] { assets: [...], raw: <api_response>, source: "coin_futures",
  #   market: "coin_m", positions: [...] or nil when unknown, summary: {...} }
  def import
    raw = provider.get_coin_futures_account
    assets = normalize_wallet_assets(raw["assets"])
    positions = fetch_positions { normalize_positions(provider.get_coin_futures_position_risk) }

    {
      assets: assets, raw: raw, source: "coin_futures", market: MARKET,
      positions: positions, summary: summarize(assets, positions)
    }
  rescue => e
    Rails.logger.error "BinanceItem::CoinFuturesImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "coin_futures", market: MARKET, error: e.message, error_class: e.class.name }
  end

  private

    def normalize_positions(rows)
      open_rows = Array(rows).reject { |row| row["positionAmt"].to_d.zero? }
      return [] if open_rows.empty?

      contracts = contract_specs

      open_rows.map do |row|
        spec = contracts[row["symbol"]] || {}
        margin_asset = spec["marginAsset"].presence || row["symbol"].to_s[/\A[A-Z0-9]+?(?=USD)/]

        {
          symbol: row["symbol"],
          position_side: row["positionSide"].presence || "BOTH",
          contract_type: spec["contractType"].presence || (row["symbol"].to_s.end_with?("_PERP") ? "PERPETUAL" : "DELIVERY"),
          quantity: row["positionAmt"].to_d,
          quantity_unit: "contracts",
          contract_size: optional_decimal(spec["contractSize"]),
          contract_size_currency: spec["quoteAsset"].presence || "USD",
          margin_asset: margin_asset,
          margin_type: row["marginType"].presence,
          entry_price: optional_decimal(row["entryPrice"]),
          break_even_price: optional_decimal(row["breakEvenPrice"]),
          mark_price: optional_decimal(row["markPrice"]),
          liquidation_price: optional_decimal(row["liquidationPrice"]),
          price_currency: spec["quoteAsset"].presence || "USD",
          # Binance states the notional of a COIN-M position in the coin.
          notional: optional_decimal(row["notionalValue"]),
          notional_currency: margin_asset,
          unrealized_pnl: optional_decimal(row["unRealizedProfit"]),
          unrealized_pnl_currency: margin_asset,
          isolated_margin: optional_decimal(row["isolatedMargin"]),
          leverage: optional_decimal(row["leverage"]),
          provider_updated_at: provider_time(row["updateTime"]),
          raw_payload: row.merge("contract" => spec.slice("contractSize", "contractType", "deliveryDate", "marginAsset", "quoteAsset"))
        }
      end
    end

    # A missing spec only loses the multiplier, so it is not worth failing
    # the position read over.
    def contract_specs
      Array(provider.get_coin_futures_exchange_info&.dig("symbols")).index_by { |symbol| symbol["symbol"] }
    rescue StandardError => e
      Rails.logger.warn "BinanceItem::CoinFuturesImporter #{binance_item.id} - exchangeInfo unavailable: #{e.message}"
      {}
    end
end
