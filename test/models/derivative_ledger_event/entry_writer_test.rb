# frozen_string_literal: true

require "test_helper"

class DerivativeLedgerEvent::EntryWriterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @account = Account.create!(family: @family, name: "Binance", balance: 0, currency: "EUR", accountable: Crypto.create!(subtype: "exchange"))
    @btc = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")
    @usdt = Security.create!(ticker: "CRYPTO:USDT", name: "Tether", price_provider: "binance_public")
    @day = Date.new(2026, 10, 12)
  end

  test "a day's funding payments become one zero-amount trade of the margin asset" do
    event("funding", "0.00000231", at: 8)
    event("funding", "-0.00000112", at: 16)

    assert_equal({ created: 1 }, write.to_h.symbolize_keys)

    entry = @account.entries.sole
    trade = entry.entryable
    assert_equal 0, entry.amount, "funding moves coins, not cash"
    assert_equal "EUR", entry.currency
    assert_equal @day, entry.date
    assert_equal @btc, trade.security
    assert_equal BigDecimal("0.00000119"), trade.qty
    assert_equal BigDecimal("55000"), trade.price
    assert_equal "Interest", trade.investment_activity_label
    assert_equal "binance_derivatives_coin_m_funding_BTC_2026-10-12", entry.external_id
    assert_equal "COIN-M funding +0.00000119 BTC on BTCUSD_PERP", entry.name
    assert_equal 2, trade.extra.dig("binance", "event_count")
    assert DerivativeLedgerEvent.all.all?(&:imported?)
    assert DerivativeLedgerEvent.all.all? { |e| e.entry_id == entry.id }
  end

  test "realized P&L, commissions and settlements are separate entries with their own labels" do
    event("realized_pnl", "0.0015")
    event("commission", "-0.00002419")
    event("settlement", "0.0008", symbol: "BTCUSD_250926")

    write

    by_category = @account.entries.includes(:entryable).index_by { |e| e.entryable.extra.dig("binance", "category") }
    assert_equal "Other", by_category["realized_pnl"].entryable.investment_activity_label
    assert_equal BigDecimal("0.0015"), by_category["realized_pnl"].entryable.qty
    assert_equal "Fee", by_category["commission"].entryable.investment_activity_label
    assert_equal BigDecimal("-0.00002419"), by_category["commission"].entryable.qty
    assert_equal "Other", by_category["settlement"].entryable.investment_activity_label
    assert @account.entries.all? { |e| e.amount.zero? }
  end

  test "excluded transfers and unknown types never reach the ledger" do
    event("transfer", "0.5", status: :excluded)
    event("unknown", "1", status: :needs_review)

    write

    assert_empty @account.entries
  end

  test "rerunning is idempotent and a late event updates the day in place" do
    event("funding", "-0.12", asset: "USDT", market: "usds_m", symbol: "ETHUSDT")
    write
    entry = @account.entries.sole

    assert_empty write, "a day without new events is not touched"

    event("funding", "-0.08", asset: "USDT", market: "usds_m", symbol: "ETHUSDT", at: 20)
    assert_equal({ updated: 1 }, write.to_h.symbolize_keys)

    assert_equal entry.id, @account.entries.sole.id
    assert_equal BigDecimal("-0.2"), entry.reload.entryable.qty
    assert_equal BigDecimal("0.92"), entry.entryable.price, "USDT priced at 1 USD in EUR"
  end

  test "an entry the user deleted is never recreated, even when the day gets more events" do
    event("commission", "-0.5", asset: "USDT", market: "usds_m")
    write
    @account.entries.sole.destroy!

    assert_equal({ dismissed: 1 }, write.to_h.symbolize_keys)
    event("commission", "-0.3", asset: "USDT", market: "usds_m", at: 22)
    write

    assert_empty @account.entries.reload
    assert DerivativeLedgerEvent.all.all?(&:dismissed?)
  end

  test "an entry the user edited keeps their edits" do
    event("realized_pnl", "35.2", asset: "USDT", market: "usds_m")
    write
    entry = @account.entries.sole
    entry.update!(name: "My ETH trade", user_modified: true)

    event("realized_pnl", "4.8", asset: "USDT", market: "usds_m", at: 23)
    write

    assert_equal "My ETH trade", entry.reload.name
    assert_equal BigDecimal("35.2"), entry.entryable.qty
    assert DerivativeLedgerEvent.all.all? { |e| e.entry_id == entry.id }
  end

  test "a day that nets to zero has no entry and can come back" do
    event("funding", "0.0001")
    write
    event("funding", "-0.0001", at: 16)

    assert_equal({ removed: 1 }, write.to_h.symbolize_keys)
    assert_empty @account.entries.reload
    assert DerivativeLedgerEvent.all.none?(&:deleted_by_user?), "netting to zero is not a user deletion"

    event("funding", "0.00005", at: 23)
    write
    assert_equal BigDecimal("0.00005"), @account.entries.sole.entryable.qty
  end

  test "a missing price is recorded as such rather than guessed" do
    event("funding", "0.0001")

    write(price_for: ->(*) { nil })

    trade = @account.entries.sole.entryable
    assert_equal 0, trade.price
    assert trade.extra.dig("binance", "price_missing")
  end

  # The point of writing quantities: Sure's reverse holdings walk undoes
  # them, so the margin coin's history reflects what futures did to it, and
  # no cash appears on any day.
  test "the reverse holdings walk undoes the quantities and invents no cash" do
    today = Date.current
    @account.update!(currency: "USD")
    @account.holdings.create!(security: @btc, date: today, qty: BigDecimal("0.86512097"), price: 62_000,
                              amount: BigDecimal("0.86512097") * 62_000, currency: "USD")
    (today - 3..today).each { |date| Security::Price.create!(security: @btc, date: date, price: 62_000, currency: "USD") }
    event("realized_pnl", "0.0015", at: 10, day: today - 2)
    event("commission", "-0.00002419", at: 10, day: today - 2)
    write

    holdings = Holding::ReverseCalculator.new(@account, portfolio_snapshot: Holding::PortfolioSnapshot.new(@account)).calculate
    qty_on = ->(date) { holdings.find { |h| h.date == date && h.security_id == @btc.id }&.qty }

    assert_equal BigDecimal("0.86512097"), qty_on.call(today - 1)
    assert_equal BigDecimal("0.86364516"), qty_on.call(today - 3), "before the day, minus its net +0.00147581 BTC"
    assert @account.entries.all? { |e| e.amount.zero? }
  end

  private

    def write(price_for: nil)
      prices = { "BTC" => BigDecimal("55000"), "USDT" => BigDecimal("0.92") }
      DerivativeLedgerEvent::EntryWriter.new(
        account: @account,
        source: "binance",
        security_for: ->(asset) { { "BTC" => @btc, "USDT" => @usdt }[asset] },
        price_for: price_for || ->(asset, _date) { prices[asset] },
        market_names: { "coin_m" => "COIN-M", "usds_m" => "USDⓈ-M" }
      ).write
    end

    def event(category, amount, asset: "BTC", market: "coin_m", symbol: "BTCUSD_PERP", at: 8, status: :ready, day: @day)
      @sequence = (@sequence || 0) + 1
      DerivativeLedgerEvent.create!(
        family: @family, provider_key: "binance", item: @item, account: @account, market: market,
        external_key: "#{market}:#{category}:#{@sequence}", category: category, provider_type: category.upcase,
        status: status, symbol: symbol, asset: asset, amount: BigDecimal(amount),
        occurred_at: Time.zone.local(day.year, day.month, day.day, at)
      )
    end
end
