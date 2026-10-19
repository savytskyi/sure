# frozen_string_literal: true

# Imports this connection's importable Wise ledger legs into the linked Sure
# accounts through ProviderLedgerRecord::Importer. A leg is re-imported only
# when its data changed since the last import, so daily syncs stay cheap and
# repeated runs are no-ops.
#
# Entries created by earlier Wise sync code for the same movement are adopted
# under their existing ids rather than duplicated or renamed: the legacy
# transfer fallback ("wise_transfer_<id>", "wise_fee_<id>") and the old jar
# and conversion import ("wise_interbalance_<id>_outflow" / "_inflow"). Older
# code that still knows those ids therefore finds the same entries.
#
# Kinds: legs of a movement between the customer's own money (jar moves,
# conversions, top-ups, payments to an account Wise marks as their own, or
# what an operator classified as an internal transfer) are funds movements,
# so a missing counterpart leg never turns them into income or expense.
# Business <-> personal payments stay income and expense unless classified
# otherwise.
class WiseItem::LedgerProcessor
  SOURCE = "wise"

  Result = Data.define(:imported, :needs_review, :dismissed, :skipped, :failed)
  OWN_MONEY_RELATIONSHIPS = %w[currency_conversion jar_move internal_transfer own_account_transfer].freeze

  def initialize(wise_item)
    @wise_item = wise_item
    @merchants = Merchant::FamilyResolver.new(wise_item.family)
  end

  def process
    counts = Hash.new(0)

    importable_records.find_each do |record|
      account = record.provider_account.current_account
      if account.nil? || !Account::VISIBLE_STATUSES.include?(account.status)
        counts[:skipped] += 1
        next
      end

      digest = import_digest(record)
      if record.imported? && record.entry_id.present? && record.details["import_digest"] == digest
        counts[:skipped] += 1
        next
      end

      if statement_entry_exists?(record, account)
        record.update!(status: :superseded, reason: "covered_by_statement")
        counts[:skipped] += 1
        next
      end

      merchant = merchant_for(record)
      outcome = ProviderLedgerRecord::Importer.new(record, account: account, source: SOURCE).import(
        name: name_for(record),
        merchant: merchant,
        kind: kind_for(record),
        extra: extra_for(record),
        legacy_external_ids: legacy_external_ids(record),
        legacy_fee_external_ids: legacy_fee_external_ids(record),
        match_terms: [ record.merchant_name, merchant&.name, record.counterparty_name, record.payment_reference ],
        fee_name: I18n.t("wise_items.entries.fee_name")
      )

      if outcome == :imported
        record.update_columns(details: record.details.merge("import_digest" => digest, "merchant_id" => merchant&.id).compact)
      end
      counts[outcome] += 1
    rescue => e
      counts[:failed] += 1
      Rails.logger.error "WiseItem::LedgerProcessor - failed to import ledger record #{record.id}: #{e.class} - #{e.message}"
    end

    Result.new(**Result.members.to_h { |key| [ key, counts[key] ] })
  end

  private
    attr_reader :wise_item

    def importable_records
      wise_item.ledger_records
        .where(status: %i[ready imported], provenance: ProviderLedgerRecord::IMPORTABLE_PROVENANCES)
        .where.not(provider_account_id: nil)
        .includes(:entry, provider_account: { account_provider: :account })
    end

    def import_digest(record)
      Digest::SHA256.hexdigest([
        record.amount&.to_s, record.currency, record.fee_amount&.to_s, record.occurred_at&.iso8601,
        record.provenance, record.field_provenance, record.name, record.counterparty_name,
        record.merchant_name, record.payment_reference, record.relationship, record.provider_account_id,
        record.classification_override, kind_for(record)
      ].to_json)
    end

    # Never let a reconstructed leg overwrite or duplicate a verified line.
    def statement_entry_exists?(record, account)
      reference = record.details["statement_reference"]
      reference.present? && account.entries.exists?(source: SOURCE, external_id: "wise_statement_#{reference}")
    end

    def merchant_for(record)
      return nil unless record.category == "card_payment" && record.merchant_name.present?

      @merchants.resolve(record.merchant_name, remembered_id: record.details["merchant_id"])
    end

    def name_for(record)
      case record.category
      when "card_payment"
        record.merchant_name
      when "cash_withdrawal"
        [ I18n.t("wise_items.ledger.cash_withdrawal"), record.name ].compact_blank.join(" - ")
      when "currency_conversion"
        I18n.t("wise_items.ledger.conversion", from: record.details["source_currency"], to: record.details["target_currency"])
      when "batch_payment"
        I18n.t("wise_items.ledger.batch_payment", name: record.counterparty_name || record.name)
      when "jar_move"
        I18n.t("wise_items.ledger.jar_move", destination: record.details["destination_title"])
      else
        [ record.counterparty_name || record.name, record.payment_reference ].compact_blank.uniq.join(" - ")
      end.presence || I18n.t("wise_items.entries.default_name")
    end

    def extra_for(record)
      {
        SOURCE => {
          "source" => "activity",
          "provenance" => record.provenance,
          "field_provenance" => record.field_provenance.presence,
          "provenance_reason" => record.reason,
          "category" => record.category,
          "activity_id" => record.raw_payload&.dig("id"),
          "activity_type" => record.details["activity_type"],
          "resource_type" => record.provider_resource_type,
          "resource_id" => record.provider_resource_id,
          "transfer_id" => record.provider_transfer_id,
          "balance_id" => record.provider_account&.balance_id,
          "merchant_raw" => record.merchant_name,
          "counterparty" => record.counterparty_name,
          "payment_reference" => record.payment_reference,
          "original_amount" => record.original_amount&.to_s,
          "original_currency" => record.original_currency,
          "fee" => record.fee_amount&.positive? ? record.fee_amount.to_s : nil,
          "fee_currency" => record.fee_amount&.positive? ? record.fee_currency : nil,
          "relationship" => record.relationship.slice("type", "status", "basis", "counterpart_key", "batch_key").presence
        }.compact
      }
    end

    def legacy_external_ids(record)
      case record.category
      when "outgoing_payment", "incoming_payment"
        record.provider_resource_id.present? && record.provider_resource_type == "TRANSFER" ? [ "wise_transfer_#{record.provider_resource_id}" ] : []
      when "currency_conversion"
        record.details["conversion_leg"] == "source" ? [ "wise_interbalance_#{record.provider_resource_id}_outflow" ] : []
      when "jar_move"
        [ record.details["legacy_external_id"] ]
      else
        []
      end.compact
    end

    # The legacy fallback imported a transfer's fee as its own entry.
    def legacy_fee_external_ids(record)
      return [] unless record.category == "outgoing_payment" && record.provider_resource_id.present?

      [ "wise_fee_#{record.provider_resource_id}" ]
    end

    def kind_for(record)
      case record.classification_override
      when "internal_transfer" then return "funds_movement"
      when "income", "expense", "salary" then return nil
      end

      own_money = record.category.in?(%w[jar_move currency_conversion]) ||
        record.details["activity_type"] == "BALANCE_DEPOSIT" ||
        OWN_MONEY_RELATIONSHIPS.include?(record.relationship["type"])
      own_money ? "funds_movement" : nil
    end
end
