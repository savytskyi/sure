# frozen_string_literal: true

# Shared normalization for Binance's two futures wallets (USDⓈ-M and COIN-M).
#
# Four figures are kept apart for every margin asset, because they answer
# different questions:
#
#   wallet_balance     deposits, transfers, realized P&L, funding and fees
#   margin_balance     wallet_balance + unrealized P&L: what the wallet is
#                      worth if every position closed at the mark price
#   available_balance  what could be used for new margin or moved out
#   unrealized_pnl     the open positions' paper result, in the margin asset
#
# The asset's quantity on the combined account is margin_balance, the owner's
# equity. A position's notional value is exposure, not an asset, and is never
# added: the position's whole worth to its owner is its unrealized P&L, which
# margin_balance already contains.
module BinanceItem::FuturesWallet
  private

    def normalize_wallet_assets(raw_assets)
      Array(raw_assets).filter_map do |asset|
        wallet = asset["walletBalance"].to_d
        unrealized = (asset["unrealizedProfit"] || asset["crossUnPnl"]).to_d
        margin = asset["marginBalance"].present? ? asset["marginBalance"].to_d : wallet + unrealized
        next if wallet.zero? && unrealized.zero? && margin.zero?

        available = asset["availableBalance"].present? ? asset["availableBalance"].to_d : wallet

        {
          symbol: asset["asset"],
          free: decimal_string(available),
          locked: decimal_string(wallet - available),
          total: decimal_string(margin),
          wallet_balance: decimal_string(wallet),
          unrealized_pnl: decimal_string(unrealized),
          margin_balance: decimal_string(margin),
          available_balance: decimal_string(available),
          maint_margin: decimal_string(asset["maintMargin"].to_d)
        }
      end
    end

    def decimal_string(value)
      value.to_d.to_s("F")
    end

    def optional_decimal(value)
      value.present? ? value.to_d : nil
    end

    def provider_time(ms)
      ms.to_i.positive? ? Time.zone.at(ms.to_i / 1000.0) : nil
    end

    # A failed position read must not look like "no positions": that would
    # close every open episode. nil means unknown.
    def fetch_positions
      yield
    rescue StandardError => e
      @position_error = e.message
      Rails.logger.warn "#{self.class.name} #{binance_item.id} - positions unavailable: #{e.message}"
      nil
    end

    def summarize(assets, positions)
      {
        "assets" => assets.to_h do |asset|
          [ asset[:symbol], asset.slice(:wallet_balance, :unrealized_pnl, :margin_balance, :available_balance, :maint_margin).stringify_keys ]
        end,
        "open_positions" => positions&.size,
        "notional" => positions&.group_by { |p| p[:notional_currency] }&.transform_values { |rows| decimal_string(rows.sum { |p| p[:notional].to_d.abs }) },
        "positions_error" => @position_error
      }.compact
    end
end
