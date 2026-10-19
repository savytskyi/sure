# frozen_string_literal: true

# Reconstructs ledger legs from Wise activities when balance statements are
# not available (Wise blocks them for personal API tokens outside
# US/CA/AU/NZ/SG/MY). Activities are display records: amounts are formatted
# text and no activity names the balance it touched. Transfer orders, quotes
# and recipient accounts supply what they can.
#
# Each leg gets field-level provenance (amount, balance, fee) and an overall
# provenance that is never stronger than its weakest essential field:
#
# - provider_explicit: Wise states the amount and the balance (quote payInId,
#   recipient balanceId).
# - inferred: amounts stated, but the balance is the single STANDARD balance
#   of that currency that existed at the time (WiseItem::BalanceRegistry), or
#   a batch total was summed from its member transfers.
# - unresolved: something essential is missing or Wise contradicts itself.
#   Never imported.
#
# No FX rate, fee, balance or counterpart leg is ever invented. Ported from
# the homelab financial-data project (providers/wise/provisional*.py).
# Same-currency jar moves, jar interest and jar fees are not handled here;
# WiseActivity::Processor imports those from the jar's own payload.
class WiseItem::LedgerReconstructor
  CARD_TYPES = %w[CARD_PAYMENT CASH_WITHDRAWAL].freeze
  JAR_ONLY_TYPES = %w[BALANCE_CASHBACK BALANCE_ASSET_FEE].freeze
  KNOWN_TYPES = (CARD_TYPES + %w[CARD_CHECK TRANSFER BALANCE_DEPOSIT INTERBALANCE BATCH_TRANSFER]).freeze
  CONTRADICTS_COMPLETED = [ "pending", "declined", "cancelled", "canceled", "in progress" ].freeze
  BATCH_WINDOW = 15.minutes
  BALANCE_PAY_IN = "BALANCE"

  EXPLICIT = "provider_explicit"
  INFERRED = "inferred"
  UNRESOLVED = "unresolved"

  # Statement referenceNumber prefix for an activity's resource type, used to
  # recognize the same movement on a verified statement.
  STATEMENT_PREFIX = { "CARD_TRANSACTION" => "CARD", "TRANSFER" => "TRANSFER", "BALANCE_TRANSACTION" => "BALANCE" }.freeze

  Leg = Struct.new(
    :key, :category, :direction, :provenance, :reason, :field_provenance, :wise_account,
    :amount, :currency, :fee_amount, :fee_currency, :original_amount, :original_currency,
    :occurred_at, :resource_type, :resource_id, :transfer_id, :name, :counterparty_name,
    :merchant_name, :payment_reference, :details, :raw, :excluded_reason,
    keyword_init: true
  ) do
    def excluded? = excluded_reason.present?

    def statement_reference
      prefix = STATEMENT_PREFIX[resource_type]
      "#{prefix}-#{resource_id}" if prefix && resource_id.present?
    end
  end

  Text = WiseActivity::Text

  # @param transfers [Hash{String=>Hash}] transfer id => { "transfer" =>, "quote" =>, "recipient" => }
  #   for this profile's transfer orders (and other own profiles', for incoming legs)
  # @param own_profiles [Hash{String=>String}] profile id => "personal" | "business"
  def initialize(wise_item:, registry:, transfers:, own_profiles: {})
    @wise_item = wise_item
    @registry = registry
    @transfers = transfers
    @own_profiles = own_profiles
    @batch_claims = {}
  end

  def self.conversion?(activity)
    return false unless activity["type"] == "INTERBALANCE"

    primary = Text.parse_amount(activity["primaryAmount"])
    secondary = Text.parse_amount(activity["secondaryAmount"])
    secondary.currency.present? && primary.currency.present? && secondary.currency != primary.currency
  end

  # Handled by the jar sync (WiseActivity::Processor), not here.
  def self.jar_activity?(activity)
    JAR_ONLY_TYPES.include?(activity["type"]) || (activity["type"] == "INTERBALANCE" && !conversion?(activity))
  end

  def legs(activities)
    sorted = activities.sort_by { |activity| [ activity["createdOn"].to_s, activity["id"].to_s ] }
    @own_activity_transfer_ids = sorted.filter_map do |activity|
      activity.dig("resource", "id").to_s if activity["type"] == "TRANSFER" && activity.dig("resource", "type") == "TRANSFER"
    end.to_set

    sorted.flat_map { |activity| legs_for(activity) }
  end

  private
    attr_reader :registry

    def legs_for(activity)
      return [] if activity["id"].blank? || self.class.jar_activity?(activity)

      type = activity["type"].to_s
      status = activity["status"].to_s

      if status != "COMPLETED"
        return [] unless KNOWN_TYPES.include?(type)
        return [ excluded_leg(activity, status == "IN_PROGRESS" ? "pending" : "not_completed_#{status.downcase}") ]
      end

      primary = activity["primaryAmount"].to_s

      if type == "CARD_CHECK"
        [ excluded_leg(activity, "card_check_no_balance_impact") ]
      elsif CARD_TYPES.include?(type) && activity.dig("resource", "type") == "CARD_TRANSACTION"
        [ card_leg(activity) ]
      elsif %w[TRANSFER BALANCE_DEPOSIT].include?(type) && primary.include?("<positive>")
        [ incoming_leg(activity) ]
      elsif type == "TRANSFER"
        [ outgoing_leg(activity) ]
      elsif type == "INTERBALANCE"
        conversion_legs(activity)
      elsif type == "BATCH_TRANSFER"
        batch_legs(activity)
      else
        [ base_leg(activity, category: "other", direction: nil, provenance: UNRESOLVED, reason: "unsupported_activity_type") ]
      end
    end

    # --- shared ---------------------------------------------------------

    def base_leg(activity, **attrs)
      details = {
        "activity_type" => activity["type"],
        "activity_status" => activity["status"],
        "activity_description" => Text.strip_tags(activity["description"]).presence,
        "primary_amount_text" => activity["primaryAmount"].presence,
        "secondary_amount_text" => activity["secondaryAmount"].presence
      }.compact.merge(attrs.delete(:details) || {})

      Leg.new(
        key: attrs.delete(:key) || "activity:#{activity['id']}",
        occurred_at: time(activity["createdOn"]),
        resource_type: activity.dig("resource", "type"),
        resource_id: activity.dig("resource", "id")&.to_s,
        name: Text.strip_tags(activity["title"]).presence,
        field_provenance: {},
        raw: activity,
        **attrs,
        details: details
      )
    end

    def excluded_leg(activity, reason)
      base_leg(activity, category: category_for(activity), direction: nil, provenance: UNRESOLVED, reason: reason, excluded_reason: reason)
    end

    def category_for(activity)
      case activity["type"]
      when "CARD_PAYMENT", "CARD_CHECK" then "card_payment"
      when "CASH_WITHDRAWAL" then "cash_withdrawal"
      when "BATCH_TRANSFER" then "batch_payment"
      when "INTERBALANCE" then "currency_conversion"
      when "BALANCE_DEPOSIT" then "incoming_payment"
      when "TRANSFER" then activity["primaryAmount"].to_s.include?("<positive>") ? "incoming_payment" : "outgoing_payment"
      else "other"
      end
    end

    def combine(amount_provenance, balance_provenance, inconsistent: false)
      return UNRESOLVED if inconsistent || amount_provenance.nil? || balance_provenance.nil?
      return UNRESOLVED if [ amount_provenance, balance_provenance ].include?(UNRESOLVED)

      amount_provenance == EXPLICIT && balance_provenance == EXPLICIT ? EXPLICIT : INFERRED
    end

    # Sure amounts: outflows positive, inflows negative.
    def signed(magnitude, direction)
      return nil if magnitude.nil?

      direction == "inflow" ? -magnitude.abs : magnitude.abs
    end

    def infer_balance(currency, at)
      account, basis = registry.infer(currency, at)
      [ account, account ? INFERRED : nil, basis ]
    end

    # [account, provenance, basis, inconsistent] for a balance id Wise states.
    def stated_balance(balance_id, currency)
      account = registry.find(balance_id)
      return [ nil, nil, "stated_balance_unknown", false ] if account.nil?
      return [ nil, nil, "stated_balance_currency_mismatch", true ] if currency.present? && account.currency != currency

      [ account, EXPLICIT, "stated_balance", false ]
    end

    def transfer_record(transfer_id)
      @transfers[transfer_id.to_s] if transfer_id.present?
    end

    def decimal(value)
      value.nil? ? nil : value.to_s.to_d
    end

    def time(raw)
      return nil if raw.blank?

      Time.find_zone("UTC").parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def pay_in_method(quote)
      return nil if quote.nil?

      quote["payInMethod"].presence || BALANCE_PAY_IN
    end

    # Fee the quote states for the pay-in that was actually used.
    def quote_fee(quote)
      return nil if quote.nil?

      options = Array(quote["paymentOptions"]).select do |option|
        option["payIn"] == pay_in_method(quote) && option["payOut"] == quote["payOut"]
      end
      return nil unless options.one?

      decimal(options.first.dig("fee", "total"))
    end

    def recipient_name(recipient)
      name = recipient&.dig("name")
      name = name["fullName"] if name.is_a?(Hash)
      name.presence || recipient&.dig("accountHolderName").presence
    end

    def recipient_details(transfer)
      recipient = transfer && transfer["recipient"]
      return {} unless recipient

      details = recipient["details"] || {}
      {
        "recipient_type" => recipient["type"],
        "recipient_owned_by_customer" => recipient["ownedByCustomer"],
        "recipient_target_profile" => details["targetProfile"]&.to_s,
        "recipient_balance_id" => (details["balanceId"] || details["balanceAccountBalanceId"])&.to_s
      }.compact
    end

    # --- card payments, ATM withdrawals --------------------------------------

    def card_leg(activity)
      primary = Text.parse_amount(activity["primaryAmount"])
      secondary_text = activity["secondaryAmount"].to_s.strip
      secondary = Text.parse_amount(secondary_text)
      direction = primary.credit ? "inflow" : "outflow"
      description = Text.strip_tags(activity["description"]).downcase
      at = time(activity["createdOn"])
      category = activity["type"] == "CASH_WITHDRAWAL" ? "cash_withdrawal" : "card_payment"
      merchant = category == "card_payment" ? Text.strip_tags(activity["title"]).presence : nil

      leg = base_leg(
        activity,
        category: category,
        direction: direction,
        original_amount: primary.magnitude,
        original_currency: primary.currency,
        merchant_name: merchant
      )

      unresolved = ->(reason) do
        leg.provenance = UNRESOLVED
        leg.reason = reason
        leg
      end

      return unresolved.call("description_contradicts_completed_status") if CONTRADICTS_COMPLETED.include?(description)
      return unresolved.call("refunded_without_credit_marker") if description == "refunded" && !primary.credit
      return unresolved.call("unparseable_purchase_amount") if primary.value.nil?

      if secondary_text.present?
        return unresolved.call("split_balance_no_per_balance_amounts") if Text.currency_list?(secondary_text)
        return unresolved.call("unparseable_debit_amount") if secondary.value.nil?

        # Wise shows a second amount only when the charged balance's currency
        # differs from the purchase currency: that is the actual debit.
        amount, currency, amount_provenance, amount_basis = secondary.magnitude, secondary.currency, EXPLICIT, "activity_debit_amount"
      else
        # No second amount: the purchase currency was charged as is.
        amount, currency, amount_provenance, amount_basis = primary.magnitude, primary.currency, INFERRED, "activity_purchase_amount"
      end

      account, balance_provenance, balance_basis = infer_balance(currency, at)
      leg.wise_account = account
      leg.amount = signed(amount, direction)
      leg.currency = currency
      leg.field_provenance = {
        "amount" => amount_provenance,
        "currency" => amount_provenance,
        (direction == "inflow" ? "destination_balance" : "source_balance") => balance_provenance || UNRESOLVED
      }
      leg.provenance = combine(amount_provenance, balance_provenance)
      leg.reason = balance_provenance ? amount_basis : balance_basis
      leg.details = leg.details.merge("amount_basis" => amount_basis, "balance_basis" => balance_basis)
      leg
    end

    # --- incoming payments, deposits, refunds of transfers -------------------------

    def incoming_leg(activity)
      credited = Text.parse_amount(activity["primaryAmount"])
      at = time(activity["createdOn"])
      transfer = activity.dig("resource", "type") == "TRANSFER" ? transfer_record(activity.dig("resource", "id")) : nil
      data = transfer&.dig("transfer") || {}
      inconsistent = false
      reasons = []

      leg = base_leg(
        activity,
        category: "incoming_payment",
        direction: "inflow",
        original_amount: credited.magnitude,
        original_currency: credited.currency,
        counterparty_name: Text.strip_tags(activity["title"]).presence,
        transfer_id: transfer ? data["id"].to_s : nil,
        payment_reference: data["reference"].presence || data.dig("details", "reference").presence
      )

      if transfer
        target_value = decimal(data["targetValue"])
        if target_value && (target_value != credited.magnitude || data["targetCurrency"] != credited.currency)
          inconsistent = true
          reasons << "credit_differs_from_transfer_target_value"
        end
        leg.details = leg.details.merge("transfer_target_value" => target_value&.to_s, "sender_profile" => transfer["profile_id"]&.to_s).compact
      end

      account = nil
      balance_provenance = nil
      basis = "no_stated_balance"
      stated_id = recipient_details(transfer)["recipient_balance_id"]
      if stated_id.present?
        account, balance_provenance, basis, bad = stated_balance(stated_id, credited.currency)
        inconsistent ||= bad
        reasons << basis if bad
      end
      if account.nil? && !inconsistent
        account, balance_provenance, basis = infer_balance(credited.currency, at)
      end

      amount_provenance = credited.value ? EXPLICIT : nil
      leg.wise_account = account
      leg.amount = signed(credited.magnitude, "inflow")
      leg.currency = credited.currency
      leg.field_provenance = {
        "amount" => amount_provenance || UNRESOLVED,
        "currency" => amount_provenance || UNRESOLVED,
        "destination_balance" => balance_provenance || UNRESOLVED
      }
      leg.provenance = combine(amount_provenance, balance_provenance, inconsistent: inconsistent)
      leg.reason = reasons.first || (credited.value ? "credited_amount_#{basis}" : "unparseable_credited_amount")
      leg.details = leg.details.merge("balance_basis" => basis)
      leg
    end

    # --- outgoing payments ----------------------------------------------------

    def outgoing_leg(activity)
      shown = Text.parse_amount(activity["primaryAmount"])
      at = time(activity["createdOn"])
      transfer = transfer_record(activity.dig("resource", "id"))

      leg = base_leg(
        activity,
        category: "outgoing_payment",
        direction: "outflow",
        original_amount: shown.magnitude,
        original_currency: shown.currency,
        counterparty_name: Text.strip_tags(activity["title"]).presence
      )

      unless transfer
        leg.provenance = UNRESOLVED
        leg.reason = "no_transfer_order"
        return leg
      end

      data = transfer["transfer"]
      quote = transfer["quote"]
      source_currency = data["sourceCurrency"]
      source_value = decimal(data["sourceValue"])
      target_currency = data["targetCurrency"]
      target_value = decimal(data["targetValue"])

      leg.transfer_id = data["id"].to_s
      leg.counterparty_name = recipient_name(transfer["recipient"]) || leg.counterparty_name
      leg.payment_reference = data["reference"].presence || data.dig("details", "reference").presence
      leg.details = leg.details.merge(recipient_details(transfer)).merge(
        "source_value" => source_value&.to_s,
        "target_value" => target_value&.to_s,
        "target_currency" => target_currency,
        "rate" => data["rate"]&.to_s,
        "quote_available" => quote.present?
      ).compact

      pay_in = pay_in_method(quote)
      if pay_in && pay_in != BALANCE_PAY_IN
        leg.provenance = UNRESOLVED
        leg.reason = "funded_by_#{pay_in.downcase}"
        leg.excluded_reason = "no_balance_impact_funded_by_#{pay_in.downcase}"
        return leg
      end

      inconsistent = false
      reason = nil
      fee_quoted = quote_fee(quote)
      total = activity["secondaryAmount"].present? ? Text.parse_amount(activity["secondaryAmount"]) : nil
      amount = fee = nil
      amount_provenance = fee_provenance = nil

      # Transfers with a fixed target amount show what the recipient gets (in
      # the target currency) and put the source debit incl. fees second.
      shows_target = shown.value && shown.currency == target_currency && shown.magnitude == target_value && target_currency != source_currency
      if !shows_target && shown.value && (shown.magnitude != source_value || shown.currency != source_currency)
        inconsistent = true
        reason = "activity_amount_differs_from_transfer_source_value"
      end

      if total&.value && total.currency == source_currency
        amount = total.magnitude
        amount_provenance = EXPLICIT
        if fee_quoted && source_value && source_value + fee_quoted == amount
          fee, fee_provenance = fee_quoted, EXPLICIT
        elsif source_value
          fee, fee_provenance = amount - source_value, INFERRED
          if fee.negative? || fee_quoted
            inconsistent = true
            reason ||= fee.negative? ? "activity_total_below_transfer_source_value" : "quote_fee_contradicts_activity_total"
          end
        end
      elsif shows_target
        reason ||= "target_amount_shown_without_source_total"
      elsif fee_quoted&.zero? && source_value
        amount, amount_provenance = source_value, EXPLICIT
        fee, fee_provenance = 0.to_d, EXPLICIT
      elsif fee_quoted
        inconsistent = true
        reason ||= "quote_fee_without_activity_total"
        fee, fee_provenance = fee_quoted, EXPLICIT
      else
        reason ||= "fee_unknown_no_quote"
      end

      # The funding balance from the quote is authoritative and never
      # overridden by currency inference.
      pay_in_id = quote&.dig("payInId")
      if pay_in_id.present?
        account, balance_provenance, basis, bad = stated_balance(pay_in_id, source_currency)
        basis = "quote_pay_in_id" if balance_provenance
        if bad
          inconsistent = true
          reason ||= basis
        end
      else
        account, balance_provenance, basis = infer_balance(source_currency, at)
      end

      leg.wise_account = account
      leg.amount = signed(amount, "outflow")
      leg.currency = amount ? source_currency : nil
      leg.fee_amount = fee
      leg.fee_currency = fee ? source_currency : nil
      leg.field_provenance = {
        "amount" => amount_provenance || UNRESOLVED,
        "currency" => amount_provenance || UNRESOLVED,
        "source_balance" => balance_provenance || UNRESOLVED,
        "fee" => fee_provenance || UNRESOLVED
      }
      leg.provenance = combine(amount_provenance, balance_provenance, inconsistent: inconsistent)
      leg.reason = reason || (leg.provenance == UNRESOLVED ? basis : "stated_amount_#{basis}")
      leg.details = leg.details.merge("balance_basis" => basis, "quote_fee" => fee_quoted&.to_s).compact
      leg
    end

    # --- conversions between own balances --------------------------------------------

    def conversion_legs(activity)
      target = Text.parse_amount(activity["primaryAmount"])
      source = Text.parse_amount(activity["secondaryAmount"])
      at = time(activity["createdOn"])
      destination = Text.strip_tags(activity["title"]).delete_prefix("To ").strip
      rate = (target.magnitude / source.magnitude).round(6) if target.magnitude && source.magnitude&.positive?

      [ [ "source", "outflow", source ], [ "target", "inflow", target ] ].map do |leg_name, direction, amount|
        if leg_name == "target" && destination != amount.currency
          # Converted straight into a jar: only its name identifies it.
          account = registry.jar_named(destination, amount.currency)
          balance_provenance = account ? INFERRED : nil
          basis = account ? "jar_name_in_title" : "target_jar_not_identifiable"
        else
          account, balance_provenance, basis = infer_balance(amount.currency, at)
        end

        balance_field = direction == "inflow" ? "destination_balance" : "source_balance"
        leg = base_leg(
          activity,
          key: "activity:#{activity['id']}:#{leg_name}",
          category: "currency_conversion",
          direction: direction,
          wise_account: account,
          amount: signed(amount.magnitude, direction),
          currency: amount.currency,
          original_amount: amount.magnitude,
          original_currency: amount.currency,
          field_provenance: { "amount" => EXPLICIT, "currency" => EXPLICIT, balance_field => balance_provenance || UNRESOLVED, "fee" => "not_stated" },
          provenance: combine(amount.value ? EXPLICIT : nil, balance_provenance),
          reason: "conversion_#{leg_name}_#{basis}"
        )
        leg.details = leg.details.merge(
          "conversion_leg" => leg_name,
          "counterpart_key" => "activity:#{activity['id']}:#{leg_name == 'source' ? 'target' : 'source'}",
          "effective_rate" => rate&.to_s,
          "source_amount" => source.magnitude&.to_s,
          "source_currency" => source.currency,
          "target_amount" => target.magnitude&.to_s,
          "target_currency" => target.currency,
          "destination_title" => destination,
          "fee_note" => "Wise states no separate conversion fee; it is inside the rate"
        ).compact
        leg
      end
    end

    # --- batch payments -----------------------------------------------------------

    # Member transfers carry no batch id anywhere in Wise's API. They are
    # matched by creation time (within 15 minutes) and never become ledger
    # legs themselves, so a batch is counted exactly once.
    def batch_members(activity)
      at = time(activity["createdOn"])
      return [] unless at

      @transfers.filter_map do |id, record|
        data = record["transfer"] || {}
        next unless record["profile_id"].to_s == @wise_item.profile_id.to_s
        next if @own_activity_transfer_ids.include?(id)

        created = time(data["created"])
        next unless created && (created - at).abs <= BATCH_WINDOW

        claimed = @batch_claims[id]
        next if claimed && claimed != activity["id"]

        @batch_claims[id] = activity["id"]
        record
      end.sort_by { |record| record.dig("transfer", "id").to_s }
    end

    def batch_legs(activity)
      members = batch_members(activity)
      live = members.reject { |member| member.dig("transfer", "status") == "cancelled" }
      refunded = live.select { |member| member.dig("transfer", "status") == "funds_refunded" }
      shown = Text.parse_amount(activity["primaryAmount"])
      total = activity["secondaryAmount"].present? ? Text.parse_amount(activity["secondaryAmount"]) : nil
      at = time(activity["createdOn"])
      member_ids = members.map { |member| member.dig("transfer", "id").to_s }

      base = {
        category: "batch_payment",
        direction: "outflow",
        counterparty_name: Text.strip_tags(activity["title"]).presence
      }

      source_account = lambda do |currency, ms|
        ids = ms.map { |member| member.dig("quote", "payInId")&.to_s }
        if ids.any? && ids.all?(&:present?) && ids.uniq.one?
          account, provenance, basis, bad = stated_balance(ids.first, currency)
          [ account, provenance, provenance ? "member_quotes_pay_in_id" : basis, bad ]
        else
          [ *infer_balance(currency, at), false ]
        end
      end

      if shown.value && shown.currency
        ms = live.select { |member| member.dig("transfer", "sourceCurrency") == shown.currency }
        member_sum = ms.sum { |member| decimal(member.dig("transfer", "sourceValue")).to_d }
        fees = ms.map { |member| quote_fee(member["quote"]) }
        fee_sum = ms.any? && fees.none?(&:nil?) ? fees.sum : nil
        members_match = ms.any? && member_sum == shown.magnitude && ms.size == live.size
        inconsistent = false
        reason = nil

        if total&.value && total.currency == shown.currency
          amount, amount_provenance = total.magnitude, EXPLICIT
          fee = total.magnitude - shown.magnitude
          fee_provenance = fee_sum && fee_sum == fee ? EXPLICIT : INFERRED
        elsif fee_sum&.positive?
          amount = amount_provenance = nil
          fee, fee_provenance = fee_sum, INFERRED
          inconsistent = true
          reason = "member_fees_without_activity_total"
        else
          amount, amount_provenance = shown.magnitude, EXPLICIT
          fee, fee_provenance = fee_sum&.zero? ? [ 0.to_d, EXPLICIT ] : [ nil, nil ]
        end

        account, balance_provenance, basis, bad = source_account.call(shown.currency, ms.presence || live)
        provenance = combine(amount_provenance, balance_provenance, inconsistent: inconsistent || bad)
        if refunded.any? && provenance != UNRESOLVED
          provenance = UNRESOLVED
          reason = "batch_member_refunded_refund_leg_not_visible"
        end

        leg = base_leg(
          activity, **base,
          wise_account: account,
          amount: signed(amount, "outflow"),
          currency: amount ? shown.currency : nil,
          fee_amount: fee,
          fee_currency: fee ? shown.currency : nil,
          original_amount: shown.magnitude,
          original_currency: shown.currency,
          field_provenance: {
            "amount" => amount_provenance || UNRESOLVED,
            "currency" => amount_provenance || UNRESOLVED,
            "source_balance" => balance_provenance || UNRESOLVED,
            "fee" => fee_provenance || UNRESOLVED
          },
          provenance: provenance,
          reason: reason || "batch_total_stated_#{basis}"
        )
        leg.details = leg.details.merge(
          "member_transfer_ids" => member_ids,
          "member_source_sum" => member_sum.to_s,
          "member_fee_sum" => fee_sum&.to_s,
          "members_match_total" => members_match,
          "member_match_basis" => "created within 15 minutes; Wise exposes no batch id",
          "refunded_member_ids" => refunded.map { |member| member.dig("transfer", "id").to_s }.presence
        ).compact
        return [ leg ]
      end

      if Text.currency_list?(activity["primaryAmount"]) && live.any?
        return live.group_by { |member| member.dig("transfer", "sourceCurrency") }.sort_by(&:first).map do |currency, ms|
          fees = ms.map { |member| quote_fee(member["quote"]) }
          if fees.any?(&:nil?)
            amount = fee = nil
            reason = "member_fee_unknown"
          else
            fee = fees.sum
            amount = ms.sum { |member| decimal(member.dig("transfer", "sourceValue")).to_d } + fee
            reason = "per_currency_total_from_members"
          end
          account, balance_provenance, basis, bad = source_account.call(currency, ms)
          provenance = combine(amount ? INFERRED : nil, balance_provenance, inconsistent: bad)
          if refunded.any? && provenance != UNRESOLVED
            provenance = UNRESOLVED
            reason = "batch_member_refunded_refund_leg_not_visible"
          end

          leg = base_leg(
            activity, **base,
            key: "activity:#{activity['id']}:#{currency}",
            wise_account: account,
            amount: signed(amount, "outflow"),
            currency: amount ? currency : nil,
            fee_amount: fee,
            fee_currency: fee ? currency : nil,
            field_provenance: {
              "amount" => amount ? INFERRED : UNRESOLVED,
              "currency" => EXPLICIT,
              "source_balance" => balance_provenance || UNRESOLVED,
              "fee" => fee ? INFERRED : UNRESOLVED
            },
            provenance: provenance,
            reason: provenance == UNRESOLVED ? reason : "#{reason}_#{basis}"
          )
          leg.details = leg.details.merge(
            "member_transfer_ids" => ms.map { |member| member.dig("transfer", "id").to_s },
            "members_match_total" => false,
            "member_match_basis" => "created within 15 minutes; Wise exposes no batch id"
          )
          leg
        end
      end

      [ base_leg(activity, **base, provenance: UNRESOLVED, reason: "batch_amount_and_members_unknown",
                 details: { "member_transfer_ids" => member_ids }) ]
    end
end
