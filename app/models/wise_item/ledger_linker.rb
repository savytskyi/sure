# frozen_string_literal: true

# Relationships between a family's Wise ledger legs, across all its Wise
# profiles (personal and business connections are separate WiseItems).
#
# `annotate!` runs before import and records, on each leg, what Wise states
# or what a deterministic rule found:
# - currency_conversion: both legs of one conversion activity (confirmed)
# - internal_transfer / business_to_personal / personal_to_business: the
#   same Wise transfer id debited in one own profile and credited in another
#   (confirmed), or credited from an own profile's batch member transfer
# - own_account_transfer: paid to an account Wise marks as the customer's
#   own, with no credit leg in Wise (unmatched; never invented)
# - refund: a card refund and the earlier purchase at the same merchant
#
# `link_transfers!` runs after import and turns confirmed movements between
# own balances into Sure Transfers, so they count as neither income nor
# expense. Business <-> personal payments stay income/expense unless
# WISE_LINK_OWN_PROFILE_TRANSFERS is enabled: salary, dividends or
# reimbursements are not neutral transfers.
class WiseItem::LedgerLinker
  REFUND_WINDOW = 180.days
  NEUTRAL_TYPES = %w[currency_conversion jar_move internal_transfer].freeze
  OWN_PROFILE_TYPES = %w[business_to_personal personal_to_business].freeze

  def initialize(family)
    @family = family
  end

  def annotate!
    relationships = {}
    legs = records.where.not(category: "transfer_order").includes(:item).to_a
    orders = records.where(category: "transfer_order").includes(:item).index_by(&:provider_transfer_id)
    by_key = legs.index_by { |record| [ record.item_id, record.external_key ] }

    annotate_conversions(legs, by_key, relationships)
    annotate_transfers(legs, orders, relationships)
    annotate_refunds(legs, relationships)

    legs.each do |record|
      relationship = relationships[record.id] || {}
      # The Sure transfer outcome (set by link_transfers!) belongs to the same pair.
      if relationship["counterpart_id"].present? && relationship["counterpart_id"] == record.relationship["counterpart_id"]
        relationship = relationship.merge(record.relationship.slice("sure_transfer"))
      end
      record.update_columns(relationship: relationship, updated_at: Time.current) if record.relationship != relationship
    end
  end

  def link_transfers!
    pairs = records.where(status: :imported).where.not(entry_id: nil).to_a
      .select { |record| record.outflow? && linkable?(record.relationship) }

    pairs.each do |outflow|
      inflow = records.find_by(id: outflow.relationship["counterpart_id"])
      next unless inflow&.imported? && inflow.entry
      next unless linkable_pair?(outflow, inflow)

      result = Transfer::ProviderLinker.new(outflow_entry: outflow.entry, inflow_entry: inflow.entry).link
      state = result.status.to_s
      [ outflow, inflow ].each do |record|
        next if record.relationship["sure_transfer"] == state

        record.update_columns(relationship: record.relationship.merge("sure_transfer" => state))
      end
      log_link_failure(outflow, result) if result.status.in?(%i[invalid conflict])
    end
  end

  private
    def records
      ProviderLedgerRecord.where(family: @family, provider_key: "wise")
    end

    def linkable?(relationship)
      relationship["status"] == "confirmed" && relationship["counterpart_id"].present?
    end

    # An operator's classification (bin/rails wise:classify) wins: salary or
    # income is never netted away as a transfer, an internal transfer is.
    def linkable_pair?(outflow, inflow)
      overrides = [ outflow.classification_override, inflow.classification_override ].compact
      return false if overrides.intersect?(%w[salary income expense])
      return true if overrides.include?("internal_transfer")

      type = outflow.relationship["type"]
      NEUTRAL_TYPES.include?(type) ||
        (OWN_PROFILE_TYPES.include?(type) && Rails.configuration.x.wise.link_own_profile_transfers)
    end

    def profile_type(record)
      record.item.profile_type
    end

    def relation_type(sender, receiver)
      return "internal_transfer" if sender.item_id == receiver.item_id

      case [ profile_type(sender), profile_type(receiver) ]
      when %w[business personal] then "business_to_personal"
      when %w[personal business] then "personal_to_business"
      else "internal_transfer"
      end
    end

    def pair!(relationships, a, b, type:, basis:, status: "confirmed")
      relationships[a.id] = { "type" => type, "status" => status, "counterpart_id" => b.id, "counterpart_key" => b.external_key, "basis" => basis }
      relationships[b.id] = { "type" => type, "status" => status, "counterpart_id" => a.id, "counterpart_key" => a.external_key, "basis" => basis }
    end

    # Both legs of one conversion or jar-move activity.
    def annotate_conversions(legs, by_key, relationships)
      legs.each do |record|
        if record.category == "currency_conversion" && record.details["conversion_leg"] == "source"
          target = by_key[[ record.item_id, record.details["counterpart_key"] ]]
          pair!(relationships, record, target, type: "currency_conversion", basis: "same Wise conversion activity") if target
        elsif record.category == "jar_move" && record.outflow?
          counterpart = by_key[[ record.item_id, record.details["counterpart_key"] ]] if record.details["counterpart_key"]
          if counterpart
            pair!(relationships, record, counterpart, type: "jar_move", basis: "same Wise jar move activity")
          else
            relationships[record.id] = { "type" => "jar_move", "status" => "unmatched", "basis" => "the jar side is not a known balance" }
          end
        elsif record.category == "jar_move" && record.details["counterpart_key"].blank? && record.amount
          relationships[record.id] = { "type" => "jar_move", "status" => "unmatched", "basis" => "the jar side is not a known balance" }
        end
      end
    end

    def annotate_transfers(legs, orders, relationships)
      transfer_legs = legs.select { |record| record.provider_resource_type == "TRANSFER" && record.provider_resource_id.present? }
      debits = transfer_legs.select { |record| record.category == "outgoing_payment" && !record.excluded? }.group_by(&:provider_resource_id)
      credits = transfer_legs.select { |record| record.category == "incoming_payment" && !record.excluded? }

      credits.each do |credit|
        transfer_id = credit.provider_resource_id
        debit = Array(debits[transfer_id]).find { |record| record.id != credit.id }
        order = orders[transfer_id]

        if debit
          pair!(relationships, debit, credit, type: relation_type(debit, credit), basis: "same Wise transfer id debited and credited")
        elsif order&.relationship&.dig("type") == "batch_member"
          relationships[credit.id] = {
            "type" => relation_type(order, credit), "status" => "confirmed",
            "batch_key" => order.relationship["batch_key"], "transfer_id" => transfer_id,
            "basis" => "credit carries the Wise transfer id of an own batch member; the batch debit stays one leg"
          }
        elsif order && order.item_id == credit.item_id
          # The profile created this transfer to its own balance (a pay-in
          # such as "add money by bank transfer"). Wise does not say who paid
          # it in, so it is neither assumed to be own money nor income: it
          # stays an ordinary incoming payment, marked for context only.
          relationships[credit.id] = {
            "type" => "self_initiated_deposit", "status" => "unmatched", "transfer_id" => transfer_id,
            "basis" => "transfer created by the receiving profile itself; the payer is not stated"
          }
        elsif order
          relationships[credit.id] = {
            "type" => relation_type(order, credit), "status" => "unmatched", "transfer_id" => transfer_id,
            "basis" => "sent by another own profile; its debit leg was not found"
          }
        end
      end

      own_profiles = @family.wise_items.pluck(:profile_id).map(&:to_s)
      debits.values.flatten.each do |debit|
        next if relationships.key?(debit.id)

        target_profile = debit.details["recipient_target_profile"]
        if target_profile.present? && own_profiles.include?(target_profile)
          relationships[debit.id] = {
            "type" => target_profile == debit.item.profile_id.to_s ? "internal_transfer" : "own_profile_transfer",
            "status" => "unmatched", "basis" => "recipient is an own Wise profile; no credit leg found"
          }
        elsif debit.details["recipient_owned_by_customer"]
          relationships[debit.id] = {
            "type" => "own_account_transfer", "status" => "unmatched",
            "basis" => "Wise marks the recipient as the customer's own account; the destination is outside Wise"
          }
        end
      end
    end

    def annotate_refunds(legs, relationships)
      cards = legs.select { |record| record.category == "card_payment" && record.merchant_name.present? && !record.excluded? && record.occurred_at }
      purchases = cards.select { |record| record.amount.to_d.positive? }.group_by { |record| [ record.item_id, merchant_key(record) ] }

      cards.select { |record| record.amount.to_d.negative? }.each do |refund|
        candidates = Array(purchases[[ refund.item_id, merchant_key(refund) ]]).select do |purchase|
          purchase.occurred_at <= refund.occurred_at &&
            purchase.occurred_at >= refund.occurred_at - REFUND_WINDOW &&
            purchase.original_currency == refund.original_currency &&
            purchase.original_amount.to_d >= refund.original_amount.to_d
        end
        next if candidates.empty?

        purchase = candidates.max_by(&:occurred_at)
        relationships[refund.id] = {
          "type" => "refund",
          "status" => candidates.one? ? "high_confidence" : "ambiguous",
          "counterpart_id" => candidates.one? ? purchase.id : nil,
          "counterpart_key" => candidates.one? ? purchase.external_key : nil,
          "candidate_keys" => candidates.many? ? candidates.map(&:external_key) : nil,
          "refund_type" => refund.original_amount.to_d == purchase.original_amount.to_d ? "full" : "partial",
          "basis" => "same merchant, earlier purchase, refund not above the purchase, within 180 days"
        }.compact
      end
    end

    def merchant_key(record)
      Merchant::NameNormalizer.key(Merchant::NameNormalizer.default.normalize(record.merchant_name))
    end

    def log_link_failure(outflow, result)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "WiseItem::LedgerLinker - could not link Wise #{outflow.relationship['type']} as a transfer: #{result.error}",
        source: self.class.name,
        provider_key: "wise",
        family: @family,
        metadata: { ledger_record_id: outflow.id, counterpart_id: outflow.relationship["counterpart_id"], status: result.status }
      )
    rescue => e
      Rails.logger.warn "WiseItem::LedgerLinker - failed to log link failure: #{e.message}"
    end
end
