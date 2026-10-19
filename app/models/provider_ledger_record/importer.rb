# frozen_string_literal: true

# Imports one ProviderLedgerRecord into its account's ledger, or explains why
# it did not. Provider-independent.
#
# Identity: once a record is linked to an entry, that entry is updated in
# place under whatever external id it already has. Entries an earlier sync
# created for the same movement (legacy ids) are adopted the same way. No
# existing entry is ever renamed, so older code that still knows the legacy
# id keeps finding the same entry instead of creating a second one.
#
# Duplicates: manual, CSV or YNAB entries (no external id) on the account with
# the same currency within DUPLICATE_WINDOW_DAYS are candidates when their
# amount equals the full debit or, for a split fee, the principal. One
# candidate is claimed when it is on the same day, or when its name matches
# the merchant, counterparty or payment reference; any other candidate set is
# left for review rather than guessed.
#
# User data: a deleted entry is remembered and never recreated (separately
# for a fee entry); protected entries keep the user's edits
# (Account::ProviderImportAdapter); an entry moves, edits intact, when the
# provider later assigns the movement to another of its balances.
class ProviderLedgerRecord::Importer
  DUPLICATE_WINDOW_DAYS = 3
  MIN_MATCH_TERM_LENGTH = 3

  attr_reader :record, :account, :source

  def initialize(record, account:, source:)
    @record = record
    @account = account
    @source = source
  end

  def self.external_id_for(source, external_key)
    "#{source}_#{external_key.tr(':', '_')}"
  end

  def new_external_id
    self.class.external_id_for(source, record.external_key)
  end

  # @param kind [String, nil] transaction kind for a leg that is not income
  #   or expense on its own (an own-account movement with one known leg)
  # @param match_terms [Array<String>] names identifying the movement
  #   (merchant, counterparty, payment reference), for duplicate matching
  # @return [Symbol] :imported, :dismissed, :needs_review or :skipped
  def import(name:, merchant: nil, extra: {}, legacy_external_ids: [], legacy_fee_external_ids: [],
             fee_name: nil, kind: nil, match_terms: [])
    return :skipped unless record.importable_provenance? && record.amount.present? && record.currency.present?
    return :dismissed if record.dismissed?

    if record.deleted_by_user?
      record.update!(status: :dismissed, reason: "entry_deleted_by_user")
      return :dismissed
    end

    outcome = follow_account_change!
    return outcome if outcome

    entry = linked_entry || adopt(legacy_external_ids) || operator_chosen_entry
    unless entry || record.resolution["force_new"]
      decision = duplicate_decision(match_terms)
      return review!(decision[:candidates]) if decision[:review]

      if (candidate = decision[:claim])
        candidate.update!(external_id: new_external_id, source: source)
        entry = candidate
      end
    end

    # An entry that already holds the full debit (the user's own record of it,
    # or an earlier unsplit import) keeps it; the fee is not added on top.
    claimed_total = fee_separable? && entry.present? && record.fee_entry.nil? && entry.amount == record.amount
    split = fee_separable? && !claimed_total
    entry = adapter.import_transaction(
      external_id: entry&.external_id || new_external_id,
      amount: split ? principal : record.amount,
      currency: record.currency,
      date: date,
      name: name,
      source: source,
      merchant: merchant,
      kind: kind,
      extra: extra,
      allow_heuristic_matching: false,
      replace_extra_namespaces: [ source ]
    )

    fee_entry = split && !record.fee_deleted_by_user? ? import_fee(fee_name, extra, legacy_fee_external_ids) : nil

    record.update!(
      status: :imported,
      entry: entry,
      account: account,
      imported_at: record.imported_at || Time.current,
      fee_entry: fee_entry || record.fee_entry,
      fee_imported_at: fee_entry ? (record.fee_imported_at || Time.current) : record.fee_imported_at,
      details: record.details.except("duplicate_candidate_entry_ids").merge("imported_provider_account_id" => record.provider_account_id)
    )
    :imported
  end

  # The movement no longer has a balance impact (reversed, cancelled, refunded
  # in full). Its entries are excluded rather than deleted, so a category,
  # note or tag the user added stays, but a cancelled payment no longer
  # counts as spent. This happens once, on the transition; if the user
  # includes the entry again, later syncs leave it. Only an entry locked to
  # an import is left alone.
  def withdraw!(reason)
    [ record.entry, record.fee_entry ].compact.each do |entry|
      entry.update!(excluded: true) unless entry.import_locked? || entry.excluded?
    end
    record.update!(status: :withdrawn, reason: reason)
  end

  # A verified statement line now covers this movement. The entry stays
  # linked; the statement import updates it in place (see
  # WiseStatement::Processor), so the movement is never counted twice.
  def supersede!
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

    # A known fee inside an outflow is its own entry. If the user deleted that
    # fee entry, it stays deleted and is not folded back into the principal.
    def fee_separable?
      fee.positive? && record.fee_currency == record.currency && record.amount.positive? && fee < record.amount
    end

    def principal
      record.amount - fee
    end

    def linked_entry
      record.entry if record.entry&.account_id == account.id
    end

    # An operator decided a possible duplicate is this movement
    # (bin/rails wise:accept_duplicate ENTRY_ID=...).
    def operator_chosen_entry
      entry_id = record.resolution["link_entry_id"]
      return nil if entry_id.blank?

      entry = account.entries.find_by(id: entry_id, entryable_type: "Transaction")
      return nil unless entry

      entry.update!(external_id: new_external_id, source: source) if entry.external_id.nil?
      entry
    end

    def adopt(external_ids)
      Array(external_ids).compact_blank.lazy
        .filter_map { |id| account.entries.find_by(source: source, external_id: id) }
        .find { |entry| !ProviderLedgerRecord.where.not(id: record.id).exists?(entry_id: entry.id) }
    end

    # --- moving between balances -----------------------------------------------

    # The provider now places the movement on a different provider account
    # (a balance that existed only for part of the time came to light). The
    # existing entry, with every user edit, moves; nothing stays behind.
    # A change of the Sure account linked to the same provider account is a
    # relink by the user instead: like other providers, the old entries stay
    # with the old account and the movement is imported afresh.
    def follow_account_change!
      entry = record.entry
      return nil if entry.nil? || entry.account_id == account.id

      imported_from = record.details["imported_provider_account_id"]
      unless imported_from.present? && imported_from != record.provider_account_id
        record.assign_attributes(entry: nil, fee_entry: nil, account: nil, imported_at: nil, fee_imported_at: nil)
        return nil
      end

      entries = [ entry, record.fee_entry ].compact
      if entries.any? { |e| e.entryable.is_a?(Transaction) && e.entryable.transfer.present? }
        return review_reason!("reassignment_blocked_by_transfer")
      end
      if entries.any? { |e| account.entries.exists?(source: e.source, external_id: e.external_id) }
        return review_reason!("reassignment_external_id_conflict")
      end

      previous_account = entry.account
      Entry.transaction { entries.each { |e| e.update!(account: account) } }
      record.update!(account: account, details: record.details.merge("moved_from_account_id" => previous_account.id))
      previous_account.sync_later
      nil
    end

    # --- duplicates ------------------------------------------------------------------

    def duplicate_decision(match_terms)
      amounts = [ record.amount ]
      amounts << principal if fee_separable?
      candidates = account.entries
        .where(entryable_type: "Transaction", external_id: nil, currency: record.currency, amount: amounts, excluded: false)
        .where(date: (date - DUPLICATE_WINDOW_DAYS.days)..(date + DUPLICATE_WINDOW_DAYS.days))
        .order(:date, :created_at)
        .to_a
      return {} if candidates.empty?

      terms = match_keys(match_terms)
      same_day = candidates.select { |candidate| candidate.date == date }
      named = candidates.select { |candidate| name_matches?(candidate, terms) }

      claim =
        if candidates.one? && (same_day.any? || named.any?)
          candidates.first
        elsif (strong = same_day & named).one?
          strong.first
        end

      claim ? { claim: claim } : { review: true, candidates: candidates }
    end

    def match_keys(terms)
      Array(terms).filter_map { |term| Merchant::NameNormalizer.key(term).presence }
        .select { |key| key.length >= MIN_MATCH_TERM_LENGTH }.uniq
    end

    def name_matches?(entry, keys)
      name = Merchant::NameNormalizer.key("#{entry.name} #{entry.notes}")
      keys.any? { |key| name.include?(key) }
    end

    def review!(candidates)
      record.update!(
        status: :needs_review,
        reason: "possible_duplicate",
        details: record.details.merge("duplicate_candidate_entry_ids" => candidates.map(&:id))
      )
      :needs_review
    end

    def review_reason!(reason)
      record.update!(status: :needs_review, reason: reason)
      :needs_review
    end

    # --- fees ----------------------------------------------------------------------

    def import_fee(fee_name, extra, legacy_fee_external_ids)
      fee_entry = (record.fee_entry if record.fee_entry&.account_id == account.id) ||
        adopt(legacy_fee_external_ids) ||
        claim_fee_duplicate

      adapter.import_transaction(
        external_id: fee_entry&.external_id || "#{new_external_id}_fee",
        amount: fee,
        currency: record.currency,
        date: date,
        name: fee_name.presence || "#{source.titleize} fee",
        source: source,
        extra: { source => (extra[source] || extra[source.to_sym] || {}).merge("type" => "FEE", "fee_of" => record.external_key) },
        allow_heuristic_matching: false,
        replace_extra_namespaces: [ source ]
      )
    end

    # A fee the user already entered by hand, on the same day.
    def claim_fee_duplicate
      candidates = account.entries
        .where(entryable_type: "Transaction", external_id: nil, currency: record.currency, amount: fee, date: date, excluded: false)
        .to_a
      return nil unless candidates.one?

      candidates.first.tap { |candidate| candidate.update!(external_id: "#{new_external_id}_fee", source: source) }
    end
end
