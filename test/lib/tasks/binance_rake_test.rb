# frozen_string_literal: true

require "test_helper"

RakeTaskTestHelper.load_task("binance:futures", "binance")

class BinanceRakeTest < ActiveSupport::TestCase
  setup do
    RakeTaskTestHelper.prepare("binance:futures", "binance:positions", "binance:legacy_futures_trades")

    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "Binance", api_key: "k", api_secret: "s",
                                raw_payload: { "api_restrictions" => { "enableReading" => true, "enableWithdrawals" => true } })
    @ba = @item.binance_accounts.create!(
      name: "Binance", account_type: "combined", currency: "USD", current_balance: 0,
      raw_payload: { "futures_summary" => { "coin_m" => {
        "assets" => { "BTC" => { "wallet_balance" => "0.85", "margin_balance" => "0.86512097", "available_balance" => "0.8325", "unrealized_pnl" => "0.01512097" } },
        "open_positions" => 1, "notional" => { "BTC" => "0.48387097" }, "read_at" => Time.current.iso8601
      } } }
    )
    @account = Account.create!(family: @family, name: "Binance", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange"))
    AccountProvider.create!(account: @account, provider: @ba)
    @btc = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")
  end

  test "futures report shows equity apart from wallet and flags a key that can do more than read" do
    out, = capture_io { Rake::Task["binance:futures"].invoke }

    assert_match "wallet 0.85  equity 0.86512097", out
    assert_match "exposure, not in the balance", out
    assert_match "WARNING: the key can do more than read: enableWithdrawals", out
  end

  test "legacy futures fills are reported, and deleted only with FAMILY_ID, CONFIRM and OUT" do
    legacy = legacy_fill("binance_futures_BTCUSDT_1")
    edited = legacy_fill("binance_futures_BTCUSDT_2")
    edited.update!(user_modified: true)
    spot = legacy_fill("binance_spot_BTCUSDT_3")
    income = legacy_fill("binance_derivatives_usds_m_funding_USDT_2026-10-12")
    out_path = Rails.root.join("tmp", "binance-legacy-#{SecureRandom.hex(4)}.csv")

    out, = capture_io do
      assert_raises(SystemExit) { Rake::Task["binance:legacy_futures_trades"].invoke }
    end
    assert_match "2 futures fills recorded as trades, 1 edited by the user", out
    assert Entry.exists?(legacy.id), "a dry run deletes nothing"

    Rake::Task["binance:legacy_futures_trades"].reenable
    ClimateControl.modify(FAMILY_ID: @family.id, CONFIRM: "yes", OUT: out_path.to_s) do
      capture_io { Rake::Task["binance:legacy_futures_trades"].invoke }
    end

    refute Entry.exists?(legacy.id)
    assert Entry.exists?(edited.id), "a row the user edited stays"
    assert Entry.exists?(spot.id)
    assert Entry.exists?(income.id), "derived futures income is not a legacy fill"
    assert_equal 3, CSV.read(out_path).size, "header plus both rows, written before deleting"
  ensure
    File.delete(out_path) if out_path && File.exist?(out_path)
  end

  private

    def legacy_fill(external_id)
      @account.entries.create!(
        date: Date.current, name: "Buy 0.1 BTC", amount: -4000, currency: "USD", external_id: external_id, source: "binance",
        entryable: Trade.new(security: @btc, qty: 0.1, price: 40_000, currency: "USD", investment_activity_label: "Buy")
      )
    end
end
