# frozen_string_literal: true

# Fetches one Wise profile's data and stores it for processing:
#
# - Balances (STANDARD and SAVINGS jars) become WiseAccounts. A balance that
#   is no longer returned is marked closed, never deleted.
# - Balance statements, where Wise allows them, are the verified ledger
#   (WiseStatement::Processor). Each balance keeps its own checkpoint.
# - The activity feed is read for the sync window. Jar movements, interest
#   and fees go to the jar payloads (WiseActivity::Processor); everything else
#   (card payments, incoming/outgoing payments, conversions, batches) is
#   reconstructed by WiseItem::LedgerCollector with explicit provenance,
#   because Wise blocks statements for personal tokens in most regions.
#
# Incremental: activity and transfer windows start at the last fully
# collected point minus an overlap (WISE_SYNC_OVERLAP_DAYS, default 14). A
# checkpoint only advances after the whole window was collected.
class WiseItem::Importer
  DEFAULT_HISTORY_DAYS = 365
  # Wise has existed since 2011, so this safely predates any account creation.
  FULL_HISTORY_START_DATE = Date.new(2000, 1, 1)
  ACTIVITY_PAGE_SIZE = 100
  MAX_ACTIVITY_PAGES = 10_000
  # Pending activities are re-read until they complete, within this horizon.
  PENDING_REFRESH_DAYS = 120
  # Statements a token cannot read are retried weekly, not on every sync.
  STATEMENT_RETRY_INTERVAL = 7.days
  STATEMENT_UNAVAILABLE_ERRORS = %i[access_forbidden not_found sca_key_invalid].freeze

  attr_reader :wise_item, :wise_provider, :sync_start_date

  def initialize(wise_item, wise_provider:, sync_start_date: nil)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @sync_start_date = sync_start_date
  end

  def import
    Rails.logger.info "WiseItem::Importer - Starting import for item #{wise_item.id} (profile #{wise_item.profile_id})"

    balances = fetch_balances
    return failed_result("Failed to fetch balances") if balances.nil?

    savings_balances = fetch_savings_balances
    all_balances = Array(balances) + Array(savings_balances)

    borderless_accounts = fetch_borderless_accounts
    account_result = import_balances(all_balances, borderless_accounts: borderless_accounts)
    mark_closed_balances!(all_balances) if Array(balances).any? && !@savings_fetch_failed

    statements = fetch_statements
    activity_window = activity_window_range
    activities = fetch_activities(activity_window)

    transaction_result = store_transactions_per_account(
      statements: statements,
      statement_failures: Array(@statement_fetch_failed_accounts)
    )

    ledger_result = collect_ledger(activities, activity_window)

    success = account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero? && ledger_result[:ledger_complete]
    wise_item.update!(status: :good) if success

    {
      success: success,
      **account_result,
      **transaction_result,
      **ledger_result
    }
  end

  private

    def fetch_balances
      wise_provider.get_balances(wise_item.profile_id)
    rescue Provider::Wise::WiseError => e
      if e.error_type == :not_found
        Rails.logger.info "WiseItem::Importer - No balances for profile #{wise_item.profile_id}"
        return []
      end
      mark_requires_update_if_credentials_error(e)
      Rails.logger.error "WiseItem::Importer - Failed to fetch balances: #{e.message}"
      # A rejected token fails the sync instead of completing it with nothing imported
      raise if credentials_error?(e)
      nil
    rescue => e
      Rails.logger.error "WiseItem::Importer - Unexpected error fetching balances: #{e.class} - #{e.message}"
      nil
    end

    def fetch_savings_balances
      wise_provider.get_savings_balances(wise_item.profile_id)
    rescue Provider::Wise::WiseError => e
      @savings_fetch_failed = true
      Rails.logger.info "WiseItem::Importer - No savings (JAR) balances for profile #{wise_item.profile_id}: #{e.message}"
      []
    rescue => e
      @savings_fetch_failed = true
      Rails.logger.warn "WiseItem::Importer - Unexpected error fetching savings balances: #{e.message}"
      []
    end

    # Returns a map of { balance_id => { borderless_account_id:, recipient_id: } }.
    # Used in WiseEntry::Processor to distinguish expenses (targetAccount != recipientId)
    # from incomes (targetAccount == recipientId).
    def fetch_borderless_accounts
      trace_wise_fetch(operation: "borderless_accounts", status: "started", level: "info")
      result = wise_provider.get_borderless_accounts(wise_item.profile_id)
      trace_wise_fetch(
        operation: "borderless_accounts",
        status: "completed",
        level: "info",
        received_record_count: Array(result).size
      )
      Array(result).each_with_object({}) do |ba, map|
        borderless_id = ba["id"]
        recipient_id  = ba["recipientId"]
        Array(ba["balances"]).each do |b|
          map[b["id"].to_s] = { borderless_account_id: borderless_id, recipient_id: recipient_id }
        end
      end
    rescue => e
      trace_wise_fetch(operation: "borderless_accounts", status: "failed", level: "warn", error: e)
      {}
    end

    def import_balances(balances, borderless_accounts: {})
      accounts_created = 0
      accounts_updated = 0
      accounts_failed = 0

      existing_ids = wise_item.wise_accounts.pluck(:balance_id).map(&:to_s).to_set

      Array(balances).each do |balance_data|
        data = balance_data.with_indifferent_access
        balance_id = data[:id].to_s
        currency = data.dig(:amount, :currency).to_s

        next if balance_id.blank? || currency.blank?

        account_ids = borderless_accounts[balance_id] || {}

        is_savings = data[:type] == "SAVINGS"
        api_name   = data[:name].presence

        wise_account = wise_item.wise_accounts.find_or_initialize_by(balance_id: balance_id)
        wise_account.currency ||= currency
        wise_account.name ||= api_name || (is_savings ? "Wise JAR #{currency}" : "Wise #{currency}")
        wise_account.upsert_wise_snapshot!(
          data,
          borderless_account_id: account_ids[:borderless_account_id],
          recipient_id: account_ids[:recipient_id]
        )

        if existing_ids.include?(balance_id)
          accounts_updated += 1
        else
          accounts_created += 1
          existing_ids << balance_id
        end
      rescue => e
        accounts_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to import balance #{balance_id.presence || 'unknown'}: #{e.message}"
      end

      { accounts_created: accounts_created, accounts_updated: accounts_updated, accounts_failed: accounts_failed }
    end

    # A listed balance Wise no longer returns has been closed. Its account,
    # entries and history stay; it just stops absorbing new activity.
    def mark_closed_balances!(balances)
      listed = Array(balances).filter_map { |balance| balance["id"]&.to_s }.to_set
      wise_item.wise_accounts.active.where.not(balance_id: listed.to_a).find_each do |wise_account|
        wise_account.update!(status: :closed, closed_at: Time.current)
      end
    end

    # --- statements ----------------------------------------------------------

    # Fetches statement rows for STANDARD balances. Legacy transfer snapshots
    # are retained; outgoing statement rows dated on/after the oldest legacy
    # transfer are dropped since transfers already captured that side (see
    # #legacy_overlap_outgoing_row?), while incoming rows there are kept so
    # money the legacy fallback could never capture (external payments) gets
    # backfilled.
    def fetch_statements
      @statement_fetch_failed_accounts = []

      wise_item.wise_accounts.active.each_with_object({}) do |wise_account, result|
        next if wise_account.jar?

        checkpoint = wise_item.statement_coverage(wise_account.balance_id) || {}
        next if statement_retry_pending?(checkpoint)

        existing = Array(wise_account.raw_transactions_payload)
        legacy = existing.select do |transaction|
          transaction["wise_statement"].blank? && transaction["type"].blank?
        end
        legacy_cutoff = legacy.filter_map { |transaction| parse_transaction_date(transaction) }.min

        start_date =
          if existing.any? { |transaction| transaction["wise_statement"].present? } &&
             sync_start_date.blank? && wise_item.sync_start_date.blank? && wise_item.last_synced_at.present?
            # Incremental: once statements exist, only fetch the short overlap.
            (wise_item.last_synced_at - overlap_days.days).to_date
          elsif full_history?
            full_history_start_date(wise_account)
          else
            sync_start_date_value
          end
        end_date = Date.current

        next if start_date > end_date

        trace_wise_fetch(
          operation: "balance_statement",
          status: "started",
          level: "info",
          wise_account: wise_account,
          start_date: start_date,
          end_date: end_date
        )
        rows = wise_provider.get_balance_statements(
          wise_item.profile_id,
          wise_account.balance_id,
          currency: wise_account.currency,
          start_date: start_date,
          end_date: end_date
        )
        received_row_count = Array(rows).size
        rows = Array(rows).reject { |row| legacy_overlap_outgoing_row?(row, legacy_cutoff) }
        trace_wise_fetch(
          operation: "balance_statement",
          status: "completed",
          level: "info",
          wise_account: wise_account,
          received_row_count: received_row_count,
          stored_row_count: rows.size
        )
        covered_from = [ checkpoint["covered_from"]&.to_date, start_date ].compact.min
        wise_item.update_statement_checkpoint!(wise_account.balance_id,
          "state" => "ok",
          "covered_from" => covered_from.beginning_of_day.utc.iso8601,
          "covered_to" => Time.current.utc.iso8601,
          "checked_at" => Time.current.utc.iso8601)
        result[wise_account.id] = rows.map { |row| row.merge("wise_statement" => true) }
      rescue Provider::Wise::WiseError => e
        handle_statement_failure(wise_account, e, checkpoint)
        result[wise_account.id] = []
      rescue => e
        handle_statement_failure(wise_account, e, checkpoint)
        result[wise_account.id] = []
      end
    end

    # Wise refuses statements to personal tokens in most regions. That is a
    # permanent restriction, recorded once as `unavailable` (activity
    # reconstruction covers the balance) and retried weekly. Other failures
    # count against this balance only.
    def handle_statement_failure(wise_account, error, checkpoint)
      unavailable = error.respond_to?(:error_type) && STATEMENT_UNAVAILABLE_ERRORS.include?(error.error_type)
      first_report = checkpoint["state"] != "unavailable"

      if unavailable
        wise_item.update_statement_checkpoint!(wise_account.balance_id,
          "state" => "unavailable",
          "error_type" => error.error_type.to_s,
          "checked_at" => Time.current.utc.iso8601)
      else
        @statement_fetch_failed_accounts << wise_account.id
      end

      return unless !unavailable || first_report

      trace_wise_fetch(operation: "balance_statement", status: unavailable ? "unavailable" : "failed", level: "warn", wise_account: wise_account, error: error)
    end

    def statement_retry_pending?(checkpoint)
      return false unless checkpoint["state"] == "unavailable" && checkpoint["checked_at"].present?

      Time.zone.parse(checkpoint["checked_at"]) > STATEMENT_RETRY_INTERVAL.ago
    rescue ArgumentError
      false
    end

    # The legacy /v1/transfers fallback captured outgoing money unconditionally,
    # plus the incoming leg of any internal cross-currency conversion between
    # the profile's own balances (transfers where this balance is the target).
    # So an outgoing statement row (Wise reports debits as non-positive) dated
    # on/after the oldest legacy transfer already has a legacy counterpart and
    # would double-book it. Incoming rows are always kept: silently dropping a
    # real external payment is worse than a visible, user-correctable
    # duplicate of a historical conversion.
    def legacy_overlap_outgoing_row?(row, legacy_cutoff)
      return false unless legacy_cutoff

      date = parse_transaction_date(row)
      return false unless date && date >= legacy_cutoff

      row.dig("amount", "value").to_d <= 0
    end

    # --- activities ----------------------------------------------------------

    def activity_window_range
      checkpoint = wise_item.checkpoint("activities")
      desired = desired_start_time
      start = desired

      covered_to = parse_time(checkpoint["covered_to"])
      covered_from = parse_time(checkpoint["covered_from"])
      if covered_to && covered_from && covered_from <= desired && sync_start_date.blank?
        start = [ desired, covered_to - overlap_days.days ].max
      end

      # Wise changes old activities: a refunded transfer turns CANCELLED, a
      # card payment is reversed. Periodically the whole refresh horizon is
      # re-read so those changes reach the ledger.
      refreshed_at = parse_time(checkpoint["refreshed_at"])
      @refresh_due = covered_to.present? && (refreshed_at.nil? || refreshed_at < refresh_interval_days.days.ago)
      # A first backfill reads everything, which counts as a refresh.
      @initial_window = covered_to.nil?
      start = [ start, [ desired, refresh_days.days.ago ].max ].min if @refresh_due

      pending_floor = wise_item.ledger_records
        .where(status: :excluded, reason: "pending")
        .where(occurred_at: PENDING_REFRESH_DAYS.days.ago..)
        .minimum(:occurred_at)
      start = [ start, pending_floor ].min if pending_floor

      start..Time.current
    end

    def desired_start_time
      if sync_start_date.present? || wise_item.sync_start_date.present?
        sync_start_date_value.to_time.utc
      elsif full_history?
        FULL_HISTORY_START_DATE.to_time.utc
      else
        DEFAULT_HISTORY_DAYS.days.ago
      end
    end

    # Reads every activity in the window, newest first, following Wise's
    # `nextCursor`. @activities_complete is false if any page failed, so the
    # checkpoint does not move past a gap.
    def fetch_activities(window)
      @activities_complete = false
      activities = []
      cursor = nil
      seen_cursors = Set.new

      MAX_ACTIVITY_PAGES.times do
        trace_wise_fetch(operation: "activities", status: "started", level: "info", cursor: cursor, page_size: ACTIVITY_PAGE_SIZE)
        result = with_rate_limit_retry do
          wise_provider.get_activities(wise_item.profile_id, cursor: cursor, size: ACTIVITY_PAGE_SIZE, since: window.begin, until_time: window.end)
        end
        batch = Array(result&.dig("activities"))
        next_cursor = result&.dig("cursor").presence
        trace_wise_fetch(
          operation: "activities",
          status: "completed",
          level: "info",
          cursor: cursor,
          received_record_count: batch.size,
          next_cursor_present: next_cursor.present?
        )

        # Wise filters by `since`; older rows are dropped defensively in case
        # the filter is ignored.
        activities.concat(batch.select { |activity| (parse_time(activity["createdOn"]) || Time.current) >= window.begin })

        if batch.empty? || next_cursor.nil?
          @activities_complete = true
          break
        end

        if seen_cursors.include?(next_cursor)
          trace_wise_fetch(
            operation: "activities",
            status: "failed",
            level: "warn",
            cursor: cursor,
            next_cursor: next_cursor,
            error: StandardError.new("Wise activities pagination cursor did not advance")
          )
          break
        end

        seen_cursors << next_cursor
        cursor = next_cursor
      end

      activities.uniq { |activity| activity["id"] }
    rescue Provider::Wise::WiseError, StandardError => e
      trace_wise_fetch(operation: "activities", status: "failed", level: "warn", error: e, cursor: cursor)
      activities.uniq { |activity| activity["id"] }
    end

    # --- reconstructed ledger ------------------------------------------------------

    def collect_ledger(activities, window)
      result = WiseItem::LedgerCollector.new(
        wise_item,
        wise_provider: wise_provider,
        window_start: window.begin,
        window_end: window.end
      ).collect(Array(activities))

      complete = @activities_complete && result.complete
      if complete
        previous_from = parse_time(wise_item.checkpoint("activities")["covered_from"])
        attributes = {
          "covered_from" => [ previous_from, window.begin ].compact.min.utc.iso8601,
          "covered_to" => window.end.utc.iso8601,
          "state" => "ok"
        }
        attributes["refreshed_at"] = window.end.utc.iso8601 if @refresh_due || @initial_window
        wise_item.update_checkpoint!("activities", attributes)
      else
        result.errors.each do |error|
          trace_wise_fetch(operation: error[:operation], status: "failed", level: "warn",
                           error: Provider::Wise::WiseError.new("Wise #{error[:operation]} request failed", error[:error_type]))
        end
      end

      { ledger_complete: complete, ledger_legs: result.legs }
    rescue => e
      trace_wise_fetch(operation: "ledger_reconstruction", status: "failed", level: "warn", error: e)
      { ledger_complete: false, ledger_legs: 0 }
    end

    # --- stored payloads ------------------------------------------------------------

    # Stores statement rows for STANDARD balances. Every activity, including
    # jar moves and jar interest, now goes through the reconstructed ledger.
    # Rows earlier versions stored (legacy transfers, jar activities) stay in
    # the payload untouched but are no longer processed (see
    # WiseAccount::Transactions::Processor); the reconstructed legs adopt
    # their entries under their existing ids.
    def store_transactions_per_account(statements: {}, statement_failures: [])
      transactions_imported = 0
      transactions_failed = 0

      wise_item.wise_accounts.find_each do |wise_account|
        if statement_failures.include?(wise_account.id)
          transactions_failed += 1
          next
        end

        account_statements = statements[wise_account.id] || []
        next if account_statements.empty?

        payload = merge_transaction_payloads(Array(wise_account.raw_transactions_payload) + account_statements)
        wise_account.upsert_wise_transactions_snapshot!(payload)
        transactions_imported += account_statements.size
      rescue => e
        transactions_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to store transactions for wise_account #{wise_account.id}: #{e.message}"
      end

      { transactions_imported: transactions_imported, transactions_failed: transactions_failed }
    end

    def merge_transaction_payloads(transactions)
      transactions.each_with_object({}) do |transaction, merged|
        key = if transaction["wise_statement"].present?
          [ "statement", transaction["referenceNumber"].presence || transaction["id"] || transaction.to_json ]
        elsif transaction["type"].present?
          [ "activity", transaction["id"] || transaction.to_json ]
        else
          [ "transfer", transaction["id"] || transaction.to_json ]
        end
        merged[key] = transaction
      end.values
    end

    def trace_wise_fetch(operation:, status:, level:, wise_account: nil, error: nil, **metadata)
      message = "WiseItem::Importer - Wise #{operation} fetch #{status}"
      message = "#{message} for wise_account #{wise_account.id}" if wise_account
      message = "#{message}: #{error.message}" if error

      return Rails.logger.debug(message) unless error

      Rails.logger.public_send(level, message)
      DebugLogEntry.capture(
        category: error ? "provider_sync_error" : "provider_sync",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "wise",
        family: wise_item.family,
        account_provider: wise_account&.account_provider,
        metadata: {
          wise_item_id: wise_item.id,
          operation: operation,
          wise_account_id: wise_account&.id,
          balance_id: wise_account&.balance_id,
          currency: wise_account&.currency,
          sca_private_key_configured: wise_item.sca_private_key.present?,
          error_class: error&.class&.name,
          error_type: error&.respond_to?(:error_type) ? error.error_type : nil
        }.compact.merge(metadata)
      )
    rescue => trace_error
      Rails.logger.warn "WiseItem::Importer - Failed to capture statement trace: #{trace_error.message}"
    end

    def with_rate_limit_retry(max_retries: 3)
      retries = 0
      begin
        yield
      rescue Provider::Wise::WiseError => e
        raise unless e.error_type == :rate_limited && retries < max_retries
        retries += 1
        sleep(2 ** retries)
        retry
      end
    end

    def overlap_days
      Rails.configuration.x.wise.overlap_days
    end

    def refresh_days
      Rails.configuration.x.wise.refresh_days
    end

    def refresh_interval_days
      Rails.configuration.x.wise.refresh_interval_days
    end

    def sync_start_date_value
      (sync_start_date.presence || wise_item.sync_start_date.presence || DEFAULT_HISTORY_DAYS.days.ago).to_date
    end

    def full_history?
      wise_item.import_all_history?
    end

    # Full-history imports start from the balance's creation time when Wise
    # reports one, falling back to a far-past date so every historical row is
    # fetched regardless.
    def full_history_start_date(wise_account)
      raw = wise_account.raw_payload&.dig("creationTime")
      return FULL_HISTORY_START_DATE if raw.blank?

      Time.parse(raw.to_s).to_date
    rescue ArgumentError, TypeError
      FULL_HISTORY_START_DATE
    end

    def parse_transaction_date(transaction)
      raw = transaction["created"] || transaction["createdOn"] || transaction["date"]
      return nil if raw.blank?

      Time.parse(raw.to_s).to_date
    rescue ArgumentError, TypeError
      nil
    end

    def parse_time(raw)
      return nil if raw.blank?

      Time.find_zone("UTC").parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def credentials_error?(error)
      error.is_a?(Provider::Wise::WiseError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
    end

    def mark_requires_update_if_credentials_error(error)
      return unless credentials_error?(error)

      wise_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "WiseItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_created: 0,
        accounts_updated: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end
end
