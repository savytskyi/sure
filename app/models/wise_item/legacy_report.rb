# frozen_string_literal: true

# Reviews the entries the old Wise connector created (the /v1/transfers
# fallback, its fee entries, and conversion/jar rows) against the
# reconstructed ledger and Wise's transfer statuses, and proposes a
# correction for each. Read-only: nothing is changed here. Excluding an
# entry (reversible) is a separate, explicit step (bin/rails
# wise:legacy_exclude), and nothing is ever deleted.
class WiseItem::LegacyReport
  Finding = Data.define(:entry, :finding, :action, :evidence)

  LEGACY_PATTERNS = {
    transfer: /\Awise_transfer_(\d+)\z/,
    fee: /\Awise_fee_(\d+)\z/,
    interbalance: /\Awise_interbalance_(.+)_(inflow|outflow)\z/
  }.freeze

  ACTIONS = {
    "adopted" => "none",
    "adopted_user_modified_differs" => "review",
    "cancelled_transfer" => "exclude",
    "refunded_transfer" => "exclude",
    "duplicate_of_reconstructed_leg" => "exclude",
    "batch_member_counted_in_batch_debit" => "exclude",
    "duplicate_fee" => "exclude",
    "misrouted_conversion_or_jar_move" => "exclude",
    "no_reconstructed_leg" => "review"
  }.freeze

  def initialize(family)
    @family = family
  end

  def findings
    @findings ||= legacy_entries.map { |entry| classify(entry) }
  end

  def summary
    findings.group_by(&:finding).transform_values(&:size).sort.to_h
  end

  def to_csv
    CSV.generate do |csv|
      csv << %w[entry_id date account external_id amount currency name user_modified finding proposed_action evidence]
      findings.each do |f|
        e = f.entry
        csv << [ e.id, e.date, e.account.name, e.external_id, e.amount.to_s("F"), e.currency, e.name, e.user_modified, f.finding, f.action, f.evidence ]
      end
    end
  end

  private
    def legacy_entries
      Entry.joins(:account).where(accounts: { family_id: @family.id }, source: "wise", entryable_type: "Transaction")
        .where("entries.external_id ~ '^wise_(transfer|fee)_[0-9]+$' OR entries.external_id LIKE 'wise\\_interbalance\\_%'")
        .preload(:account).order(:date)
    end

    def records
      @records ||= ProviderLedgerRecord.where(family: @family, provider_key: "wise")
    end

    def adopted_entry_ids
      @adopted_entry_ids ||= (records.where.not(entry_id: nil).pluck(:entry_id) + records.where.not(fee_entry_id: nil).pluck(:fee_entry_id)).to_set
    end

    def orders
      @orders ||= records.where(category: "transfer_order").index_by(&:provider_transfer_id)
    end

    def legs_by_resource
      @legs_by_resource ||= records.where.not(category: "transfer_order").where.not(provider_resource_id: nil)
        .group_by { |record| [ record.provider_resource_type, record.provider_resource_id ] }
    end

    def finding(entry, name, evidence = nil)
      Finding.new(entry: entry, finding: name, action: ACTIONS.fetch(name), evidence: evidence)
    end

    def classify(entry)
      if adopted_entry_ids.include?(entry.id)
        record = records.find_by(entry_id: entry.id) || records.find_by(fee_entry_id: entry.id)
        fee = record.fee_amount.to_d
        expected = record.entry_id == entry.id ? [ record.amount.to_d, record.amount.to_d - fee ] : [ fee ]
        if entry.protected_from_sync? && !expected.include?(entry.amount)
          return finding(entry, "adopted_user_modified_differs", "#{record.external_key}: Wise says #{expected.first.to_s('F')}")
        end
        return finding(entry, "adopted", record.external_key)
      end

      case entry.external_id
      when LEGACY_PATTERNS[:transfer] then classify_transfer(entry, $1)
      when LEGACY_PATTERNS[:fee] then classify_fee(entry, $1)
      when LEGACY_PATTERNS[:interbalance] then classify_interbalance(entry, $1)
      end
    end

    def classify_transfer(entry, transfer_id)
      order = orders[transfer_id]
      status = order&.details&.dig("transfer_status")
      legs = Array(legs_by_resource[[ "TRANSFER", transfer_id ]]).select(&:entry_id)

      if status == "cancelled"
        finding(entry, "cancelled_transfer", "transfer #{transfer_id} cancelled; never funded")
      elsif status == "funds_refunded"
        finding(entry, "refunded_transfer", "transfer #{transfer_id} refunded in full")
      elsif legs.any?
        finding(entry, "duplicate_of_reconstructed_leg", legs.map(&:external_key).join(" "))
      elsif order&.relationship&.dig("type") == "batch_member"
        finding(entry, "batch_member_counted_in_batch_debit", order.relationship["batch_key"])
      else
        finding(entry, "no_reconstructed_leg", "transfer #{transfer_id} #{status || 'not in the transfer list'}")
      end
    end

    def classify_fee(entry, transfer_id)
      status = orders[transfer_id]&.details&.dig("transfer_status")
      legs = Array(legs_by_resource[[ "TRANSFER", transfer_id ]])
      fee_leg = legs.find(&:fee_entry_id)

      if status.in?(%w[cancelled funds_refunded])
        finding(entry, status == "cancelled" ? "cancelled_transfer" : "refunded_transfer", "fee of transfer #{transfer_id}")
      elsif fee_leg
        finding(entry, "duplicate_fee", "#{fee_leg.external_key} has its own fee entry")
      else
        finding(entry, "no_reconstructed_leg", "fee of transfer #{transfer_id}; reconstructed fee #{legs.first&.fee_amount&.to_s('F') || 'unknown'}")
      end
    end

    def classify_interbalance(entry, resource_id)
      legs = Array(legs_by_resource[[ "BALANCE_TRANSACTION", resource_id ]])
      if legs.any?
        finding(entry, "misrouted_conversion_or_jar_move", legs.map(&:external_key).join(" "))
      else
        finding(entry, "no_reconstructed_leg", "balance transaction #{resource_id}")
      end
    end
end
