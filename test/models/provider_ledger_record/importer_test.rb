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

  test "adopts an entry an earlier sync created without renaming it" do
    legacy = create_entry(amount: 23.45, external_id: "wise_transfer_7101", source: "wise")
    record = build_record(amount: 23.45)

    assert_no_difference -> { @account.entries.count } do
      import(record, legacy_external_ids: [ "wise_transfer_7101" ])
      import(record.reload, legacy_external_ids: [ "wise_transfer_7101" ])
    end

    assert_equal legacy.id, record.reload.entry_id
    assert_equal "wise_transfer_7101", legacy.reload.external_id, "older code must still find the entry under its id"
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

  test "a superseded record keeps its entry and its id" do
    record = build_record(amount: 23.45)
    import(record)

    ProviderLedgerRecord::Importer.new(record.reload, account: @account, source: "wise").supersede!

    assert record.reload.superseded?
    assert_equal "wise_activity_card-1", record.entry.external_id
  end

  test "a manual entry for the full debit is claimed without adding the fee on top" do
    manual = create_entry(amount: 113)
    record = build_record(amount: 113, fee_amount: 3, fee_currency: "EUR")

    assert_no_difference -> { @account.entries.count } do
      assert_equal :imported, import(record)
    end
    assert_equal manual.id, record.reload.entry_id
    assert_equal BigDecimal("113"), manual.reload.amount
    assert_nil record.fee_entry
  end

  test "a manual principal and a manual fee are both claimed" do
    principal = create_entry(amount: 110)
    fee = create_entry(amount: 3)
    record = build_record(amount: 113, fee_amount: 3, fee_currency: "EUR")

    assert_no_difference -> { @account.entries.count } do
      import(record)
    end
    assert_equal [ principal.id, fee.id ], [ record.reload.entry_id, record.fee_entry_id ]
  end

  test "a nearby manual entry is claimed when its name matches the merchant" do
    manual = create_entry(amount: 23.45, date: Date.new(2024, 5, 2), name: "LIDL MARIBOR")
    record = build_record(amount: 23.45)

    assert_equal :imported, import(record, match_terms: [ "Lidl" ])
    assert_equal manual.id, record.reload.entry_id
  end

  test "of two same-day candidates the one named like the movement is claimed" do
    create_entry(amount: 23.45, name: "Coffee")
    named = create_entry(amount: 23.45, name: "Rent - INV-77")
    record = build_record(amount: 23.45)

    import(record, match_terms: [ "John Landlord", "INV-77" ])

    assert_equal named.id, record.reload.entry_id
  end

  test "an unrelated nearby entry with the same amount is not merged" do
    create_entry(amount: 23.45, date: Date.new(2024, 5, 3), name: "Pharmacy")
    record = build_record(amount: 23.45)

    assert_equal :needs_review, import(record, match_terms: [ "Lidl" ])
  end

  test "a deleted fee entry is not recreated and the principal stays as it was" do
    record = build_record(amount: 113, fee_amount: 3, fee_currency: "EUR")
    import(record)
    record.reload.fee_entry.destroy!

    assert_no_difference -> { @account.entries.count } do
      assert_equal :imported, import(record.reload)
    end
    assert_equal BigDecimal("110"), record.reload.entry.amount
    assert record.fee_deleted_by_user?
  end

  test "moves the entry with the user's edits when the movement is reassigned to another balance" do
    record = build_record(amount: 23.45)
    first_wise_account = linked_wise_account(@account, "50001")
    record.update!(provider_account: first_wise_account)
    import(record)
    entry = record.reload.entry
    category = @family.categories.create!(name: "Groceries", color: "#407706")
    tag = @family.tags.create!(name: "trip")
    entry.update!(notes: "kept")
    entry.transaction.update!(category: category, tags: [ tag ])

    other = @family.accounts.create!(name: "Wise EUR (old)", balance: 0, currency: "EUR", accountable: Depository.new)
    record.update!(provider_account: linked_wise_account(other, "50009"))

    assert_no_difference -> { Entry.count } do
      ProviderLedgerRecord::Importer.new(record.reload, account: other, source: "wise").import(name: "Lidl")
    end

    entry.reload
    assert_equal other, entry.account
    assert_equal [ "kept", category, [ tag ] ], [ entry.notes, entry.transaction.category, entry.transaction.tags.to_a ]
    assert_empty @account.entries.where(source: "wise")
  end

  test "a relink by the user imports afresh and leaves the old account's entries alone" do
    record = build_record(amount: 23.45)
    wise_account = linked_wise_account(@account, "50001")
    record.update!(provider_account: wise_account)
    import(record)
    old_entry = record.reload.entry

    new_account = @family.accounts.create!(name: "New EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    ProviderLedgerRecord::Importer.new(record, account: new_account, source: "wise").import(name: "Lidl")

    assert old_entry.reload.persisted?
    assert_equal new_account, record.reload.entry.account
  end

  test "withdrawing a categorized entry excludes it but keeps the user's category" do
    record = build_record(amount: 23.45)
    import(record)
    entry = record.reload.entry
    category = @family.categories.create!(name: "Shopping", color: "#407706")
    entry.update!(user_modified: true)
    entry.transaction.update!(category: category)

    ProviderLedgerRecord::Importer.new(record, account: @account, source: "wise").withdraw!("not_completed_cancelled")

    assert entry.reload.excluded?
    assert_equal category, entry.transaction.category
  end

  test "an amount correction updates the entry" do
    record = build_record(amount: 23.45)
    import(record)

    record.reload.update!(amount: 25)
    import(record)

    assert_equal BigDecimal("25"), record.reload.entry.amount
  end

  test "an operator can point a possible duplicate at the right entry or import it anyway" do
    first = create_entry(amount: 23.45, date: Date.new(2024, 5, 2))
    record = build_record(amount: 23.45)
    assert_equal :needs_review, import(record)

    record.update!(details: record.details.merge("resolution" => { "link_entry_id" => first.id }))
    assert_no_difference -> { @account.entries.count } do
      assert_equal :imported, import(record)
    end
    assert_equal first.id, record.reload.entry_id

    other = build_record(amount: 23.45, external_key: "activity:card-2")
    other.update!(details: { "resolution" => { "force_new" => true } })
    assert_difference -> { @account.entries.count }, 1 do
      assert_equal :imported, import(other)
    end
  end

  private
    def build_record(amount: 10, provenance: "inferred", external_key: "activity:card-1", **attrs)
      ProviderLedgerRecord.create!(
        family: @family, provider_key: "wise", item: @item, external_key: external_key,
        category: "card_payment", provenance: provenance, occurred_at: Time.utc(2024, 5, 1, 10),
        amount: amount, currency: "EUR", **attrs
      )
    end

    def import(record, name: "Lidl", legacy_external_ids: [], match_terms: [])
      ProviderLedgerRecord::Importer.new(record, account: @account, source: "wise").import(
        name: name,
        extra: { "wise" => { "provenance" => record.provenance } },
        legacy_external_ids: legacy_external_ids,
        match_terms: match_terms,
        fee_name: "Wise fee"
      )
    end

    def linked_wise_account(account, balance_id)
      wise_account = @item.wise_accounts.create!(balance_id: balance_id, currency: "EUR", name: "Wise EUR", raw_payload: { "type" => "STANDARD" })
      AccountProvider.create!(account: account, provider: wise_account)
      wise_account
    end

    def create_entry(amount:, date: Date.new(2024, 5, 1), external_id: nil, source: nil, name: "Imported")
      @account.entries.create!(
        name: name, date: date, amount: amount, currency: "EUR",
        external_id: external_id, source: source, entryable: Transaction.new
      )
    end
end
