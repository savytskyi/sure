require "test_helper"

class ProviderLedgerRecord::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Wise EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    @item = WiseItem.create!(family: @family, name: "Wise", token: "t", profile_id: "10001", profile_type: :personal)
  end

  test "imports an inferred record once and records the entry" do
    record = build_record(amount: 23.45)

    assert_difference -> { @account.entries.count }, 1 do
      assert_equal :imported, import(record)
      assert_equal :imported, import(record.reload)
    end

    entry = record.reload.entry
    assert record.imported?
    assert_equal "wise_activity_card-1", entry.external_id
    assert_equal BigDecimal("23.45"), entry.amount
    assert_equal "inferred", entry.transaction.extra.dig("wise", "provenance")
  end

  test "never imports unresolved records" do
    record = build_record(provenance: "unresolved")

    assert_no_difference -> { @account.entries.count } do
      assert_equal :skipped, import(record)
    end
  end

  test "splits a known fee out of an outflow" do
    record = build_record(amount: 113, fee_amount: 3, fee_currency: "EUR")

    import(record)

    assert_equal BigDecimal("110"), record.reload.entry.amount
    fee = @account.entries.find_by(external_id: "wise_activity_card-1_fee")
    assert_equal BigDecimal("3"), fee.amount
    assert_equal "Wise fee", fee.name
  end

  test "claims an entry an earlier sync created under a legacy id" do
    legacy = create_entry(amount: 23.45, external_id: "wise_transfer_7101", source: "wise")
    record = build_record(amount: 23.45)

    assert_no_difference -> { @account.entries.count } do
      import(record, legacy_external_ids: [ "wise_transfer_7101" ])
    end

    assert_equal legacy.id, record.reload.entry_id
    assert_equal "wise_activity_card-1", legacy.reload.external_id
  end

  test "claims a single same-day manual or YNAB entry with the same amount" do
    manual = create_entry(amount: 23.45)
    record = build_record(amount: 23.45)

    assert_no_difference -> { @account.entries.count } do
      assert_equal :imported, import(record)
    end
    assert_equal manual.id, record.reload.entry_id
  end

  test "leaves ambiguous duplicates for review" do
    first = create_entry(amount: 23.45, date: Date.new(2024, 5, 2))
    record = build_record(amount: 23.45)

    assert_no_difference -> { @account.entries.count } do
      assert_equal :needs_review, import(record)
    end
    assert_equal "possible_duplicate", record.reload.reason
    assert_equal [ first.id ], record.details["duplicate_candidate_entry_ids"]
  end

  test "does not recreate an entry the user deleted" do
    record = build_record(amount: 23.45)
    import(record)
    record.reload.entry.destroy!

    assert_no_difference -> { @account.entries.count } do
      assert_equal :dismissed, import(record.reload)
      assert_equal :dismissed, import(record.reload)
    end
    assert record.reload.dismissed?
  end

  test "keeps user corrections to category, merchant, notes and name" do
    record = build_record(amount: 23.45)
    import(record)
    entry = record.reload.entry
    category = @family.categories.create!(name: "Groceries", color: "#407706")
    merchant = FamilyMerchant.create!(family: @family, name: "My Lidl")
    entry.update!(name: "Weekly shop", notes: "kept", user_modified: true)
    entry.transaction.update!(category: category, merchant: merchant)
    entry.transaction.lock_saved_attributes!

    record.update!(name: "LIDL", amount: 24)
    import(record, name: "LIDL")

    entry.reload
    assert_equal "Weekly shop", entry.name
    assert_equal "kept", entry.notes
    assert_equal category, entry.transaction.category
    assert_equal merchant, entry.transaction.merchant
  end

  test "excludes rather than deletes a withdrawn entry" do
    record = build_record(amount: 23.45)
    import(record)

    ProviderLedgerRecord::Importer.new(record.reload, account: @account, source: "wise").withdraw!("not_completed_cancelled")

    assert record.reload.withdrawn?
    assert record.entry.excluded?
  end

  test "hands an imported entry over to its verified statement line" do
    record = build_record(amount: 23.45)
    import(record)

    ProviderLedgerRecord::Importer.new(record.reload, account: @account, source: "wise").supersede!("wise_statement_CARD-1")

    assert record.reload.superseded?
    assert_equal "wise_statement_CARD-1", record.entry.external_id
  end

  private
    def build_record(amount: 10, provenance: "inferred", **attrs)
      ProviderLedgerRecord.create!(
        family: @family, provider_key: "wise", item: @item, external_key: "activity:card-1",
        category: "card_payment", provenance: provenance, occurred_at: Time.utc(2024, 5, 1, 10),
        amount: amount, currency: "EUR", **attrs
      )
    end

    def import(record, name: "Lidl", legacy_external_ids: [])
      ProviderLedgerRecord::Importer.new(record, account: @account, source: "wise").import(
        name: name,
        extra: { "wise" => { "provenance" => record.provenance } },
        legacy_external_ids: legacy_external_ids,
        fee_name: "Wise fee"
      )
    end

    def create_entry(amount:, date: Date.new(2024, 5, 1), external_id: nil, source: nil)
      @account.entries.create!(
        name: "Imported", date: date, amount: amount, currency: "EUR",
        external_id: external_id, source: source, entryable: Transaction.new
      )
    end
end
