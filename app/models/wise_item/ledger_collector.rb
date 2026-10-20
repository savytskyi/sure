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
  # Detail keys owned by import and operator decisions, not re-derived from Wise.
  PRESERVED_DETAILS = %w[
    merchant_id import_digest duplicate_candidate_entry_ids imported_provider_account_id
    moved_from_account_id resolution classification
  ].freeze

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
    retire_replaced_batch_legs(legs)
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
    # fetched once and cached on its transfer order; a 404 is remembered. A
    # refusal, a rate limit or the per-sync request budget stops further
    # detail requests: the sync reports itself incomplete (the checkpoint
    # holds) and the next one continues where this one stopped. Legs whose
    # quote is still missing stay unresolved until then.
    def collect_transfer_details
      complete = true
      @detail_budget = Rails.configuration.x.wise.detail_requests_per_sync
      window_transfer_orders.order(:occurred_at).each do |record|
        payload = record.raw_payload || {}
        transfer = payload["transfer"] || {}
        changed = false

        if payload["quote"].nil? && record.details["quote_state"].nil? && transfer["quoteUuid"].present? && !@quotes_unavailable && !detail_fetching_stopped?
          state, quote = fetch_detail(:quote) { wise_provider.get_quote(wise_item.profile_id, transfer["quoteUuid"]) }
          @quotes_unavailable = true if state == "unavailable"
          complete &&= state != "failed"
          payload = payload.merge("quote" => quote) if quote
          record.details = record.details.merge("quote_state" => state) unless state.in?(%w[failed unavailable])
          changed = true
        end

        target = transfer["targetAccount"].presence&.to_s
        if target && payload["recipient"].nil? && record.details["recipient_state"].nil? &&
           (cached = cached_recipient(target) || (detail_fetching_stopped? ? nil : :fetch))
          state, recipient = cached == :fetch ? fetch_detail(:recipient) { wise_provider.get_recipient_account(target) } : cached
          # One recipient Wise refuses to show (another user's account) must
          # not stop the others; it is remembered like a 404.
          state = "forbidden" if state == "unavailable"
          @recipient_cache[target] = [ state, recipient ] if state.in?(%w[ok not_found forbidden])
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

      complete &&= !detail_fetching_stopped? || pending_details.none?
      checkpoint_details_state(@quotes_unavailable ? "unavailable" : "ok")
      complete
    end

    def detail_fetching_stopped?
      @rate_limited || @detail_budget <= 0
    end

    # Transfer orders in the window still waiting for a quote or recipient.
    def pending_details
      window_transfer_orders.select do |record|
        transfer = record.raw_payload&.dig("transfer") || {}
        (transfer["quoteUuid"].present? && record.raw_payload&.dig("quote").nil? && record.details["quote_state"].nil? && !@quotes_unavailable) ||
          (transfer["targetAccount"].present? && record.raw_payload&.dig("recipient").nil? && record.details["recipient_state"].nil?)
      end
    end

    def window_transfer_orders
      records.where(category: "transfer_order", occurred_at: (@window_start - 1.day)..@window_end)
    end

    def fetch_detail(kind)
      @detail_budget -= 1
      [ "ok", with_rate_limit_retry { yield } ]
    rescue Provider::Wise::WiseError => e
      case e.error_type
      when :not_found then [ "not_found", nil ]
      when :rate_limited
        @rate_limited = true
        @errors << { operation: kind.to_s, error_type: e.error_type }
        [ "failed", nil ]
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
        details: record.details.slice(*PRESERVED_DETAILS)
          .merge(leg.details || {})
          .merge("statement_reference" => leg.statement_reference).compact,
        raw_payload: leg.raw
      )
      WiseItem::LedgerResolution.apply(record)
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
        record.status = :superseded
        record.reason = "covered_by_statement"
      elsif !record.importable_provenance? || record.provider_account.nil? || record.amount.nil?
        # A leg imported earlier keeps its entry; review decides what it is now.
        record.reason = "previously_imported_now_#{record.reason}" if record.imported? && !record.reason.to_s.start_with?("previously_imported")
        record.status = :needs_review
      elsif !record.imported? || record.needs_review?
        # Possible duplicates are re-checked on every sync; a leg that was
        # imported and became unresolved returns to the ledger once resolved.
        record.status = record.entry_id.present? ? :imported : :ready
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
      legs.each do |leg|
        if leg.category == "batch_payment"
          ids = Array(leg.details&.dig("member_transfer_ids"))
          status = leg.details["members_match_total"] ? "high_confidence" : "ambiguous"
          relationship = {
            "type" => "batch_member",
            "status" => status,
            "batch_key" => leg.key,
            "basis" => "created within 15 minutes of the batch#{status == 'high_confidence' ? '; member amounts sum to the batch total' : ''}"
          }
        elsif leg.details&.dig("batch_key") && leg.transfer_id
          ids = [ leg.transfer_id ]
          relationship = {
            "type" => "batch_member",
            "status" => "unpacked",
            "batch_key" => leg.details["batch_key"],
            "leg_key" => leg.key,
            "basis" => "created within 15 minutes of the batch; booked as its own payment"
          }
        else
          next
        end
        next if ids.empty?

        records.where(category: "transfer_order", provider_transfer_id: ids).find_each do |member|
          member.update!(relationship: relationship)
        end
      end
    end

    # A batch is either one debit or one leg per member. When a sync changes
    # which (members came to light, or no longer add up), the legs the batch
    # no longer produces are withdrawn, so it is never counted twice.
    def retire_replaced_batch_legs(legs)
      legs.select { |leg| leg.details&.dig("activity_type") == "BATCH_TRANSFER" }
        .group_by { |leg| leg.raw["id"].to_s }
        .each do |activity_id, current|
          key = "activity:#{activity_id}"
          records.where("external_key = ? OR external_key LIKE ?", key, "#{ActiveRecord::Base.sanitize_sql_like(key)}:%")
            .where.not(external_key: current.map(&:key))
            .where.not(status: %i[withdrawn dismissed excluded])
            .find_each do |record|
              if record.imported?
                ledger_importer(record).withdraw!("batch_breakdown_changed")
              else
                record.update!(status: :excluded, reason: "batch_breakdown_changed")
              end
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
