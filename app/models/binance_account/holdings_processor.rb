# frozen_string_literal: true

# Creates/updates Holdings for each asset in the combined BinanceAccount.
# One Holding per symbol, summed across the wallets that hold it.
#
# Sure keeps one holding per security and day, so BTC in Spot and BTC as
# COIN-M collateral cannot be two rows: written one after the other, the
# second replaced the first and the account showed only part of its BTC (the
# balance stayed right, the difference surfacing as cash). The quantity is
# the sum; which wallets contributed is kept in the external id.
class BinanceAccount::HoldingsProcessor
  include BinanceAccount::UsdConverter

  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    unless account&.accountable_type == "Crypto"
      Rails.logger.info "BinanceAccount::HoldingsProcessor - skipping: not a Crypto account"
      return
    end

    assets = raw_assets
    if assets.nil?
      # No asset list at all is not an empty wallet, it is a wallet nothing has
      # reported on yet. Cleaning up here would delete holdings on the strength
      # of missing information.
      Rails.logger.info "BinanceAccount::HoldingsProcessor - no asset list in payload"
      return
    end

    positions = aggregate(assets)
    positions.each { |position| process_asset(position) }
    cleanup_stale_holdings!(positions)
  rescue StandardError => e
    Rails.logger.error "BinanceAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :binance_account

    def target_currency
      binance_account.binance_item.family.currency
    end

    def account
      binance_account.current_account
    end

    # nil when the payload has never carried an asset list, [] when Binance
    # reported an empty wallet. The two mean different things to the cleanup.
    def raw_assets
      binance_account.raw_payload&.dig("assets")
    end

    # Binance reports what the wallet holds NOW, so a holding written for today
    # whose asset is no longer in the payload is one that has left the wallet.
    # Nothing removed them before, and the account page reads exactly today's
    # rows — so a coin sold hours ago was still in the portfolio.
    #
    # Keyed on what the PAYLOAD contains, not on what was successfully
    # imported: an asset whose price could not be fetched is skipped above, and
    # deleting it would turn a price outage into a disappeared holding.
    def cleanup_stale_holdings!(positions)
      provider_id = binance_account.account_provider&.id
      return if provider_id.nil?

      keep = positions.filter_map { |position| external_id_for(position) }
      scope = account.holdings.where(account_provider_id: provider_id, date: Date.current)
      scope = scope.where.not(external_id: keep) if keep.any?

      removed = scope.delete_all
      Rails.logger.info "BinanceAccount::HoldingsProcessor - removed #{removed} holding(s) no longer in the wallet" if removed.positive?
    end

    # { "symbol", "total", "sources" } per symbol. A symbol held in one
    # wallet keeps the external id it always had.
    def aggregate(assets)
      assets.group_by { |asset| asset["symbol"] || asset[:symbol] }.filter_map do |symbol, rows|
        next if symbol.blank?

        sources = rows.map { |row| (row["source"] || row[:source]).to_s }.uniq
        sources.sort_by! { |source| BinanceItem::Importer::SOURCES.index(source) || BinanceItem::Importer::SOURCES.size }

        {
          "symbol" => symbol,
          "total" => rows.sum { |row| (row["total"] || row[:total]).to_d }.to_s("F"),
          "sources" => sources
        }
      end
    end

    def external_id_for(position)
      return if position["symbol"].blank?
      return if position["total"].to_d.zero?

      holding_external_id(position["symbol"], position["sources"])
    end

    def holding_external_id(symbol, sources)
      "binance_#{symbol}_#{Array(sources).join('+')}_#{Date.current}"
    end

    def process_asset(asset)
      symbol = asset["symbol"]
      return if symbol.blank?

      total   = asset["total"].to_d
      sources = asset["sources"]

      return if total.zero?

      ticker   = symbol.include?(":") ? symbol : "CRYPTO:#{symbol}"
      security = resolve_security(ticker, symbol)
      return unless security

      price_usd = fetch_price(symbol)
      return if price_usd.nil?

      amount_usd = total * price_usd

      # Stale rate metadata is intentionally discarded here — it is captured and
      # surfaced at the account level by BinanceAccount::Processor#process_account!.
      amount, _stale, _rate_date = convert_from_usd(amount_usd, date: Date.current)

      # Also convert per-unit price to target currency
      price, _, _ = convert_from_usd(price_usd, date: Date.current)

      import_adapter.import_holding(
        security:               security,
        quantity:               total,
        amount:                 amount,
        currency:               target_currency,
        date:                   Date.current,
        price:                  price,
        cost_basis:             nil,
        external_id:            holding_external_id(symbol, sources),
        account_provider_id:    binance_account.account_provider&.id,
        source:                 "binance",
        delete_future_holdings: false
      )

      Rails.logger.info "BinanceAccount::HoldingsProcessor - imported #{total} #{symbol} (#{sources.join('+')}) @ #{price_usd} USD → #{amount} #{target_currency}"
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::HoldingsProcessor - failed asset #{asset}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(ticker, symbol)
      BinanceAccount::SecurityResolver.resolve(ticker, symbol)
    end

    def fetch_price(symbol)
      return 1.0 if BinanceAccount::STABLECOINS.include?(symbol)

      provider = binance_account.binance_item&.binance_provider
      return nil unless provider

      %w[USDT BUSD FDUSD].each do |quote|
        price_str = provider.get_spot_price("#{symbol}#{quote}")
        return price_str.to_d if price_str.present?
      end

      Rails.logger.warn "BinanceAccount::HoldingsProcessor - no price found for #{symbol} across all quote pairs; skipping holding"
      nil
    end
end
