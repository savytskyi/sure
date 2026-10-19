# frozen_string_literal: true

# Collects what activity reconstruction needs for one sync window and stores
# the resulting legs as ProviderLedgerRecords:
#
# 1. Transfer orders created in the window (GET /v1/transfers), kept as
#    `transfer_order` reference records, with their quote (fee, funding
#    balance) and recipient account, each fetched once and cached.
# 2. Balances Wise references but no longer lists (a quote's payInId) are
#    added as `discovered` WiseAccounts with their observed usage window.
# 3. WiseItem::LedgerReconstructor turns the window's activities into legs,
#    which are upserted by stable key. Re-running a window changes nothing.
#
# Read-only against Wise. Only GET endpoints are used.
class WiseItem::LedgerCollector
  TRANSFER_PAGE_SIZE = 100
  PROVIDER_KEY = "wise"
  SOURCE = "wise"

  Result = Data.define(:complete, :legs, :errors)

  attr_reader :wise_item, :wise_provider

  def initialize(wise_item, wise_provider:, window_start:, window_end:)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @window_start = window_start
    @window_end = window_end
    @errors = []
    @recipient_cache = {}
  end

  def collect(activities)
    transfers_complete = collect_transfers
    details_complete = collect_transfer_details
    discover_balances!

    legs = reconstructor(activities).legs(activities)
    legs.each { |leg| upsert_leg(leg) }
    mark_batch_members(legs)

    Result.new(complete: transfers_complete && details_complete, legs: legs.size, errors: @errors)
  end

  private
    def family
      wise_item.family
    end

    def records
      wise_item.ledger_records
    end

    # --- transfer orders ---------------------------------------------------------

    def collect_transfers
      offset = 0
      loop do
        page = with_rate_limit_retry do
          wise_provider.get_transfers(
            wise_item.profile_id,
            limit: TRANSFER_PAGE_SIZE,
            offset: offset,
            created_from: @window_start - 1.day,
            created_to: @window_end
          )
        end
        batch = Array(page.is_a?(Hash) ? page["content"] : page)
        batch.each { |transfer| upsert_transfer_order(transfer) }
        break if batch.size < TRANSFER_PAGE_SIZE

        offset += TRANSFER_PAGE_SIZE
      end
      true
    rescue Provider::Wise::WiseError => e
      @errors << { operation: "transfers", error_type: e.error_type }
      false
    end

    def upsert_transfer_order(transfer)
      return if transfer["id"].blank?

      record = records.find_or_initialize_by(external_key: "transfer:#{transfer['id']}")
      payload = (record.raw_payload || {}).merge("transfer" => transfer, "profile_id" => wise_item.profile_id.to_s)
      record.assign_attributes(
        family: family,
        provider_key: PROVIDER_KEY,
        category: "transfer_order",
        provenance: "provider_explicit",
        status: :excluded,
        reason: "reference_data",
        occurred_at: parse_time(transfer["created"]),
        amount: transfer["sourceValue"]&.to_s&.to_d,
        currency: transfer["sourceCurrency"],
        original_amount: transfer["targetValue"]&.to_s&.to_d,
        original_currency: transfer["targetCurrency"],
        provider_resource_type: "TRANSFER",
        provider_resource_id: transfer["id"].to_s,
        provider_transfer_id: transfer["id"].to_s,
        payment_reference: transfer["reference"].presence || transfer.dig("details", "reference").presence,
        raw_payload: payload,
        details: record.details.merge(
          "transfer_status" => transfer["status"],
          "target_account" => transfer["targetAccount"]&.to_s,
          "quote_uuid" => transfer["quoteUuid"]
        ).compact
      )
      record.save!
    end

    # Quotes and recipients of a funded transfer never change, so each is
    # fetched once. A 404 is remembered; a refusal stops further detail
    # requests for this sync and leaves fees and funding balances unknown.
    def collect_transfer_details
      complete = true
      window_transfer_orders.each do |record|
        payload = record.raw_payload || {}
        transfer = payload["transfer"] || {}
        changed = false

        if payload["quote"].nil? && record.details["quote_state"].nil? && transfer["quoteUuid"].present? && !@quotes_unavailable
          state, quote = fetch_detail(:quote) { wise_provider.get_quote(wise_item.profile_id, transfer["quoteUuid"]) }
          @quotes_unavailable = true if state == "unavailable"
          complete &&= state != "failed"
          payload = payload.merge("quote" => quote) if quote
          record.details = record.details.merge("quote_state" => state) unless state.in?(%w[failed unavailable])
          changed = true
        end

        target = transfer["targetAccount"].presence&.to_s
        if target && payload["recipient"].nil? && record.details["recipient_state"].nil? && !@recipients_unavailable
          state, recipient = cached_recipient(target) || fetch_detail(:recipient) { wise_provider.get_recipient_account(target) }
          @recipient_cache[target] = [ state, recipient ] if state.in?(%w[ok not_found])
          @recipients_unavailable = true if state == "unavailable"
          complete &&= state != "failed"
          payload = payload.merge("recipient" => recipient) if recipient
          record.details = record.details.merge("recipient_state" => state) unless state.in?(%w[failed unavailable])
          changed = true
        end

        if changed
          record.raw_payload = payload
          record.save!
        end
      end

      checkpoint_details_state(@quotes_unavailable || @recipients_unavailable ? "unavailable" : "ok")
      complete
    end

    def window_transfer_orders
      records.where(category: "transfer_order", occurred_at: (@window_start - 1.day)..@window_end)
    end

    def fetch_detail(kind)
      [ "ok", with_rate_limit_retry { yield } ]
    rescue Provider::Wise::WiseError => e
      case e.error_type
      when :not_found then [ "not_found", nil ]
      when :access_forbidden, :unauthorized
        @errors << { operation: kind.to_s, error_type: e.error_type }
        [ "unavailable", nil ]
      else
        @errors << { operation: kind.to_s, error_type: e.error_type }
        [ "failed", nil ]
      end
    end

    def cached_recipient(target)
      return @recipient_cache[target] if @recipient_cache.key?(target)

      known = family_transfer_orders
        .where("details->>'target_account' = ? AND details->>'recipient_state' = 'ok'", target)
        .first
      [ "ok", known.raw_payload["recipient"] ] if known&.raw_payload&.dig("recipient")
    end

    def checkpoint_details_state(state)
      wise_item.update_checkpoint!("transfer_details", "state" => state, "checked_at" => Time.current.iso8601)
    end

    # --- balances no longer listed ------------------------------------------------------

    def discover_balances!
      uses = {}
      records.where(category: "transfer_order").find_each do |record|
        payload = record.raw_payload || {}
        quote = payload["quote"]
        next unless quote&.dig("payInId").present? && (quote["payInMethod"].presence || "BALANCE") == "BALANCE"
        next unless (quote["profile"].presence || wise_item.profile_id).to_s == wise_item.profile_id.to_s
        next if record.occurred_at.nil? || record.currency.blank?

        key = quote["payInId"].to_s
        use = uses[key] ||= { currency: record.currency, first: record.occurred_at, last: record.occurred_at }
        use[:first] = [ use[:first], record.occurred_at ].min
        use[:last] = [ use[:last], record.occurred_at ].max
      end

      uses.each do |balance_id, use|
        account = wise_item.wise_accounts.find_or_initialize_by(balance_id: balance_id)
        next if account.persisted? && !account.discovered?

        account.assign_attributes(
          status: :discovered,
          currency: account.currency || use[:currency],
          name: account.name.presence || "Wise #{use[:currency]} (balance #{balance_id}, no longer listed)",
          raw_payload: account.raw_payload || { "type" => "STANDARD", "discovered_from" => "quote.payInId" },
          first_observed_at: [ account.first_observed_at, use[:first] ].compact.min,
          last_observed_at: [ account.last_observed_at, use[:last] ].compact.max
        )
        account.save!
      end
    end

    # --- legs ---------------------------------------------------------------------------

    def reconstructor(activities)
      WiseItem::LedgerReconstructor.new(
        wise_item: wise_item,
        registry: WiseItem::BalanceRegistry.new(wise_item.wise_accounts.reload),
        transfers: transfer_lookup(activities),
        own_profiles: family.wise_items.pluck(:profile_id, :profile_type).to_h { |id, type| [ id.to_s, type ] }
      )
    end

    # This profile's transfer orders around the window (batch matching), plus
    # any own profile's order an activity names (incoming legs from the
    # business profile, older outgoing transfers completing now).
    def transfer_lookup(activities)
      referenced = activities.filter_map { |activity| activity.dig("resource", "id")&.to_s if activity.dig("resource", "type") == "TRANSFER" }
      scope = family_transfer_orders.where(provider_transfer_id: referenced)
        .or(family_transfer_orders.where(item: wise_item, occurred_at: (@window_start - 1.day)..@window_end))
      scope.each_with_object({}) do |record, map|
        map[record.provider_transfer_id] = record.raw_payload || {}
      end
    end

    def family_transfer_orders
      ProviderLedgerRecord.where(family: family, provider_key: PROVIDER_KEY, category: "transfer_order")
    end

    def upsert_leg(leg)
      record = records.find_or_initialize_by(external_key: leg.key)
      record.assign_attributes(
        family: family,
        provider_key: PROVIDER_KEY,
        provider_account: leg.wise_account,
        category: leg.category,
        provenance: leg.provenance,
        reason: leg.reason,
        field_provenance: leg.field_provenance || {},
        occurred_at: leg.occurred_at,
        amount: leg.amount,
        currency: leg.currency,
        fee_amount: leg.fee_amount,
        fee_currency: leg.fee_currency,
        original_amount: leg.original_amount,
        original_currency: leg.original_currency,
        provider_resource_type: leg.resource_type,
        provider_resource_id: leg.resource_id,
        provider_transfer_id: leg.transfer_id,
        name: leg.name,
        counterparty_name: leg.counterparty_name,
        merchant_name: leg.merchant_name,
        payment_reference: leg.payment_reference,
        details: record.details.slice("merchant_id", "import_digest", "duplicate_candidate_entry_ids")
          .merge(leg.details || {})
          .merge("statement_reference" => leg.statement_reference).compact,
        raw_payload: leg.raw
      )
      apply_status(record, leg)
      record.save!
    end

    def apply_status(record, leg)
      return if record.dismissed?

      if leg.excluded?
        if record.imported?
          ledger_importer(record).withdraw!(leg.excluded_reason)
        elsif !record.withdrawn?
          record.status = :excluded
          record.reason = leg.excluded_reason
        end
      elsif statement_covered?(record)
        if record.imported?
          ledger_importer(record).supersede!("wise_statement_#{record.details['statement_reference']}")
        else
          record.status = :superseded
          record.reason = "covered_by_statement"
        end
      elsif !record.importable_provenance? || record.provider_account.nil?
        record.status = :needs_review
      elsif !record.imported?
        # Possible duplicates are re-checked on every sync.
        record.status = :ready
      end
    end

    def ledger_importer(record)
      account = record.account || record.provider_account&.current_account
      ProviderLedgerRecord::Importer.new(record, account: account, source: SOURCE)
    end

    # A verified statement for this balance already covers the time: the
    # statement line is the ledger entry, the leg is only provenance.
    def statement_covered?(record)
      wise_account = record.provider_account
      return false unless wise_account && record.occurred_at && record.details["statement_reference"]

      coverage = wise_item.statement_coverage(wise_account.balance_id)
      return false unless coverage

      from = parse_time(coverage["covered_from"])
      to = parse_time(coverage["covered_to"])
      from.present? && to.present? && record.occurred_at.between?(from, to)
    end

    def mark_batch_members(legs)
      legs.select { |leg| leg.category == "batch_payment" }.each do |leg|
        ids = Array(leg.details&.dig("member_transfer_ids"))
        next if ids.empty?

        status = leg.details["members_match_total"] ? "high_confidence" : "ambiguous"
        records.where(category: "transfer_order", provider_transfer_id: ids).find_each do |member|
          member.update!(relationship: {
            "type" => "batch_member",
            "status" => status,
            "batch_key" => leg.key,
            "basis" => "created within 15 minutes of the batch#{status == 'high_confidence' ? '; member amounts sum to the batch total' : ''}"
          })
        end
      end
    end

    def parse_time(raw)
      return raw if raw.is_a?(Time) || raw.is_a?(ActiveSupport::TimeWithZone)
      return nil if raw.blank?

      Time.find_zone("UTC").parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def with_rate_limit_retry(max_retries: 3)
      retries = 0
      begin
        yield
      rescue Provider::Wise::WiseError => e
        raise unless e.error_type == :rate_limited && retries < max_retries
        retries += 1
        sleep(2**retries)
        retry
      end
    end
end
