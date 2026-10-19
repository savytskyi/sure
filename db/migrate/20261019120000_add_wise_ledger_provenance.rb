class AddWiseLedgerProvenance < ActiveRecord::Migration[8.1]
  def change
    # Provider-reconstructed ledger legs with explicit provenance. Records that
    # cannot be imported safely (unresolved, possible duplicates) stay here for
    # review instead of reaching the ledger. Generic so other providers that
    # reconstruct transactions from non-statement data can reuse it.
    create_table :provider_ledger_records, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false
      t.references :item, type: :uuid, polymorphic: true, null: false
      t.references :provider_account, type: :uuid, polymorphic: true
      t.string :external_key, null: false
      t.string :category, null: false
      t.string :provenance, null: false
      t.string :status, null: false, default: "ready"
      t.string :reason
      t.jsonb :field_provenance, null: false, default: {}
      t.datetime :occurred_at
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency
      t.decimal :fee_amount, precision: 19, scale: 4
      t.string :fee_currency
      t.decimal :original_amount, precision: 19, scale: 4
      t.string :original_currency
      t.string :provider_resource_type
      t.string :provider_resource_id
      t.string :provider_transfer_id
      t.string :name
      t.string :counterparty_name
      t.string :merchant_name
      t.string :payment_reference
      t.jsonb :relationship, null: false, default: {}
      t.jsonb :details, null: false, default: {}
      t.jsonb :raw_payload
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.datetime :imported_at
      # A fee imported as its own entry, tracked separately so deleting just
      # the fee is remembered too.
      t.references :fee_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }
      t.datetime :fee_imported_at
      t.timestamps
    end

    add_index :provider_ledger_records, [ :item_type, :item_id, :external_key ], unique: true, name: "index_provider_ledger_records_on_item_and_external_key"
    add_index :provider_ledger_records, [ :family_id, :provider_key, :provider_transfer_id ], name: "index_provider_ledger_records_on_transfer"
    add_index :provider_ledger_records, [ :family_id, :status ]

    # Per-resource sync checkpoints ({ "activities" => { "covered_to" => ... } }).
    add_column :wise_items, :sync_checkpoints, :jsonb, null: false, default: {}

    # Balance lifetime, so historical transactions are never routed to a
    # balance that did not exist yet (or any more) at the time.
    add_column :wise_accounts, :status, :string, null: false, default: "active"
    add_column :wise_accounts, :opened_at, :datetime
    add_column :wise_accounts, :closed_at, :datetime
    add_column :wise_accounts, :first_observed_at, :datetime
    add_column :wise_accounts, :last_observed_at, :datetime
  end
end
