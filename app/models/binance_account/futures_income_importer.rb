# frozen_string_literal: true

# Reads the income history of the USDⓈ-M and COIN-M futures wallets
# (realized P&L, funding, commissions, transfers, settlements, ...) into
# DerivativeLedgerEvent rows, incrementally.
#
# Identity: Binance states that tranId is unique per incomeType, so an event
# is keyed by market, type, tranId, symbol and asset — every part immutable.
# Re-reading a window therefore never duplicates anything, which is what
# makes the overlap below and an interrupted backfill safe.
#
# Paging: a window that comes back full (1000 rows) is split in half and
# both halves are read, instead of trusting a sort order or advancing past
# the last row's time (rows can share a millisecond). The checkpoint
# (`covered_to_ms`) moves only past windows read completely, and each run
# re-reads OVERLAP before it for rows Binance recorded late.
#
# Limits: USDⓈ-M income weighs 30 and COIN-M 20 against a 2400/minute IP
# budget. A run stops after MAX_REQUESTS_PER_RUN requests per market, when
# the reported weight passes WEIGHT_CEILING, or on a 429/418, and the next
# sync resumes from the checkpoint.
class BinanceAccount::FuturesIncomeImporter
  MARKETS = {
    "usds_m" => { source: "futures", request: :get_futures_income, lookback: 90.days, host: "fapi.binance.com" },
    # Binance does not state COIN-M retention; a request may span a year.
    "coin_m" => { source: "coin_futures", request: :get_coin_futures_income, lookback: 365.days, host: "dapi.binance.com" }
  }.freeze

  PAGE_LIMIT = 1000
  WINDOW = 30.days
  OVERLAP = 1.day
  MAX_REQUESTS_PER_RUN = 40
  WEIGHT_CEILING = 1800

  CATEGORIES = {
    "REALIZED_PNL" => "realized_pnl",
    "FUNDING_FEE" => "funding",
    "COMMISSION" => "commission",
    "OPTIONS_PREMIUM_FEE" => "commission",
    "POSITION_LIMIT_INCREASE_FEE" => "commission",
    "COMMISSION_REBATE" => "rebate",
    "API_REBATE" => "rebate",
    "REFERRAL_KICKBACK" => "rebate",
    "FEE_RETURN" => "rebate",
    "DELIVERED_SETTELMENT" => "settlement",
    "DELIVERED_SETTLEMENT" => "settlement",
    "OPTIONS_SETTLE_PROFIT" => "settlement",
    "INSURANCE_CLEAR" => "liquidation",
    "AUTO_EXCHANGE" => "conversion",
    "WELCOME_BONUS" => "bonus",
    "CONTEST_REWARD" => "bonus",
    "BFUSD_REWARD" => "bonus",
    "TRANSFER" => "transfer",
    "INTERNAL_TRANSFER" => "transfer",
    "CROSS_COLLATERAL_TRANSFER" => "transfer",
    "STRATEGY_UMFUTURES_TRANSFER" => "transfer"
  }.freeze

  attr_reader :binance_account, :provider

  def initialize(binance_account, provider:)
    @binance_account = binance_account
    @provider = provider
  end

  # Markets whose wallet answered in this sync. A key that cannot read a
  # market's account cannot read its income either, so it is not asked.
  def active_markets
    MARKETS.select { |_market, config| binance_account.raw_payload&.dig(config[:source]).present? }.keys
  end

  # @return [Hash] market -> { created:, requests:, complete:, stopped: }
  def import(now: Time.current)
    active_markets.to_h { |market| [ market, import_market(market, now) ] }
  end

  def self.category_for(income_type)
    CATEGORIES.fetch(income_type.to_s, "unknown")
  end

  def self.external_key_for(market, row)
    [ market, row["incomeType"], row["tranId"].presence || "t#{row['time']}", row["symbol"].presence || "-", row["asset"] ].join(":")
  end

  private

    def import_market(market, now)
      config = MARKETS.fetch(market)
      checkpoint = checkpoints[market] || {}
      now_ms = (now.to_f * 1000).to_i
      floor_ms = ((now - config[:lookback]).to_f * 1000).to_i

      start_ms = if checkpoint["covered_to_ms"]
        [ checkpoint["covered_to_ms"].to_i - OVERLAP.in_milliseconds, floor_ms ].max
      else
        [ configured_start_ms || floor_ms, floor_ms ].max
      end

      windows = []
      cursor = start_ms
      while cursor <= now_ms
        window_end = [ cursor + WINDOW.in_milliseconds - 1, now_ms ].min
        windows << [ cursor, window_end ]
        cursor = window_end + 1
      end

      stats = { created: 0, requests: 0, complete: false, stopped: nil }
      covered_to = checkpoint["covered_to_ms"]&.to_i

      until windows.empty?
        if stats[:requests] >= MAX_REQUESTS_PER_RUN
          stats[:stopped] = "request_budget"
          break
        end

        if weight_used(config[:host]) >= WEIGHT_CEILING
          stats[:stopped] = "weight_ceiling"
          break
        end

        window_start, window_end = windows.shift
        rows = Array(provider.public_send(config[:request], start_time: window_start, end_time: window_end, limit: PAGE_LIMIT))
        stats[:requests] += 1

        if rows.size >= PAGE_LIMIT && window_end > window_start
          middle = window_start + (window_end - window_start) / 2
          windows.unshift([ window_start, middle ], [ middle + 1, window_end ])
          next
        end

        stats[:created] += store(market, rows)
        covered_to = [ covered_to || 0, window_end ].max
        save_checkpoint(market, covered_to_ms: covered_to, started_from_ms: checkpoint["started_from_ms"] || start_ms)
      end

      stats[:complete] = windows.empty?
      save_checkpoint(market, covered_to_ms: covered_to, started_from_ms: checkpoint["started_from_ms"] || start_ms,
                      backfill_complete: checkpoint["backfill_complete"] || stats[:complete], stopped: stats[:stopped],
                      error: nil, retry_after: nil)
      record_stop(market, stats) if stats[:stopped]
      stats
    rescue Provider::Binance::RateLimitError, Provider::Binance::AuthenticationError, Provider::Binance::ApiError => e
      stats ||= { created: 0, requests: 0, complete: false }
      stats[:stopped] = e.class.name.demodulize.underscore
      stats[:error] = e.message
      save_checkpoint(market, covered_to_ms: covered_to, started_from_ms: checkpoint["started_from_ms"] || start_ms,
                      stopped: stats[:stopped], error: e.message, retry_after: e.try(:retry_after))
      record_stop(market, stats)
      stats
    end

    def store(market, rows)
      return 0 if rows.empty?

      keyed = rows.index_by { |row| self.class.external_key_for(market, row) }
      existing = DerivativeLedgerEvent.where(item: binance_item, external_key: keyed.keys).pluck(:external_key).to_set
      created = 0

      keyed.each do |external_key, row|
        next if existing.include?(external_key)

        category = self.class.category_for(row["incomeType"])
        DerivativeLedgerEvent.create!(
          family: binance_item.family,
          provider_key: "binance",
          item: binance_item,
          provider_account: binance_account,
          account: binance_account.current_account,
          market: market,
          external_key: external_key,
          category: category,
          provider_type: row["incomeType"].to_s,
          status: DerivativeLedgerEvent.initial_status_for(category),
          reason: category == "unknown" ? "unrecognised_income_type" : nil,
          symbol: row["symbol"].presence,
          asset: row["asset"].to_s,
          amount: row["income"].to_d,
          occurred_at: Time.zone.at(row["time"].to_i / 1000.0),
          provider_transaction_id: row["tranId"].to_s.presence,
          provider_trade_id: row["tradeId"].to_s.presence,
          info: row["info"].to_s.presence,
          raw_payload: row
        )
        created += 1
      rescue ActiveRecord::RecordNotUnique
        next
      end

      created
    end

    def binance_item
      binance_account.binance_item
    end

    def configured_start_ms
      start = binance_item.sync_start_date
      start ? (start.to_time.to_f * 1000).to_i : nil
    end

    def weight_used(host)
      Array(provider.try(:used_weight)).select { |(key_host, name), _| key_host == host && name.end_with?("1m") }.map(&:last).max.to_i
    end

    def checkpoints
      binance_account.extra.to_h.dig("binance", "futures_income") || {}
    end

    def save_checkpoint(market, **values)
      # Replaced, not deep-merged, so a cleared error or stop reason goes away.
      entry = (checkpoints[market] || {}).merge(values.transform_keys(&:to_s)).merge("run_at" => Time.current.iso8601).compact
      extra = binance_account.extra.to_h.deep_dup
      extra["binance"] = (extra["binance"] || {}).merge("futures_income" => checkpoints.merge(market => entry))
      binance_account.update!(extra: extra)
    end

    def record_stop(market, stats)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: stats[:error] ? "warn" : "info",
        message: "Binance #{market} income read paused; the next sync resumes it",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        account_provider: binance_account.account_provider,
        metadata: { binance_account_id: binance_account.id, market: market }.merge(stats.except(:created))
      )
    end
end
