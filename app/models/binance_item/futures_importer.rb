# frozen_string_literal: true

# Pulls USDⓈ-M futures account data: per-asset wallet balance, unrealized
# P&L, margin balance and available balance, and the open positions.
# Returns normalized asset list with source tag "futures".
#
# Each asset's quantity is its margin balance (equity). Positions are
# reported separately, never as assets — see BinanceItem::FuturesWallet.
class BinanceItem::FuturesImporter
  include BinanceItem::FuturesWallet

  MARKET = "usds_m"
  QUOTE_SUFFIXES = %w[USDT USDC BUSD FDUSD BTC].freeze

  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  # @return [Hash] { assets: [...], raw: <api_response>, source: "futures",
  #   market: "usds_m", positions: [...] or nil when unknown, summary: {...} }
  def import
    raw = provider.get_futures_account
    assets = normalize_wallet_assets(raw["assets"])
    positions = fetch_positions { normalize_positions(provider.get_futures_position_risk) }

    {
      assets: assets, raw: raw, source: "futures", market: MARKET,
      positions: positions, summary: summarize(assets, positions)
    }
  rescue => e
    Rails.logger.error "BinanceItem::FuturesImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "futures", market: MARKET, error: e.message, error_class: e.class.name }
  end

  private

    # Quantities are in the base asset (no contract multiplier); prices,
    # notional and P&L are in the symbol's margin (quote) asset.
    def normalize_positions(rows)
      Array(rows).filter_map do |row|
        quantity = row["positionAmt"].to_d
        next if quantity.zero?

        quote = row["marginAsset"].presence || QUOTE_SUFFIXES.find { |suffix| row["symbol"].to_s.end_with?(suffix) }

        {
          symbol: row["symbol"],
          position_side: row["positionSide"].presence || "BOTH",
          # Dated USDⓈ-M contracts carry their delivery date: BTCUSDT_261225.
          contract_type: row["symbol"].to_s.include?("_") ? "DELIVERY" : "PERPETUAL",
          quantity: quantity,
          quantity_unit: "base",
          contract_size: nil,
          contract_size_currency: nil,
          margin_asset: quote,
          margin_type: row["marginType"].presence || (row["isolatedMargin"].to_d.zero? ? "cross" : "isolated"),
          entry_price: optional_decimal(row["entryPrice"]),
          break_even_price: optional_decimal(row["breakEvenPrice"]),
          mark_price: optional_decimal(row["markPrice"]),
          liquidation_price: optional_decimal(row["liquidationPrice"]),
          price_currency: quote,
          notional: optional_decimal(row["notional"]),
          notional_currency: quote,
          unrealized_pnl: optional_decimal(row["unRealizedProfit"]),
          unrealized_pnl_currency: quote,
          isolated_margin: optional_decimal(row["isolatedMargin"]),
          leverage: optional_decimal(row["leverage"]),
          provider_updated_at: provider_time(row["updateTime"]),
          raw_payload: row
        }
      end
    end
end
