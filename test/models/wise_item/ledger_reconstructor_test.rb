require "test_helper"

# Anonymized, synthetic Wise activity shapes (no real financial data).
class WiseItem::LedgerReconstructorTest < ActiveSupport::TestCase
  setup do
    @wise_item = WiseItem.create!(family: families(:empty), name: "Personal", token: "t", profile_id: "10001", profile_type: :personal)
    @eur = balance("50001", "EUR", opened: "2023-01-10")
    @usd = balance("50002", "USD", opened: "2023-03-01")
  end

  # --- card payments -----------------------------------------------------------

  test "card payment in the balance currency is inferred to the single eligible balance" do
    leg = only_leg(card("2001", "<strong>LIDL 1234 MARIBOR</strong>", "23.45 EUR"))

    assert_equal "inferred", leg.provenance
    assert_equal @eur, leg.wise_account
    assert_equal BigDecimal("23.45"), leg.amount
    assert_equal "EUR", leg.currency
    assert_equal "LIDL 1234 MARIBOR", leg.merchant_name
    assert_equal({ "amount" => "inferred", "currency" => "inferred", "source_balance" => "inferred" }, leg.field_provenance)
    assert_equal "CARD-2001", leg.statement_reference
  end

  test "an explicitly stated debit amount keeps provider-explicit amount provenance" do
    leg = only_leg(card("3001", "<strong>Booking</strong>", "4,517.28 DKK", secondary: "607.39 EUR"))

    assert_equal BigDecimal("607.39"), leg.amount
    assert_equal "EUR", leg.currency
    assert_equal BigDecimal("4517.28"), leg.original_amount
    assert_equal "DKK", leg.original_currency
    assert_equal "provider_explicit", leg.field_provenance["amount"]
    assert_equal "inferred", leg.field_provenance["source_balance"]
    assert_equal "inferred", leg.provenance, "the balance is still inferred, so the leg is not exact"
  end

  test "a purchase in a currency without a balance is unresolved and no FX rate is invented" do
    leg = only_leg(card("3005", "<strong>Shop</strong>", "100 GBP"))

    assert_equal "unresolved", leg.provenance
    assert_equal "no_eligible_balance", leg.reason
    assert_nil leg.wise_account
  end

  test "a split-balance payment stays unresolved" do
    leg = only_leg(card("3006", "<strong>Hotel</strong>", "300 CHF", secondary: "EUR, USD"))

    assert_equal "unresolved", leg.provenance
    assert_equal "split_balance_no_per_balance_amounts", leg.reason
  end

  test "a balance opened after the purchase is never used for it" do
    leg = only_leg(card("3007", "<strong>GitHub</strong>", "4 USD", at: "2023-02-01T10:00:00Z"))

    assert_equal "unresolved", leg.provenance
    assert_equal "no_eligible_balance", leg.reason
  end

  test "a closed balance keeps its own period and is not replaced by a later balance" do
    @eur.update!(status: :closed, opened_at: Time.utc(2020, 1, 1), closed_at: Time.utc(2022, 12, 31))
    newer = balance("50009", "EUR", opened: "2023-01-10")

    old_leg = only_leg(card("4001", "<strong>Old shop</strong>", "10 EUR", at: "2022-06-01T10:00:00Z"))
    new_leg = only_leg(card("4002", "<strong>New shop</strong>", "10 EUR", at: "2024-06-01T10:00:00Z"))

    assert_equal @eur, old_leg.wise_account
    assert_equal newer, new_leg.wise_account
  end

  test "two balances of the currency at the same time leave the leg unresolved" do
    balance("50010", "EUR", opened: "2023-01-01", status: :discovered, first: "2024-01-01", last: "2024-12-31")

    leg = only_leg(card("4003", "<strong>Shop</strong>", "10 EUR", at: "2024-06-01T10:00:00Z"))

    assert_equal "unresolved", leg.provenance
    assert_equal "multiple_eligible_balances", leg.reason
  end

  test "card refunds are inflows" do
    leg = only_leg(card("3004", "<strong>GitHub</strong>", "<positive>+ 4 USD</positive>", description: "Refunded"))

    assert_equal "inflow", leg.direction
    assert_equal BigDecimal("-4"), leg.amount
    assert_equal "inferred", leg.provenance
  end

  test "a refund without a credit marker is contradictory" do
    leg = only_leg(card("3011", "<strong>GitHub</strong>", "4 USD", description: "Refunded"))

    assert_equal "unresolved", leg.provenance
    assert_equal "refunded_without_credit_marker", leg.reason
  end

  test "pending and declined card payments are excluded, never imported" do
    pending = only_leg(card("2999", "<strong>Hotel</strong>", "80 EUR", status: "IN_PROGRESS", description: "Pending"))
    declined = only_leg(card("3008", "<strong>Electronics</strong>", "127.27 EUR", status: "CANCELLED", description: "Declined"))
    contradictory = only_leg(card("3012", "<strong>Electronics</strong>", "12 EUR", description: "Declined"))

    assert_equal "pending", pending.excluded_reason
    assert_equal "not_completed_cancelled", declined.excluded_reason
    assert_not contradictory.excluded?
    assert_equal "unresolved", contradictory.provenance
  end

  test "ATM withdrawals are cash withdrawals without a merchant" do
    leg = only_leg(card("3010", "<strong>Posta 4260 Bled</strong>", "122.08 EUR", type: "CASH_WITHDRAWAL"))

    assert_equal "cash_withdrawal", leg.category
    assert_nil leg.merchant_name
    assert_equal BigDecimal("122.08"), leg.amount
  end

  test "card checks have no balance impact" do
    leg = only_leg(card("3009", "<strong>Amazon</strong>", "0 EUR", type: "CARD_CHECK", description: "Card checked"))

    assert_equal "card_check_no_balance_impact", leg.excluded_reason
  end

  # --- incoming payments ------------------------------------------------------------

  test "an incoming payment keeps the credited amount and sender" do
    leg = only_leg(transfer_activity("7900", "<strong>Example Studio d.o.o.</strong>", "<positive>+ 2,500 EUR</positive>"))

    assert_equal "incoming_payment", leg.category
    assert_equal BigDecimal("-2500"), leg.amount
    assert_equal "Example Studio d.o.o.", leg.counterparty_name
    assert_equal @eur, leg.wise_account
    assert_equal "inferred", leg.provenance
  end

  test "an incoming payment to a stated balance is provider explicit" do
    transfers = { "7001" => order("7001", profile: "20002", value: 2500, recipient: { "details" => { "balanceId" => 50001, "targetProfile" => 10001 } }) }

    leg = only_leg(transfer_activity("7001", "<strong>Business</strong>", "<positive>+ 2,500 EUR</positive>"), transfers: transfers)

    assert_equal "provider_explicit", leg.provenance
    assert_equal "7001", leg.transfer_id
    assert_equal "Ref 7001", leg.payment_reference
  end

  test "an incoming amount contradicting the transfer order is unresolved" do
    transfers = { "7002" => order("7002", profile: "20002", value: 2400) }

    leg = only_leg(transfer_activity("7002", "<strong>Business</strong>", "<positive>+ 2,500 EUR</positive>"), transfers: transfers)

    assert_equal "unresolved", leg.provenance
    assert_equal "credit_differs_from_transfer_target_value", leg.reason
  end

  test "a top-up keeps the charged amount as an attribute only" do
    activity = transfer_activity("9101", "<strong>EUR</strong>", "<positive>+ 20 EUR</positive>", type: "BALANCE_DEPOSIT", secondary: "20.08 EUR")

    leg = only_leg(activity)

    assert_equal BigDecimal("-20"), leg.amount
    assert_equal "20.08 EUR", leg.details["secondary_amount_text"]
  end

  # --- outgoing payments --------------------------------------------------------------

  test "an outgoing payment with a zero-fee quote and stated pay-in balance is provider explicit" do
    transfers = { "7101" => order("7101", value: 500, quote: quote(pay_in_id: 50001, fee: 0)) }

    leg = only_leg(transfer_activity("7101", "<strong>John Landlord</strong>", "500 EUR"), transfers: transfers)

    assert_equal "provider_explicit", leg.provenance
    assert_equal BigDecimal("500"), leg.amount
    assert_equal BigDecimal("0"), leg.fee_amount
    assert_equal @eur, leg.wise_account
  end

  test "an outgoing payment total confirmed by the quote fee splits out the fee" do
    transfers = { "7104" => order("7104", value: 110, quote: quote(pay_in_id: 50001, fee: 3)) }

    leg = only_leg(transfer_activity("7104", "<strong>Shop</strong>", "110 EUR", secondary: "113 EUR"), transfers: transfers)

    assert_equal BigDecimal("113"), leg.amount
    assert_equal BigDecimal("3"), leg.fee_amount
    assert_equal "provider_explicit", leg.field_provenance["fee"]
  end

  test "a quote fee without an activity total is contradictory" do
    transfers = { "7105" => order("7105", value: 110, quote: quote(pay_in_id: 50001, fee: 3)) }

    leg = only_leg(transfer_activity("7105", "<strong>Shop</strong>", "110 EUR"), transfers: transfers)

    assert_equal "unresolved", leg.provenance
    assert_equal "quote_fee_without_activity_total", leg.reason
  end

  test "a transfer funded outside Wise has no balance impact" do
    transfers = { "7106" => order("7106", value: 50, quote: quote(pay_in_id: nil, fee: 0, method: "BANK_TRANSFER")) }

    leg = only_leg(transfer_activity("7106", "<strong>Shop</strong>", "50 EUR"), transfers: transfers)

    assert leg.excluded?
  end

  test "an outgoing activity without its transfer order is unresolved" do
    leg = only_leg(transfer_activity("7107", "<strong>Someone</strong>", "50 EUR"))

    assert_equal "unresolved", leg.provenance
    assert_equal "no_transfer_order", leg.reason
  end

  # --- conversions --------------------------------------------------------------------

  test "a conversion yields a debit and a credit leg with stated amounts and no invented fee" do
    activity = { "id" => "conv-1", "type" => "INTERBALANCE", "status" => "COMPLETED",
                 "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "3001" },
                 "title" => "<strong>USD</strong>", "primaryAmount" => "108.03 USD", "secondaryAmount" => "100 EUR",
                 "createdOn" => "2024-05-01T10:00:00Z" }

    source, target = reconstruct([ activity ])

    assert_equal [ BigDecimal("100"), "EUR", @eur ], [ source.amount, source.currency, source.wise_account ]
    assert_equal [ BigDecimal("-108.03"), "USD", @usd ], [ target.amount, target.currency, target.wise_account ]
    assert_equal %w[inferred inferred], [ source.provenance, target.provenance ]
    assert_nil source.fee_amount
    assert_equal "1.0803", source.details["effective_rate"]
    assert_equal "activity:conv-1:target", source.details["counterpart_key"]
  end

  test "same-currency jar moves are left to the jar sync" do
    activity = { "id" => "jar-1", "type" => "INTERBALANCE", "status" => "COMPLETED", "title" => "<strong>Holiday jar</strong>",
                 "primaryAmount" => "200 EUR", "createdOn" => "2024-05-01T10:00:00Z" }

    assert_empty reconstruct([ activity ])
  end

  # --- batches ------------------------------------------------------------------------

  test "a batch is one debit; members are matched by time and never become legs" do
    at = "2024-06-30T15:00:00Z"
    transfers = {
      "8001" => order("8001", profile: "10001", value: 1000, created: "2024-06-30 14:59:30", quote: quote(pay_in_id: 50001, fee: 0.4)),
      "8002" => order("8002", profile: "10001", value: 2000, created: "2024-06-30 15:01:00", quote: quote(pay_in_id: 50001, fee: 0.8)),
      "8003" => order("8003", profile: "10001", value: 999, created: "2024-06-30 18:00:00")
    }
    activity = { "id" => "batch-1", "type" => "BATCH_TRANSFER", "status" => "COMPLETED",
                 "resource" => { "type" => "BATCH_TRANSFER", "id" => "b-1" }, "title" => "<strong>salaries</strong>",
                 "primaryAmount" => "3,000 EUR", "secondaryAmount" => "3,001.20 EUR", "createdOn" => at }

    leg = only_leg(activity, transfers: transfers)

    assert_equal BigDecimal("3001.20"), leg.amount
    assert_equal BigDecimal("1.20"), leg.fee_amount
    assert_equal %w[8001 8002], leg.details["member_transfer_ids"]
    assert leg.details["members_match_total"]
    assert_equal "provider_explicit", leg.provenance
  end

  test "a batch with a refunded member is unresolved" do
    transfers = { "8101" => order("8101", profile: "10001", value: 400, created: "2024-07-01 10:00:00", status: "funds_refunded") }
    activity = { "id" => "batch-2", "type" => "BATCH_TRANSFER", "status" => "COMPLETED", "title" => "<strong>refund_case</strong>",
                 "primaryAmount" => "400 EUR", "createdOn" => "2024-07-01T10:00:00Z" }

    leg = only_leg(activity, transfers: transfers)

    assert_equal "unresolved", leg.provenance
    assert_equal "batch_member_refunded_refund_leg_not_visible", leg.reason
  end

  test "a multi-currency batch is summed per currency from its members" do
    transfers = {
      "8201" => order("8201", profile: "10001", value: 100, created: "2024-08-01 10:00:00", quote: quote(pay_in_id: 50001, fee: 1)),
      "8202" => order("8202", profile: "10001", value: 50, currency: "USD", created: "2024-08-01 10:00:10", quote: quote(pay_in_id: 50002, fee: 0.5, currency: "USD"))
    }
    activity = { "id" => "batch-3", "type" => "BATCH_TRANSFER", "status" => "COMPLETED", "title" => "<strong>mixed</strong>",
                 "primaryAmount" => "EUR, USD", "createdOn" => "2024-08-01T10:00:00Z" }

    eur_leg, usd_leg = reconstruct([ activity ], transfers: transfers)

    assert_equal [ BigDecimal("101"), "EUR", @eur ], [ eur_leg.amount, eur_leg.currency, eur_leg.wise_account ]
    assert_equal [ BigDecimal("50.5"), "USD", @usd ], [ usd_leg.amount, usd_leg.currency, usd_leg.wise_account ]
    assert_equal "inferred", eur_leg.provenance
  end

  test "unknown completed activity types are kept for review" do
    leg = only_leg({ "id" => "dd-1", "type" => "DIRECT_DEBIT_TRANSACTION", "status" => "COMPLETED",
                     "primaryAmount" => "9.99 EUR", "createdOn" => "2024-05-01T10:00:00Z" })

    assert_equal "unresolved", leg.provenance
    assert_equal "unsupported_activity_type", leg.reason
  end

  private
    def balance(id, currency, opened:, status: :active, first: nil, last: nil)
      @wise_item.wise_accounts.create!(
        balance_id: id, currency: currency, name: "Wise #{currency}", raw_payload: { "type" => "STANDARD" },
        status: status, opened_at: Time.zone.parse(opened),
        first_observed_at: first && Time.zone.parse(first), last_observed_at: last && Time.zone.parse(last)
      )
    end

    def reconstruct(activities, transfers: {})
      WiseItem::LedgerReconstructor.new(
        wise_item: @wise_item,
        registry: WiseItem::BalanceRegistry.new(@wise_item.wise_accounts.reload),
        transfers: transfers,
        own_profiles: { "10001" => "personal", "20002" => "business" }
      ).legs(activities)
    end

    def only_leg(activity, transfers: {})
      legs = reconstruct([ activity ], transfers: transfers)
      assert_equal 1, legs.size
      legs.first
    end

    def card(id, title, primary, secondary: "", status: "COMPLETED", description: "", type: "CARD_PAYMENT", at: "2024-05-01T10:00:00Z")
      { "id" => "card-#{id}", "type" => type, "resource" => { "type" => "CARD_TRANSACTION", "id" => id },
        "title" => title, "description" => description, "primaryAmount" => primary, "secondaryAmount" => secondary,
        "status" => status, "createdOn" => at }
    end

    def transfer_activity(id, title, primary, secondary: "", type: "TRANSFER")
      { "id" => "tr-#{id}", "type" => type, "resource" => { "type" => "TRANSFER", "id" => id },
        "title" => title, "description" => "", "primaryAmount" => primary, "secondaryAmount" => secondary,
        "status" => "COMPLETED", "createdOn" => "2024-05-01T10:00:00Z" }
    end

    def order(id, value:, profile: "10001", currency: "EUR", created: "2024-05-01 09:59:00", status: "outgoing_payment_sent", quote: nil, recipient: nil)
      {
        "profile_id" => profile,
        "transfer" => { "id" => id.to_i, "status" => status, "created" => created, "reference" => "Ref #{id}",
                        "sourceCurrency" => currency, "sourceValue" => value, "targetCurrency" => currency, "targetValue" => value },
        "quote" => quote,
        "recipient" => recipient
      }
    end

    def quote(pay_in_id:, fee:, method: "BALANCE", currency: "EUR")
      { "payInId" => pay_in_id, "payInMethod" => method, "payOut" => "BANK_TRANSFER",
        "paymentOptions" => [ { "payIn" => method, "payOut" => "BANK_TRANSFER", "fee" => { "total" => fee }, "sourceCurrency" => currency } ] }
    end
end
