class CreateDerivativePositionsAndLedgerEvents < ActiveRecord::Migration[8.1]
  def change
    # Open and closed derivatives positions as a provider reports them. A
    # position is exposure, not an asset: its notional value is never part of
    # an account balance (the margin it uses already is), so it lives here
    # rather than as a holding. One row per episode: a position that closes
    # and later reopens on the same symbol and side gets a new row.
    create_table :derivative_positions, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false
      t.references :item, type: :uuid, polymorphic: true, null: false
      t.references :provider_account, type: :uuid, polymorphic: true
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :market, null: false
      t.string :symbol, null: false
      t.string :position_side, null: false, default: "BOTH"
      t.string :status, null: false, default: "open"
      t.string :contract_type
      t.string :margin_asset
      t.string :margin_type
      # Signed: positive long, negative short. In contracts when
      # quantity_unit is "contracts" (each worth contract_size of
      # contract_size_currency), otherwise in the base asset.
      t.decimal :quantity, precision: 36, scale: 18, null: false
      t.string :quantity_unit, null: false
      t.decimal :contract_size, precision: 36, scale: 18
      t.string :contract_size_currency
      t.decimal :entry_price, precision: 36, scale: 18
      t.decimal :break_even_price, precision: 36, scale: 18
      t.decimal :mark_price, precision: 36, scale: 18
      t.decimal :liquidation_price, precision: 36, scale: 18
      t.string :price_currency
      t.decimal :notional, precision: 36, scale: 18
      t.string :notional_currency
      t.decimal :unrealized_pnl, precision: 36, scale: 18
      t.string :unrealized_pnl_currency
      t.decimal :isolated_margin, precision: 36, scale: 18
      t.decimal :leverage, precision: 12, scale: 4
      t.datetime :opened_at
      t.datetime :closed_at
      t.datetime :first_observed_at, null: false
      t.datetime :last_observed_at, null: false
      t.datetime :provider_updated_at
      t.jsonb :raw_payload
      t.timestamps
    end

    add_index :derivative_positions, [ :item_type, :item_id, :market, :symbol, :position_side ],
              unique: true, where: "status = 'open'", name: "index_derivative_positions_one_open_per_side"
    add_index :derivative_positions, [ :family_id, :status ]

    # Wallet movements of a derivatives account (realized P&L, funding,
    # commissions, transfers, settlements, ...) in the asset they were paid
    # in, at full precision. Kept apart from provider_ledger_records, whose
    # amounts are 4-decimal cash: a COIN-M funding payment of 0.00000123 BTC
    # would round to nothing there.
    create_table :derivative_ledger_events, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false
      t.references :item, type: :uuid, polymorphic: true, null: false
      t.references :provider_account, type: :uuid, polymorphic: true
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :market, null: false
      t.string :external_key, null: false
      t.string :category, null: false
      t.string :provider_type, null: false
      t.string :status, null: false, default: "ready"
      t.string :reason
      t.string :symbol
      t.string :asset, null: false
      # Provider sign: positive credits the wallet, negative debits it.
      t.decimal :amount, precision: 36, scale: 18, null: false
      t.datetime :occurred_at, null: false
      t.string :provider_transaction_id
      t.string :provider_trade_id
      t.string :info
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.datetime :imported_at
      t.jsonb :raw_payload
      t.timestamps
    end

    add_index :derivative_ledger_events, [ :item_type, :item_id, :external_key ], unique: true,
              name: "index_derivative_ledger_events_on_item_and_external_key"
    add_index :derivative_ledger_events, [ :account_id, :occurred_at ]
    add_index :derivative_ledger_events, [ :family_id, :status ]
  end
end
