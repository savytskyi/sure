# frozen_string_literal: true

require "test_helper"

class BinanceAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BinanceItem.create!(
      family: @family, name: "Binance", api_key: "k", api_secret: "s"
    )
    @ba = @item.binance_accounts.create!(
      name: "Binance",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000,
      raw_payload: {
        "assets" => [ { "symbol" => "BTC", "total" => "0.5", "source" => "spot" } ]
      }
    )
    @account = Account.create!(
      family: @family,
      name: "Binance",
      balance: 0,
      currency: "EUR",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)
  end

  test "converts holding amount to family currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::HoldingsProcessor.any_instance
      .stubs(:fetch_price).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 27_600.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
  end

  test "uses raw USD amount when no rate is available" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::HoldingsProcessor.any_instance
      .stubs(:fetch_price).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 30_000.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
  end
  # The reported bug. The processor wrote whatever Binance returned and never
  # removed what it stopped returning, so an asset sold between two syncs kept
  # its row for the day — and the account page reads exactly that day.
  test "an asset that has left the wallet stops being held" do
    seed_rate_and_securities

    write_payload([ btc_asset, eth_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC", "CRYPTO:ETH" ], held_tickers

    # ETH is sold, so Binance stops returning it.
    write_payload([ btc_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_equal [ "CRYPTO:BTC" ], held_tickers,
                 "an asset the wallet no longer holds was still in the portfolio"
  end

  # An emptied wallet is the same question with nothing left to compare
  # against, and the early return on a blank asset list skipped the removal
  # entirely.
  test "emptying the wallet empties the portfolio" do
    seed_rate_and_securities

    write_payload([ btc_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC" ], held_tickers

    write_payload([])
    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_empty held_tickers, "the emptied wallet still reported holdings"
  end

  # Sure keeps one holding per security and day. BTC in Spot and BTC posted
  # as COIN-M collateral used to be written one after the other, and the
  # second replaced the first, so the account showed only part of its BTC.
  test "the same coin in several wallets is one holding of the summed quantity" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    @family.update!(currency: "USD")
    @account.update!(currency: "USD")
    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end
    BinanceAccount::HoldingsProcessor.any_instance.stubs(:fetch_price).with("BTC").returns(60_000.0)
    @ba.update!(raw_payload: { "assets" => [
      { "symbol" => "BTC", "total" => "0.5", "source" => "spot" },
      { "symbol" => "BTC", "total" => "0.86512097", "source" => "coin_futures" }
    ] })

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holding = @account.holdings.where(date: Date.current).sole
    assert_equal BigDecimal("1.36512097"), holding.qty
    assert_in_delta 81_907.26, holding.amount, 0.01
    assert_equal "binance_BTC_spot+coin_futures_#{Date.current}", holding.external_id
  end

  test "a coin held in one wallet keeps its existing external id" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end
    BinanceAccount::HoldingsProcessor.any_instance.stubs(:fetch_price).with("BTC").returns(60_000.0)

    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_equal "binance_BTC_spot_#{Date.current}", @account.holdings.where(date: Date.current).sole.external_id
  end

  private
    def seed_rate_and_securities
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                           date: Date.current, rate: 1.0)
      %w[BTC ETH].each do |symbol|
        Security.find_or_create_by!(ticker: "CRYPTO:#{symbol}") do |s|
          s.name = symbol
          s.exchange_operating_mic = "XBNC"
        end
      end
      BinanceAccount::HoldingsProcessor.any_instance.stubs(:fetch_price).returns(1_000.0)
    end

    def btc_asset = { "symbol" => "BTC", "total" => "0.5", "source" => "spot" }
    def eth_asset = { "symbol" => "ETH", "total" => "2", "source" => "spot" }

    def write_payload(assets)
      @ba.update!(raw_payload: { "assets" => assets })
    end

    def held_tickers
      @account.reload.current_holdings.filter_map { |h| h.security&.ticker }.sort
    end
end
