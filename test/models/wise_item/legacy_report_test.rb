require "test_helper"

class WiseItem::LegacyReportTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = WiseItem.create!(family: @family, name: "Wise", token: "t", profile_id: "10001", profile_type: :personal)
    @eur = @family.accounts.create!(name: "EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    @gbp = @family.accounts.create!(name: "GBP", balance: 0, currency: "GBP", accountable: Depository.new)
  end

  test "classifies old connector entries and proposes corrections without changing anything" do
    adopted = legacy(@eur, "wise_transfer_1", 50)
    record(key: "activity:a1", resource: [ "TRANSFER", "1" ], entry: adopted, amount: 50)

    cancelled = legacy(@eur, "wise_transfer_2", 20)
    order("2", status: "cancelled")

    duplicate = legacy(@gbp, "wise_transfer_3", 30)
    fee = legacy(@eur, "wise_fee_3", 1)
    reconstructed = legacy(@eur, "wise_activity_a3", 30, external: true)
    reconstructed_fee = legacy(@eur, "wise_activity_a3_fee", 1, external: true)
    record(key: "activity:a3", resource: [ "TRANSFER", "3" ], entry: reconstructed, fee_entry: reconstructed_fee, amount: 31, fee: 1)

    member = legacy(@eur, "wise_transfer_4", 1000)
    order("4", status: "outgoing_payment_sent", relationship: { "type" => "batch_member", "batch_key" => "activity:b1" })

    misrouted = legacy(@gbp, "wise_interbalance_77_outflow", 100)
    record(key: "activity:c1:source", resource: [ "BALANCE_TRANSACTION", "77" ], amount: 100)

    unknown = legacy(@eur, "wise_transfer_5", 10)

    report = WiseItem::LegacyReport.new(@family)
    by_entry = report.findings.to_h { |f| [ f.entry.id, [ f.finding, f.action ] ] }

    assert_equal [ "adopted", "none" ], by_entry[adopted.id]
    assert_equal [ "cancelled_transfer", "exclude" ], by_entry[cancelled.id]
    assert_equal [ "duplicate_of_reconstructed_leg", "exclude" ], by_entry[duplicate.id]
    assert_equal [ "duplicate_fee", "exclude" ], by_entry[fee.id]
    assert_equal [ "batch_member_counted_in_batch_debit", "exclude" ], by_entry[member.id]
    assert_equal [ "misrouted_conversion_or_jar_move", "exclude" ], by_entry[misrouted.id]
    assert_equal [ "no_reconstructed_leg", "review" ], by_entry[unknown.id]
    assert_not by_entry.key?(reconstructed.id), "entries the new sync created are not legacy"
    assert_includes report.to_csv, "duplicate_fee"
    assert_not Entry.where(excluded: true).exists?(account_id: [ @eur.id, @gbp.id ])
  end

  test "flags an adopted entry the user changed to a different amount" do
    entry = legacy(@eur, "wise_transfer_1", 55)
    entry.update!(user_modified: true)
    record(key: "activity:a1", resource: [ "TRANSFER", "1" ], entry: entry, amount: 50)

    assert_equal "adopted_user_modified_differs", WiseItem::LegacyReport.new(@family).findings.sole.finding
  end

  private
    def legacy(account, external_id, amount, external: false)
      account.entries.create!(name: "Wise", date: Date.new(2024, 5, 1), amount: amount, currency: account.currency,
                              external_id: external_id, source: "wise", entryable: Transaction.new)
    end

    def record(key:, resource:, amount:, entry: nil, fee_entry: nil, fee: nil)
      ProviderLedgerRecord.create!(family: @family, provider_key: "wise", item: @item, external_key: key, category: "outgoing_payment",
                                   provenance: "inferred", status: entry ? :imported : :ready, amount: amount, currency: "EUR",
                                   fee_amount: fee, fee_currency: fee && "EUR", entry: entry, fee_entry: fee_entry,
                                   provider_resource_type: resource.first, provider_resource_id: resource.last)
    end

    def order(id, status:, relationship: {})
      ProviderLedgerRecord.create!(family: @family, provider_key: "wise", item: @item, external_key: "transfer:#{id}", category: "transfer_order",
                                   provenance: "provider_explicit", status: :excluded, provider_transfer_id: id,
                                   relationship: relationship, details: { "transfer_status" => status })
    end
end
