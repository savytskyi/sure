# frozen_string_literal: true

# One wallet movement of a derivatives account, in the asset it was paid in.
# Provider-independent; the provider's own identifier is `external_key`.
#
# Categories that change what the account holds (realized P&L, funding,
# commissions and rebates, settlements, liquidation fees, conversions,
# bonuses) reach the ledger through DerivativeLedgerEvent::EntryWriter as
# quantity changes of the asset, never as cash. Transfers between the
# provider's own wallets are kept but excluded: both wallets belong to the
# same Sure account, so the move changes nothing there. A type the
# integration does not know waits for review instead of being guessed.
#
# Unrealized P&L is never an event: it is part of the current balance until
# a realized P&L or settlement event says otherwise.
class DerivativeLedgerEvent < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
  end

  CATEGORIES = %w[
    realized_pnl funding commission rebate settlement liquidation conversion bonus transfer unknown
  ].freeze
  EXCLUDED_CATEGORIES = %w[transfer].freeze

  enum :status, {
    ready: "ready",               # changes the balance, not in the ledger yet
    imported: "imported",         # part of `entry`
    excluded: "excluded",         # no effect on the Sure account (own-wallet transfer)
    needs_review: "needs_review", # a type the integration does not recognise
    dismissed: "dismissed"        # the user deleted the entry; never re-import
  }, validate: true

  belongs_to :family
  belongs_to :item, polymorphic: true
  belongs_to :provider_account, polymorphic: true, optional: true
  belongs_to :account, optional: true
  belongs_to :entry, optional: true

  validates :provider_key, :market, :external_key, :provider_type, :asset, presence: true
  validates :amount, :occurred_at, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :external_key, uniqueness: { scope: [ :item_type, :item_id ] }

  scope :for_provider, ->(key) { where(provider_key: key) }
  scope :importable, -> { where(status: %i[ready imported]) }

  def self.initial_status_for(category)
    return :excluded if EXCLUDED_CATEGORIES.include?(category)
    return :needs_review if category == "unknown"

    :ready
  end

  # The provider account now feeds another Sure account (relinked, or the old
  # one was deleted): its events start over there. What was imported or
  # dismissed belonged to the old account's ledger.
  def self.reassign!(provider_account:, account:)
    stale = where(provider_account: provider_account).where("account_id IS DISTINCT FROM ?", account.id)
    stale.where(status: %w[imported dismissed]).update_all(status: "ready", reason: nil, entry_id: nil, imported_at: nil, updated_at: Time.current)
    stale.update_all(account_id: account.id, updated_at: Time.current)
  end

  # Imported once, and the entry is gone while the account still exists: the
  # user deleted it. (Removing the whole account drops account_id too.)
  def deleted_by_user?
    imported_at.present? && entry_id.nil? && account_id.present?
  end
end
