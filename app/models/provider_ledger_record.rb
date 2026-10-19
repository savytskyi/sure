# frozen_string_literal: true

# A ledger leg a provider integration reconstructed from non-statement data
# (activity feeds, transfer orders, quotes), together with how much of it the
# provider actually stated.
#
# Provenance:
# - provider_explicit: the provider states the balance impact and the balance.
# - inferred:          the impact is stated, a deterministic rule picked the
#                      balance (or summed stated parts).
# - unresolved:        essential information is missing or contradictory.
# - user_confirmed:    an operator resolved an unresolved leg by hand
#                      (balance, amount); never mistaken for provider data.
#
# Only provider_explicit, inferred and user_confirmed records are imported;
# unresolved ones (and possible duplicates) stay here with status
# needs_review. Field-level provenance lives in `field_provenance`
# ({ "amount" => "provider_explicit", "source_balance" => "inferred", ... }).
class ProviderLedgerRecord < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
  end

  PROVENANCES = %w[provider_explicit inferred unresolved user_confirmed].freeze
  IMPORTABLE_PROVENANCES = %w[provider_explicit inferred user_confirmed].freeze

  enum :status, {
    ready: "ready",               # importable, not in the ledger yet
    imported: "imported",         # in the ledger as `entry`
    needs_review: "needs_review", # unresolved, or a possible duplicate
    excluded: "excluded",         # no balance impact (pending, declined, reference data)
    superseded: "superseded",     # covered by a verified statement line
    withdrawn: "withdrawn",       # reversed or cancelled after it was imported
    dismissed: "dismissed"        # the user deleted the imported entry; never re-import
  }, validate: true

  belongs_to :family
  belongs_to :item, polymorphic: true
  belongs_to :provider_account, polymorphic: true, optional: true
  belongs_to :account, optional: true
  belongs_to :entry, optional: true
  belongs_to :fee_entry, class_name: "Entry", optional: true

  validates :provider_key, :external_key, :category, presence: true
  validates :provenance, inclusion: { in: PROVENANCES }
  validates :external_key, uniqueness: { scope: [ :item_type, :item_id ] }

  scope :for_provider, ->(key) { where(provider_key: key) }

  # Sure's sign convention: positive amounts leave the account.
  def outflow?
    amount.present? && amount.positive?
  end

  def importable_provenance?
    IMPORTABLE_PROVENANCES.include?(provenance)
  end

  # Imported once, and the entry is gone while its account still exists: the
  # user deleted it on purpose. (Deleting or relinking the whole account drops
  # `account_id` too, which is not a dismissal.)
  def deleted_by_user?
    imported_at.present? && entry_id.nil? && account_id.present?
  end

  # The same for a fee imported as its own entry: the user deleted only the
  # fee, so it is not recreated (the main entry is unaffected).
  def fee_deleted_by_user?
    fee_imported_at.present? && fee_entry_id.nil? && account_id.present?
  end

  # Set by an operator (bin/rails wise:resolve / wise:accept_duplicate /
  # wise:classify); survives every later sync.
  def resolution
    details["resolution"] || {}
  end

  def classification_override
    details["classification"]
  end
end
