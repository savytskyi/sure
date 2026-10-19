# frozen_string_literal: true

require "test_helper"

class BinanceItem::CoinFuturesImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "BTC collateral is a BTC asset whose quantity is wallet plus BTC-denominated unrealized P&L" do
    stub_all

    result = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import

    assert_equal "coin_futures", result[:source]
    assert_equal "coin_m", result[:market]
    assert_equal [ "BTC" ], result[:assets].map { |a| a[:symbol] }
    btc = result[:assets].first
    assert_equal "0.85", btc[:wallet_balance]
    assert_equal "0.01512097", btc[:unrealized_pnl]
    assert_equal "0.86512097", btc[:margin_balance]
    assert_equal "0.8325", btc[:available_balance]
    assert_equal "0.86512097", btc[:total]
  end

  test "positions are contracts with the contract multiplier and coin-denominated notional and P&L" do
    stub_all

    positions = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import[:positions]

    assert_equal [ "BTCUSD_PERP" ], positions.map { |p| p[:symbol] }
    perp = positions.first
    assert_equal BigDecimal("-300"), perp[:quantity], "short 300 contracts"
    assert_equal "contracts", perp[:quantity_unit]
    assert_equal BigDecimal("100"), perp[:contract_size]
    assert_equal "USD", perp[:contract_size_currency]
    assert_equal "PERPETUAL", perp[:contract_type]
    assert_equal "BTC", perp[:margin_asset]
    assert_equal BigDecimal("64000"), perp[:entry_price]
    assert_equal "USD", perp[:price_currency]
    assert_equal BigDecimal("-0.48387097"), perp[:notional]
    assert_equal "BTC", perp[:notional_currency]
    assert_equal BigDecimal("0.01512097"), perp[:unrealized_pnl]
    assert_equal "BTC", perp[:unrealized_pnl_currency], "COIN-M P&L is BTC, never USD"
    assert_equal BigDecimal("3"), perp[:leverage]

    # The multiplier is what links contracts to the notional Binance states.
    implied = (perp[:quantity].abs * perp[:contract_size] / perp[:mark_price]).round(8)
    assert_equal perp[:notional].abs, implied
  end

  test "dated contracts keep their contract type from exchangeInfo" do
    @provider.stubs(:get_coin_futures_account).returns(fixture("cm_account"))
    @provider.stubs(:get_coin_futures_exchange_info).returns(fixture("cm_exchange_info"))
    @provider.stubs(:get_coin_futures_position_risk).returns([
      { "symbol" => "BTCUSD_261225", "positionAmt" => "10", "entryPrice" => "66000", "markPrice" => "65000",
        "unRealizedProfit" => "-0.00023310", "notionalValue" => "0.01538462", "positionSide" => "BOTH" }
    ])

    perp = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import[:positions].first

    assert_equal "CURRENT_QUARTER", perp[:contract_type]
    assert_equal BigDecimal("100"), perp[:contract_size]
  end

  test "a missing exchangeInfo only loses the multiplier" do
    @provider.stubs(:get_coin_futures_account).returns(fixture("cm_account"))
    @provider.stubs(:get_coin_futures_position_risk).returns(fixture("cm_position_risk"))
    @provider.stubs(:get_coin_futures_exchange_info).raises(Provider::Binance::ApiError, "down")

    perp = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import[:positions].first

    assert_nil perp[:contract_size]
    assert_equal "BTC", perp[:margin_asset], "the margin coin is read from the symbol instead"
    assert_equal BigDecimal("-300"), perp[:quantity]
  end

  test "no open contracts means no exchangeInfo request" do
    @provider.stubs(:get_coin_futures_account).returns(fixture("cm_account"))
    @provider.stubs(:get_coin_futures_position_risk).returns([])
    @provider.expects(:get_coin_futures_exchange_info).never

    assert_equal [], BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import[:positions]
  end

  test "returns an error result when the account cannot be read" do
    @provider.stubs(:get_coin_futures_account).raises(Provider::Binance::PermissionError, "Invalid API-key, IP, or permissions for action.")

    result = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import

    assert_equal [], result[:assets]
    assert_equal "coin_futures", result[:source]
    assert_match "permissions", result[:error]
  end

  private

    def stub_all
      @provider.stubs(:get_coin_futures_account).returns(fixture("cm_account"))
      @provider.stubs(:get_coin_futures_position_risk).returns(fixture("cm_position_risk"))
      @provider.stubs(:get_coin_futures_exchange_info).returns(fixture("cm_exchange_info"))
    end

    def fixture(name)
      JSON.parse(file_fixture("binance_futures/#{name}.json").read)
    end
end
