# frozen_string_literal: true

require "test_helper"

class BinanceItem::FuturesImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "returns normalized assets from USDⓈ-M futures with source=futures" do
    @provider.stubs(:get_futures_account).returns({
      "assets" => [
        { "asset" => "USDT", "walletBalance" => "100.0", "unrealizedProfit" => "5.0", "availableBalance" => "90.0" },
        { "asset" => "BUSD", "walletBalance" => "0.0", "unrealizedProfit" => "0.0", "availableBalance" => "0.0" }
      ],
      "positions" => [
        { "symbol" => "BTCUSDT", "positionAmt" => "0.5" }
      ]
    })
    @provider.stubs(:get_futures_position_risk).returns([])

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_equal "futures", result[:source]
    assert_equal 1, result[:assets].size
    usdt = result[:assets].first
    assert_equal "USDT", usdt[:symbol]
    assert_equal "105.0", usdt[:total] # walletBalance + unrealizedProfit
    assert_equal "90.0", usdt[:free]
    assert_equal "10.0", usdt[:locked] # walletBalance - availableBalance
  end

  test "keeps USDT and USDC wallet, equity, available margin and unrealized P&L apart" do
    stub_account_and_positions

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import
    usdt = result[:assets].find { |a| a[:symbol] == "USDT" }
    usdc = result[:assets].find { |a| a[:symbol] == "USDC" }

    assert_equal %w[USDC USDT], result[:assets].map { |a| a[:symbol] }.sort, "an all-zero BTC row is not an asset"
    assert_equal "1000.0", usdt[:wallet_balance]
    assert_equal "-12.25", usdt[:unrealized_pnl]
    assert_equal "987.75", usdt[:margin_balance]
    assert_equal "867.75", usdt[:available_balance]
    assert_equal "987.75", usdt[:total], "the quantity held is the equity, wallet plus unrealized P&L"
    assert_equal "250.5", usdc[:total]

    summary = result[:summary]
    assert_equal "987.75", summary.dig("assets", "USDT", "margin_balance")
    assert_equal 1, summary["open_positions"]
    assert_equal({ "USDT" => "1200.0" }, summary["notional"])
  end

  test "reports open positions with quantity in the base asset and prices in the margin asset" do
    stub_account_and_positions

    positions = BinanceItem::FuturesImporter.new(@item, provider: @provider).import[:positions]

    assert_equal 1, positions.size, "a zero position is not open"
    eth = positions.first
    assert_equal "ETHUSDT", eth[:symbol]
    assert_equal "BOTH", eth[:position_side]
    assert_equal "PERPETUAL", eth[:contract_type]
    assert_equal BigDecimal("0.5"), eth[:quantity]
    assert_equal "base", eth[:quantity_unit]
    assert_nil eth[:contract_size]
    assert_equal BigDecimal("2424.5"), eth[:entry_price]
    assert_equal BigDecimal("2400"), eth[:mark_price]
    assert_equal BigDecimal("1200"), eth[:notional]
    assert_equal "USDT", eth[:notional_currency]
    assert_equal BigDecimal("-12.25"), eth[:unrealized_pnl]
    assert_equal "USDT", eth[:unrealized_pnl_currency]
  end

  test "a failed position read is unknown, not empty, and keeps the balances" do
    @provider.stubs(:get_futures_account).returns(fixture("um_account"))
    @provider.stubs(:get_futures_position_risk).raises(Provider::Binance::RateLimitError.new("slow down", retry_after: 30))

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_nil result[:error]
    assert_nil result[:positions]
    assert_equal 2, result[:assets].size
    assert_match "slow down", result[:summary]["positions_error"]
  end

  test "returns empty on API error" do
    @provider.stubs(:get_futures_account).raises(Provider::Binance::ApiError, "WAF")

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_equal "futures", result[:source]
    assert_equal [], result[:assets]
  end

  test "a key that may not read futures is reported as a permission error" do
    @provider.stubs(:get_futures_account).raises(Provider::Binance::PermissionError, "Invalid API-key, IP, or permissions for action.")

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_equal "Provider::Binance::PermissionError", result[:error_class]
    assert_equal [], result[:assets]
  end

  private

    def stub_account_and_positions
      @provider.stubs(:get_futures_account).returns(fixture("um_account"))
      @provider.stubs(:get_futures_position_risk).returns(fixture("um_position_risk"))
    end

    def fixture(name)
      JSON.parse(file_fixture("binance_futures/#{name}.json").read)
    end
end
