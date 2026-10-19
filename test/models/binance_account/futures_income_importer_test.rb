# frozen_string_literal: true

require "test_helper"

class BinanceAccount::FuturesIncomeImporterTest < ActiveSupport::TestCase
  # Answers income requests from a block and records every window asked for.
  class FakeProvider
    attr_reader :calls, :used_weight

    def initialize(&responder)
      @responder = responder
      @calls = []
      @used_weight = {}
    end

    def get_futures_income(start_time:, end_time:, limit:)
      answer(:usds_m, start_time, end_time)
    end

    def get_coin_futures_income(start_time:, end_time:, limit:)
      answer(:coin_m, start_time, end_time)
    end

    private

      def answer(market, start_time, end_time)
        @calls << [ market, start_time, end_time ]
        @responder.call(market, start_time, end_time, @calls.size)
      end
  end

  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @ba = @item.binance_accounts.create!(
      name: "Binance", account_type: "combined", currency: "USD", current_balance: 0,
      raw_payload: { "futures" => { "assets" => [] }, "coin_futures" => { "assets" => [] } }
    )
    @account = Account.create!(family: @family, name: "Binance", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange"))
    AccountProvider.create!(account: @account, provider: @ba)
    @now = Time.zone.parse("2026-10-19 12:00")
  end

  test "stores every COIN-M income row once, keyed by type and tranId, with its category" do
    provider = FakeProvider.new { |market, *| market == :coin_m ? rows("cm_income") : [] }

    import(provider)

    events = DerivativeLedgerEvent.where(market: "coin_m").order(:occurred_at, :provider_type)
    assert_equal 7, events.count
    assert_equal %w[commission commission funding funding realized_pnl settlement transfer], events.map(&:category).sort
    assert_equal 2, events.where(provider_transaction_id: "770005").count,
                 "a realized P&L and its commission share a tranId but are different events"

    settlement = events.find_by(provider_type: "DELIVERED_SETTELMENT")
    assert_equal "settlement", settlement.category
    assert_equal BigDecimal("0.0008"), settlement.amount
    assert_equal "BTC", settlement.asset

    funding = events.where(category: "funding").order(:occurred_at).first
    assert_equal BigDecimal("0.00000231"), funding.amount, "satoshi-level amounts survive"
    assert funding.ready?
    assert events.find_by(category: "transfer").excluded?
    assert_equal @account, funding.account
  end

  test "an income type the integration does not know waits for review" do
    provider = FakeProvider.new { |market, *| market == :usds_m ? rows("um_income") : [] }

    import(provider)

    unknown = DerivativeLedgerEvent.find_by(provider_type: "SOME_NEW_TYPE")
    assert unknown.needs_review?
    assert_equal "unknown", unknown.category
    assert_equal "unrecognised_income_type", unknown.reason
  end

  test "repeated syncs never duplicate events" do
    provider = FakeProvider.new { |market, *| rows(market == :coin_m ? "cm_income" : "um_income") }

    import(provider)
    assert_no_difference "DerivativeLedgerEvent.count" do
      import(provider, now: @now + 1.hour)
    end
  end

  test "the first sync backfills from sync_start_date, clamped to what Binance keeps" do
    @item.update!(sync_start_date: @now - 2.years)
    provider = FakeProvider.new { [] }

    import(provider)

    first_um = provider.calls.find { |market, *| market == :usds_m }
    first_cm = provider.calls.find { |market, *| market == :coin_m }
    assert_equal ms(@now - 90.days), first_um[1], "USDⓈ-M keeps three months"
    assert_equal ms(@now - 365.days), first_cm[1]
    assert provider.calls.all? { |_, start_time, end_time| end_time - start_time < 30.days.in_milliseconds }
    assert_equal ms(@now), provider.calls.select { |market, *| market == :coin_m }.last[2]
    assert checkpoint("coin_m")["backfill_complete"]
  end

  test "later syncs resume from the checkpoint with a one-day overlap" do
    provider = FakeProvider.new { [] }
    import(provider)

    later = @now + 3.days
    second = FakeProvider.new { [] }
    import(second, now: later)

    um_calls = second.calls.select { |market, *| market == :usds_m }
    assert_equal ms(@now) - 1.day.in_milliseconds, um_calls.first[1]
    assert_equal ms(later), um_calls.last[2]
    assert_equal 1, um_calls.size
  end

  test "a full page splits its window instead of trusting the row order" do
    full_page = Array.new(1000) do |i|
      { "symbol" => "BTCUSD_PERP", "incomeType" => "FUNDING_FEE", "income" => "-0.00000001", "asset" => "BTC",
        "time" => ms(@now - 10.days) + i, "tranId" => "f#{i}", "tradeId" => "" }
    end

    provider = FakeProvider.new do |market, start_time, end_time|
      next [] unless market == :coin_m

      full_page.select { |row| row["time"].between?(start_time, end_time) }
    end

    @item.update!(sync_start_date: @now - 20.days)
    import(provider)

    assert_equal 1000, DerivativeLedgerEvent.where(market: "coin_m").count
    windows = provider.calls.select { |market, *| market == :coin_m }
    assert windows.size > 1, "the full window was split"
  end

  test "a rate limit stops the read, keeps the checkpoint and the next sync resumes there" do
    @item.update!(sync_start_date: @now - 80.days)
    limited = FakeProvider.new do |market, _start, _end, call_number|
      raise Provider::Binance::RateLimitError.new("Too many requests", retry_after: 60) if market == :usds_m && call_number == 2

      []
    end

    stats = import(limited)

    assert_equal "rate_limit_error", stats["usds_m"][:stopped]
    refute checkpoint("usds_m")["backfill_complete"]
    covered = checkpoint("usds_m")["covered_to_ms"]
    assert_equal ms(@now - 80.days) + 30.days.in_milliseconds - 1, covered, "only the window read in full counts"
    assert_equal 60, checkpoint("usds_m")["retry_after"]
    assert DebugLogEntry.where(provider_key: "binance", source: "BinanceAccount::FuturesIncomeImporter").exists?

    resumed = FakeProvider.new { [] }
    import(resumed, now: @now + 1.minute)
    um = resumed.calls.select { |market, *| market == :usds_m }
    assert_equal covered - 1.day.in_milliseconds, um.first[1]
    assert checkpoint("usds_m")["backfill_complete"]
    assert_nil checkpoint("usds_m")["error"], "a later clean run clears the error"
  end

  test "the request budget pauses a long backfill" do
    @item.update!(sync_start_date: @now - 365.days)
    @ba.update!(raw_payload: { "coin_futures" => { "assets" => [] } })
    stub_const(BinanceAccount::FuturesIncomeImporter, :MAX_REQUESTS_PER_RUN, 3) do
      provider = FakeProvider.new { [] }
      stats = import(provider)

      assert_equal 3, provider.calls.size
      assert_equal "request_budget", stats["coin_m"][:stopped]
      refute checkpoint("coin_m")["backfill_complete"]
    end
  end

  test "a market whose wallet did not answer is not asked for income" do
    @ba.update!(raw_payload: { "futures" => nil, "coin_futures" => { "assets" => [] } })
    provider = FakeProvider.new { [] }

    import(provider)

    assert provider.calls.none? { |market, *| market == :usds_m }
    assert provider.calls.any? { |market, *| market == :coin_m }
  end

  test "a permission error is recorded and does not raise" do
    provider = FakeProvider.new { raise Provider::Binance::PermissionError, "Invalid API-key, IP, or permissions for action." }

    stats = import(provider)

    assert_equal "permission_error", stats["coin_m"][:stopped]
    assert_match "permissions", checkpoint("coin_m")["error"]
  end

  private

    def import(provider, now: @now)
      BinanceAccount::FuturesIncomeImporter.new(@ba.reload, provider: provider).import(now: now)
    end

    def checkpoint(market)
      @ba.reload.extra.dig("binance", "futures_income", market)
    end

    def rows(name)
      JSON.parse(file_fixture("binance_futures/#{name}.json").read)
    end

    def ms(time)
      (time.to_f * 1000).to_i
    end

    def stub_const(klass, name, value)
      original = klass.const_get(name)
      klass.send(:remove_const, name)
      klass.const_set(name, value)
      yield
    ensure
      klass.send(:remove_const, name)
      klass.const_set(name, original)
    end
end
