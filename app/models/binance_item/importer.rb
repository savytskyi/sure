# frozen_string_literal: true

# Orchestrates all Binance sub-importers and upserts a single combined BinanceAccount.
class BinanceItem::Importer
  # Every sub-importer swallows its own error and answers with an empty asset
  # list, so "the wallet is empty" and "nothing could be fetched" arrive here
  # looking identical. Raising on the second keeps the sync honest instead of
  # reporting a successful import of nothing.
  class AllRequestsFailed < StandardError; end

  SOURCES = %w[spot margin earn futures coin_futures].freeze
  FUTURE_MARKETS = { "futures" => "usds_m", "coin_futures" => "coin_m" }.freeze

  attr_reader :binance_item, :binance_provider

  def initialize(binance_item, binance_provider:)
    @binance_item = binance_item
    @binance_provider = binance_provider
  end

  def import
    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - starting import"

    spot_result   = BinanceItem::SpotImporter.new(binance_item, provider: binance_provider).import
    margin_result = BinanceItem::MarginImporter.new(binance_item, provider: binance_provider).import
    earn_result   = BinanceItem::EarnImporter.new(binance_item, provider: binance_provider).import
    futures_result = BinanceItem::FuturesImporter.new(binance_item, provider: binance_provider).import
    coin_futures_result = BinanceItem::CoinFuturesImporter.new(binance_item, provider: binance_provider).import

    results = [ spot_result, margin_result, earn_result, futures_result, coin_futures_result ]
    all_assets = results.flat_map { |result| tagged_assets(result) }

    if results.all? { |result| result[:error].present? }
      raise AllRequestsFailed, results.filter_map { |result| result[:error] }.uniq.join("; ")
    end

    # A source that failed tells us nothing about what it holds, and the
    # holdings processor removes anything missing from this list. Writing only
    # the sources that answered would therefore delete live positions on a
    # transient error or a permission-scoped key. Their last known assets are
    # carried instead: stale until the source answers again, which beats gone.
    all_assets += carried_over_assets(results)

    # An emptied wallet still has to be written down. Returning here left the
    # previous payload in place, and the holdings processor reads that payload —
    # so assets already sold were re-imported as today's holdings on every sync
    # and never went away. Only skipped when there is nothing to correct yet.
    if all_assets.empty? && binance_item.binance_accounts.find_by(account_type: "combined").nil?
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = calculate_total_usd(all_assets)

    binance_account = upsert_binance_account(
      all_assets: all_assets,
      total_usd: total_usd,
      spot_raw: spot_result[:raw],
      margin_raw: margin_result[:raw],
      earn_raw: earn_result[:raw],
      futures_raw: futures_result[:raw],
      coin_futures_raw: coin_futures_result[:raw],
      futures_results: [ futures_result, coin_futures_result ]
    )

    reconcile_positions(binance_account, [ futures_result, coin_futures_result ])

    binance_item.upsert_binance_snapshot!({
      "spot" => spot_result[:raw],
      "margin" => margin_result[:raw],
      "earn" => earn_result[:raw],
      "futures" => futures_result[:raw],
      "coin_futures" => coin_futures_result[:raw],
      "wallet_overview" => fetch_optional { binance_provider.get_wallet_balances },
      "api_restrictions" => fetch_optional { binance_provider.get_api_restrictions },
      "imported_at" => Time.current.iso8601
    })

    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - imported #{all_assets.size} assets, total_usd=#{total_usd}"

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    # Reference data for checking the import (Binance's own per-wallet
    # valuation, the key's permissions). Never a reason to fail the sync.
    def fetch_optional
      yield
    rescue StandardError => e
      Rails.logger.info "BinanceItem::Importer #{binance_item.id} - optional request failed: #{e.message}"
      { "error" => e.message }
    end

    # Only a market whose positions were read in full may close episodes.
    def reconcile_positions(binance_account, results)
      results.each do |result|
        next if result[:error].present? || result[:positions].nil?

        DerivativePosition.reconcile!(
          item: binance_item, provider_key: "binance", market: market_of(result),
          reported: result[:positions], provider_account: binance_account,
          account: binance_account.current_account
        )
      end
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Binance futures positions could not be stored",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        metadata: { binance_item_id: binance_item.id, error_class: e.class.name, error: e.message }
      )
    end

    def tagged_assets(result)
      result[:assets].map { |a| a.merge(source: result[:source]) }
    end

    def carried_over_assets(results)
      failed = results.select { |result| result[:error].present? }
      return [] if failed.empty?

      # A partial failure returns normally, so it never reaches the rescue in
      # BinanceItem#import_latest_binance_data. Without this the only trace is
      # an application log line, and support has nothing against the connection
      # saying part of the wallet went unread.
      record_partial_failure(failed)

      sources = failed.map { |result| result[:source] }
      previous = binance_item.binance_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets")
      return [] if previous.blank?

      carried = previous
        .map(&:deep_symbolize_keys)
        .select { |asset| sources.include?(asset[:source]) }

      if carried.any?
        Rails.logger.warn(
          "BinanceItem::Importer #{binance_item.id} - carrying #{carried.size} asset(s) " \
          "from unavailable source(s): #{sources.join(', ')}"
        )
      end

      carried
    end

    def record_partial_failure(failed)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Binance import read only part of the wallet",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        metadata: {
          binance_item_id: binance_item.id,
          unavailable_sources: failed.map { |result| result[:source] },
          errors: failed.to_h { |result| [ result[:source], result[:error] ] }
        }
      )
    end

    def calculate_total_usd(assets)
      assets.sum do |asset|
        quantity = asset[:total].to_d
        next 0 if quantity.zero?

        price = price_for(asset[:symbol])
        quantity * price
      end.round(2)
    end

    def price_for(symbol)
      return 1.0 if BinanceAccount::STABLECOINS.include?(symbol)

      price = binance_provider.get_spot_price("#{symbol}USDT")
      price.to_d
    rescue => e
      Rails.logger.warn "BinanceItem::Importer - could not get price for #{symbol}: #{e.message}"
      0
    end

    def upsert_binance_account(all_assets:, total_usd:, spot_raw:, margin_raw:, earn_raw:, futures_raw:, coin_futures_raw:, futures_results:)
      ba = binance_item.binance_accounts.find_or_initialize_by(account_type: "combined")
      previous_futures = ba.raw_payload&.dig("futures_summary") || {}

      ba.assign_attributes(
        name: binance_item.institution_name.presence || "Binance",
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: build_institution_metadata(all_assets),
        raw_payload: {
          "spot" => spot_raw,
          "margin" => margin_raw,
          "earn" => earn_raw,
          "futures" => futures_raw,
          "coin_futures" => coin_futures_raw,
          "futures_summary" => futures_summary(futures_results, previous_futures),
          "assets" => all_assets.map(&:stringify_keys),
          "fetched_at" => Time.current.iso8601
        }
      )

      ba.save!
      ba
    end

    # Wallet, equity, available margin, unrealized P&L and notional exposure
    # per futures market, kept apart from the asset list so none of them is
    # mistaken for a balance. A market that did not answer keeps its last
    # summary, marked stale.
    def futures_summary(results, previous)
      results.to_h do |result|
        summary = if result[:error].present?
          (previous[market_of(result)] || {}).merge("stale" => true, "error" => result[:error], "error_class" => result[:error_class])
        else
          (result[:summary] || {}).merge("read_at" => Time.current.iso8601)
        end

        [ market_of(result), summary ]
      end
    end

    def market_of(result)
      result[:market] || FUTURE_MARKETS.fetch(result[:source])
    end

    def build_institution_metadata(all_assets)
      SOURCES.each_with_object({}) do |source, hash|
        source_assets = all_assets.select { |a| a[:source] == source }
        hash[source] = {
          "asset_count" => source_assets.size,
          "assets" => source_assets.map { |a| a[:symbol] }
        }
      end
    end
end
