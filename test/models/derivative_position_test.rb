# frozen_string_literal: true

require "test_helper"

class DerivativePositionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @t0 = Time.zone.parse("2026-10-10 08:00")
  end

  test "a reported position opens an episode and later reports update it" do
    assert_equal({ opened: 1, updated: 0, closed: 0 }, reconcile([ perp(-300) ], at: @t0))
    assert_equal({ opened: 0, updated: 1, closed: 0 }, reconcile([ perp(-500, mark: "61000") ], at: @t0 + 1.hour))

    position = DerivativePosition.sole
    assert position.open?
    assert position.short?
    assert_equal BigDecimal("-500"), position.quantity
    assert_equal BigDecimal("61000"), position.mark_price
    assert_equal @t0, position.first_observed_at
    assert_equal @t0 + 1.hour, position.last_observed_at
  end

  test "a position missing from a complete report is closed, and reopening starts a new episode" do
    reconcile([ perp(-300) ], at: @t0)
    assert_equal({ opened: 0, updated: 0, closed: 1 }, reconcile([], at: @t0 + 1.day))

    closed = DerivativePosition.sole
    assert closed.closed?
    assert_equal @t0 + 1.day, closed.closed_at
    assert_equal BigDecimal("-300"), closed.quantity, "the last known size stays on the closed episode"

    reconcile([ perp(-100) ], at: @t0 + 2.days)

    assert_equal 2, DerivativePosition.count
    reopened = DerivativePosition.open.sole
    refute_equal closed.id, reopened.id
    assert_equal @t0 + 2.days, reopened.opened_at
    assert_equal BigDecimal("-100"), reopened.quantity
  end

  test "flipping a one-way position from short to long closes one episode and opens another" do
    reconcile([ perp(-300) ], at: @t0)

    assert_equal({ opened: 1, updated: 0, closed: 1 }, reconcile([ perp(200) ], at: @t0 + 1.hour))
    assert DerivativePosition.closed.sole.short?
    assert DerivativePosition.open.sole.long?
  end

  test "hedge-mode long and short on one symbol are separate episodes" do
    reconcile([ perp(100, side: "LONG"), perp(-50, side: "SHORT") ], at: @t0)

    assert_equal 2, DerivativePosition.open.count
    reconcile([ perp(100, side: "LONG") ], at: @t0 + 1.hour)
    assert_equal "SHORT", DerivativePosition.closed.sole.position_side
  end

  test "markets are reconciled independently" do
    reconcile([ perp(-300) ], at: @t0)
    DerivativePosition.reconcile!(item: @item, provider_key: "binance", market: "usds_m", reported: [], observed_at: @t0)

    assert DerivativePosition.sole.open?, "an empty USDⓈ-M report must not close a COIN-M position"
  end

  test "only one open episode per symbol and side" do
    reconcile([ perp(-300) ], at: @t0)

    assert_raises(ActiveRecord::RecordNotUnique) do
      DerivativePosition.create!(DerivativePosition.sole.attributes.except("id", "created_at", "updated_at"))
    end
  end

  private

    def reconcile(reported, at:)
      DerivativePosition.reconcile!(item: @item, provider_key: "binance", market: "coin_m", reported: reported, observed_at: at)
    end

    def perp(quantity, side: "BOTH", mark: "62000")
      {
        symbol: "BTCUSD_PERP", position_side: side, quantity: BigDecimal(quantity.to_s), quantity_unit: "contracts",
        contract_size: 100, contract_size_currency: "USD", margin_asset: "BTC", entry_price: 64000, mark_price: BigDecimal(mark),
        notional_currency: "BTC", unrealized_pnl_currency: "BTC"
      }
    end
end
