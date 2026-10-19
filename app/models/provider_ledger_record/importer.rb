# frozen_string_literal: true

# Imports one ProviderLedgerRecord into its account's ledger, or explains why
# it did not:
#
# 1. A record the user dismissed (deleted after import) is never recreated.
# 2. An entry the provider created earlier under another external id (legacy
#    sync code, a statement line) is claimed, so the same movement is never
#    imported twice.
# 3. Manual, CSV or YNAB entries (no external id) with the same amount and
#    currency close by are possible duplicates: exactly one on the same day is
#    claimed (Account::ProviderImportAdapter's rule); anything less certain is
#    left for review instead of guessed.
# 4. User edits are protected by Account::ProviderImportAdapter.
#
# A known fee inside an outflow is imported as its own entry, so fees can be
# categorized; both entries keep the record's provenance. Provider-independent.
class ProviderLedgerRecord::Importer
  DUPLICATE_WINDOW_DAYS = 3

  attr_reader :record, :account, :source

  def initialize(record, account:, source:)
    @record = record
    @account = account
    @source = source
  end

  def self.external_id_for(source, external_key)
    "#{source}_#{external_key.tr(':', '_')}"
  end

  def external_id
    self.class.external_id_for(source, record.external_key)
  end

  def fee_external_id
    "#{external_id}_fee"
  end

  # @return [Symbol] :imported, :dismissed, :needs_review or :skipped
  def import(name:, merchant: nil, extra: {}, legacy_external_ids: [], fee_name: nil)
    return :skipped unless record.importable_provenance? && record.amount.present? && record.currency.present?
    return :dismissed if record.dismissed?

    reset_for_new_account! if record.account_id.present? && record.account_id != account.id

    if record.deleted_by_user?
      record.update!(status: :dismissed, reason: "entry_deleted_by_user")
      return :dismissed
    end

    claim_legacy_entry!(legacy_external_ids)

    existing = account.entries.find_by(source: source, external_id: external_id)
    allow_claim = false

    unless existing
      candidates = duplicate_candidates
      if candidates.size > 1 || (candidates.size == 1 && candidates.first.date != date)
        record.update!(
          status: :needs_review,
          reason: "possible_duplicate",
          details: record.details.merge("duplicate_candidate_entry_ids" => candidates.map(&:id))
        )
        return :needs_review
      end
      allow_claim = candidates.one?
    end

    entry = adapter.import_transaction(
      external_id: external_id,
      amount: main_amount,
      currency: record.currency,
      date: date,
      name: name,
      source: source,
      merchant: merchant,
      extra: extra,
      allow_heuristic_matching: allow_claim,
      replace_extra_namespaces: [ source ]
    )

    import_fee!(fee_name, extra) if fee_split?

    record.update!(
      status: :imported,
      entry: entry,
      account: account,
      imported_at: record.imported_at || Time.current,
      details: record.details.except("duplicate_candidate_entry_ids")
    )
    :imported
  end

  # The movement no longer has a balance impact (reversed, cancelled). An
  # entry we created is excluded rather than deleted, so nothing the user
  # might have annotated disappears; a protected entry is left untouched.
  def withdraw!(reason)
    entry = record.entry
    entry.update!(excluded: true) if entry && !entry.protected_from_sync?
    record.update!(status: :withdrawn, reason: reason)
  end

  # A verified statement line now covers this movement. Hands the entry over
  # to the statement's external id so the statement import updates it in
  # place instead of adding a second one.
  def supersede!(statement_external_id)
    entry = record.entry
    if entry && account && !account.entries.exists?(source: source, external_id: statement_external_id)
      entry.update!(external_id: statement_external_id)
    end
    record.update!(status: :superseded, reason: "covered_by_statement")
  end

  private
    def adapter
      @adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def date
      @date ||= record.occurred_at.in_time_zone(account.family.timezone.presence || "UTC").to_date
    end

    def fee
      record.fee_amount.to_d
    end

    def fee_split?
      fee.positive? && record.fee_currency == record.currency && record.amount.positive? && fee < record.amount
    end

    def main_amount
      fee_split? ? record.amount - fee : record.amount
    end

    def import_fee!(fee_name, extra)
      adapter.import_transaction(
        external_id: fee_external_id,
        amount: fee,
        currency: record.currency,
        date: date,
        name: fee_name.presence || name_fallback,
        source: source,
        extra: { source => (extra[source] || extra[source.to_sym] || {}).merge("type" => "FEE", "fee_of" => external_id) },
        allow_heuristic_matching: false,
        replace_extra_namespaces: [ source ]
      )
    end

    def name_fallback
      "#{source.titleize} fee"
    end

    def claim_legacy_entry!(legacy_external_ids)
      return if account.entries.exists?(source: source, external_id: external_id)

      legacy = Array(legacy_external_ids).compact_blank.lazy
        .filter_map { |id| account.entries.find_by(source: source, external_id: id) }
        .first
      legacy&.update!(external_id: external_id)
    end

    def duplicate_candidates
      account.entries
        .where(entryable_type: "Transaction", external_id: nil, currency: record.currency, amount: main_amount, excluded: false)
        .where(date: (date - DUPLICATE_WINDOW_DAYS.days)..(date + DUPLICATE_WINDOW_DAYS.days))
        .order(:date, :created_at)
        .to_a
    end

    def reset_for_new_account!
      record.assign_attributes(account: nil, entry: nil, imported_at: nil)
      record.status = :ready if record.imported? || record.dismissed?
    end
end
