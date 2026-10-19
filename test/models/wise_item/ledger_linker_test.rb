require "test_helper"

class WiseItem::LedgerLinkerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @personal = WiseItem.create!(family: @family, name: "Personal", token: "t", profile_id: "10001", profile_type: :personal)
    @business = WiseItem.create!(family: @family, name: "Business", token: "t", profile_id: "20002", profile_type: :business)
    @personal_eur = linked_balance(@personal, "50001", "EUR")
    @personal_usd = linked_balance(@personal, "50002", "USD")
    @business_eur = linked_balance(@business, "60001", "EUR")
  end

  test "a conversion between own balances becomes a confirmed transfer, not income or expense" do
    source = leg(@personal, "activity:c1:source", "currency_conversion", 100, "EUR", @personal_eur,
                 details: { "conversion_leg" => "source", "counterpart_key" => "activity:c1:target" })
    target = leg(@personal, "activity:c1:target", "currency_conversion", -108.03, "USD", @personal_usd,
                 details: { "conversion_leg" => "target", "counterpart_key" => "activity:c1:source" })

    process

    assert_equal "currency_conversion", source.reload.relationship["type"]
    assert_equal target.id, source.relationship["counterpart_id"]
    transfer = Transfer.find_by(outflow_transaction: source.entry.transaction)
    assert transfer.confirmed?
    assert_equal target.reload.entry.transaction, transfer.inflow_transaction
    assert_equal "funds_movement", source.entry.transaction.reload.kind
    assert_equal "funds_movement", target.entry.transaction.reload.kind
  end

  test "business to personal keeps both legs as income and expense by default" do
    debit = leg(@business, "activity:b1", "outgoing_payment", 2500, "EUR", @business_eur, resource: [ "TRANSFER", "7001" ])
    credit = leg(@personal, "activity:p1", "incoming_payment", -2500, "EUR", @personal_eur, resource: [ "TRANSFER", "7001" ])

    process

    assert_equal "business_to_personal", credit.reload.relationship["type"]
    assert_equal "confirmed", credit.relationship["status"]
    assert_nil Transfer.find_by(inflow_transaction: credit.entry.transaction)
    assert_equal "standard", credit.entry.transaction.kind
    assert_equal "business_to_personal", credit.entry.transaction.extra.dig("wise", "relationship", "type")
    assert_equal "business_to_personal", debit.reload.relationship["type"]
  end

  test "business to personal can be linked as a transfer when configured" do
    debit = leg(@business, "activity:b1", "outgoing_payment", 2500, "EUR", @business_eur, resource: [ "TRANSFER", "7001" ])
    credit = leg(@personal, "activity:p1", "incoming_payment", -2500, "EUR", @personal_eur, resource: [ "TRANSFER", "7001" ])

    with_link_own_profile_transfers do
      process
    end

    assert Transfer.exists?(outflow_transaction: debit.reload.entry.transaction, inflow_transaction: credit.reload.entry.transaction)
  end

  test "a salary credit from an own batch member is tied to the batch without a second debit" do
    leg(@business, "activity:batch-1", "batch_payment", 3001.2, "EUR", @business_eur)
    order = leg(@business, "transfer:8001", "transfer_order", 1000, "EUR", nil, status: :excluded, resource: [ "TRANSFER", "8001" ])
    order.update!(relationship: { "type" => "batch_member", "status" => "high_confidence", "batch_key" => "activity:batch-1" })
    credit = leg(@personal, "activity:p2", "incoming_payment", -1000, "EUR", @personal_eur, resource: [ "TRANSFER", "8001" ])

    process

    assert_equal "business_to_personal", credit.reload.relationship["type"]
    assert_equal "activity:batch-1", credit.relationship["batch_key"]
    assert_not Transfer.exists?(inflow_transaction: credit.entry.transaction)
  end

  test "a payment to the customer's own external account is marked but no leg is invented" do
    debit = leg(@personal, "activity:o1", "outgoing_payment", 300, "EUR", @personal_eur, resource: [ "TRANSFER", "7300" ],
                details: { "recipient_owned_by_customer" => true })

    assert_no_difference -> { Entry.count } do
      WiseItem::LedgerLinker.new(@family).annotate!
    end

    assert_equal "own_account_transfer", debit.reload.relationship["type"]
    assert_equal "unmatched", debit.relationship["status"]
  end

  test "a card refund is related to the earlier purchase at the same merchant" do
    purchase = leg(@personal, "activity:card-1", "card_payment", 4, "USD", @personal_usd, merchant: "GitHub", at: Time.utc(2024, 5, 1))
    refund = leg(@personal, "activity:card-2", "card_payment", -4, "USD", @personal_usd, merchant: "GITHUB", at: Time.utc(2024, 5, 10))

    WiseItem::LedgerLinker.new(@family).annotate!

    assert_equal "refund", refund.reload.relationship["type"]
    assert_equal purchase.id, refund.relationship["counterpart_id"]
    assert_equal "full", refund.relationship["refund_type"]
  end

  private
    def linked_balance(item, balance_id, currency)
      wise_account = item.wise_accounts.create!(balance_id: balance_id, currency: currency, name: "Wise #{currency}", raw_payload: { "type" => "STANDARD" })
      account = @family.accounts.create!(name: "#{item.name} #{currency}", balance: 0, currency: currency, accountable: Depository.new)
      AccountProvider.create!(account: account, provider: wise_account)
      wise_account
    end

    def leg(item, key, category, amount, currency, wise_account, status: :ready, resource: nil, details: {}, merchant: nil, at: Time.utc(2024, 5, 1, 10))
      ProviderLedgerRecord.create!(
        family: @family, provider_key: "wise", item: item, provider_account: wise_account, external_key: key,
        category: category, provenance: "inferred", status: status, occurred_at: at, amount: amount, currency: currency,
        original_amount: amount.abs, original_currency: currency, merchant_name: merchant,
        provider_resource_type: resource&.first, provider_resource_id: resource&.last, details: details,
        provider_transfer_id: category == "transfer_order" ? resource&.last : nil
      )
    end

    def process
      @business.process_ledger_records
      @personal.process_ledger_records
    end

    def with_link_own_profile_transfers
      previous = Rails.configuration.x.wise.link_own_profile_transfers
      Rails.configuration.x.wise.link_own_profile_transfers = true
      yield
    ensure
      Rails.configuration.x.wise.link_own_profile_transfers = previous
    end
end
