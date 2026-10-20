require "test_helper"

class WiseItem::ImporterTest < ActiveSupport::TestCase
  class FakeWiseProvider
    attr_reader :calls, :statement_requests

    attr_reader :activity_requests, :transfer_requests

    def initialize(balances: nil, savings_balances: nil, borderless_accounts: nil,
                   transfers: nil, activities: nil, statements: nil, raise_on: {},
                   statement_fail_balance_ids: [], quotes: {}, recipients: {},
                   statement_error_type: :fetch_failed)
      @balances = balances || [ standard_balance ]
      @savings_balances = savings_balances || []
      @borderless_accounts = borderless_accounts || [ borderless_account ]
      @transfers = transfers || []
      @activities = activities || []
      @statements = statements || []
      @raise_on = raise_on
      @statement_fail_balance_ids = statement_fail_balance_ids
      @statement_error_type = statement_error_type
      @quotes = quotes
      @recipients = recipients
      @calls = []
      @statement_requests = []
      @activity_requests = []
      @transfer_requests = []
    end

    def get_balances(profile_id)
      @calls << :get_balances
      raise_if(:get_balances)
      @balances
    end

    def get_savings_balances(profile_id)
      @calls << :get_savings_balances
      raise_if(:get_savings_balances)
      @savings_balances
    end

    def get_borderless_accounts(profile_id)
      @calls << :get_borderless_accounts
      raise_if(:get_borderless_accounts)
      @borderless_accounts
    end

    def get_transfers(profile_id, limit: 100, offset: 0, created_from: nil, created_to: nil)
      @calls << :get_transfers
      @transfer_requests << { offset: offset, created_from: created_from, created_to: created_to }
      raise_if(:get_transfers)
      offset.zero? ? @transfers : []
    end

    def get_quote(profile_id, quote_id)
      @calls << :get_quote
      @quotes.fetch(quote_id) { raise Provider::Wise::WiseError.new("not found", :not_found) }
    end

    def get_recipient_account(account_id)
      @calls << :get_recipient_account
      @recipients.fetch(account_id.to_s) { raise Provider::Wise::WiseError.new("not found", :not_found) }
    end

    def get_balance_statements(profile_id, balance_id, currency:, start_date:, end_date:)
      @calls << :get_balance_statements
      @statement_requests << { profile_id: profile_id, balance_id: balance_id, currency: currency,
                               start_date: start_date, end_date: end_date }
      raise_if(:get_balance_statements)
      raise Provider::Wise::WiseError.new("forbidden", @statement_error_type) if @statement_fail_balance_ids.include?(balance_id)
      @statements
    end

    def get_activities(profile_id, cursor: nil, size: 100, since: nil, until_time: nil)
      @calls << :get_activities
      @activity_requests << { cursor: cursor, since: since, until_time: until_time }
      raise_if(:get_activities)
      { "activities" => @activities, "cursor" => nil }
    end

    private

      def raise_if(method)
        error = @raise_on[method]
        raise Provider::Wise::WiseError.new(error, :fetch_failed) if error
      end

      def standard_balance
        {
          "id" => "10000001",
          "amount" => { "value" => 1964.88, "currency" => "EUR" },
          "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
          "type" => "STANDARD"
        }
      end

      def borderless_account
        {
          "id" => 88888001,
          "recipientId" => 99999001,
          "balances" => [ { "id" => 10000001 } ]
        }
      end
  end

  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "11111111",
      profile_type: :business
    )
  end

  # STANDARD balance import

  test "imports STANDARD balances and creates WiseAccount records" do
    provider = FakeWiseProvider.new

    result = nil
    assert_no_difference -> { DebugLogEntry.where(provider_key: "wise").count } do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal 0, result[:accounts_updated]

    account = @wise_item.wise_accounts.first
    assert_equal "10000001", account.balance_id
    assert_equal "EUR", account.currency
    assert_not account.jar?
  end

  test "stores borderless_account_id and recipient_id in STANDARD account raw_payload" do
    provider = FakeWiseProvider.new

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(balance_id: "10000001")
    assert_equal 88888001, account.raw_payload["borderless_account_id"]
    assert_equal 99999001, account.raw_payload["recipient_id"]
  end

  # SAVINGS (JAR) balance import

  test "imports SAVINGS balances and marks them as JAR" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 11022.16, "currency" => "EUR" },
      "totalWorth" => { "value" => 11022.16, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    provider = FakeWiseProvider.new(savings_balances: [ savings ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    assert_not_nil jar
    assert jar.jar?
    assert_equal BigDecimal("11022.16"), jar.current_balance
    assert_equal "Jar", jar.name
  end

  test "continues if savings balances fetch fails" do
    provider = FakeWiseProvider.new(raise_on: { get_savings_balances: "forbidden" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:success]
    assert_equal 1, @wise_item.wise_accounts.count
  end

  # Statements unavailable: activity reconstruction instead of currency-routed transfers

  test "does not route transfer orders to balances by currency" do
    transfers = [
      build_transfer(id: 1, source_currency: "EUR", target_currency: "EUR", target_account: 9999),
      build_transfer(id: 2, source_currency: "USD", target_currency: "USD", target_account: 9999)
    ]
    provider = FakeWiseProvider.new(transfers: transfers, raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_empty Array(eur_account.raw_transactions_payload).select { |row| row["sourceCurrency"].present? }
    assert_equal %w[1 2], @wise_item.ledger_records.where(category: "transfer_order").pluck(:provider_transfer_id).sort
    assert @wise_item.ledger_records.where(category: "transfer_order").all?(&:excluded?)
  end

  test "imports standard account balance statements and honors configured history start" do
    @wise_item.update!(sync_start_date: Date.new(2024, 1, 1))
    statements = [
      {
        "type" => "CREDIT",
        "date" => "2024-01-02T10:00:00Z",
        "amount" => { "value" => "25.00", "currency" => "EUR" },
        "details" => { "description" => "Salary" },
        "referenceNumber" => "statement-1"
      }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal statements.first.merge("wise_statement" => true), account.raw_transactions_payload.first
    assert_equal Date.new(2024, 1, 1), provider.statement_requests.first[:start_date]
    assert_equal Date.current, provider.statement_requests.first[:end_date]
  end

  test "fetches full statement history when import_all_history is enabled" do
    @wise_item.update!(import_all_history: true)
    provider = FakeWiseProvider.new(statements: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal WiseItem::Importer::FULL_HISTORY_START_DATE, provider.statement_requests.first[:start_date]
    assert_equal Date.current, provider.statement_requests.first[:end_date]
  end

  test "starts full history from balance creation time when available" do
    @wise_item.update!(import_all_history: true)
    balance = {
      "id" => "10000001",
      "amount" => { "value" => 100.0, "currency" => "EUR" },
      "type" => "STANDARD",
      "creationTime" => "2015-04-12T10:00:00Z"
    }
    provider = FakeWiseProvider.new(balances: [ balance ], statements: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal Date.new(2015, 4, 12), provider.statement_requests.first[:start_date]
  end

  test "keeps incremental sync window after statements already exist" do
    @wise_item.update!(import_all_history: true)
    statements = [
      {
        "type" => "CREDIT",
        "date" => "2024-01-02T10:00:00Z",
        "amount" => { "value" => "25.00", "currency" => "EUR" },
        "details" => { "description" => "Salary" },
        "referenceNumber" => "statement-1"
      }
    ]
    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(statements: statements)).import

    sync = @wise_item.syncs.create!(status: :completed, completed_at: Time.current)

    second_provider = FakeWiseProvider.new(statements: [])
    WiseItem::Importer.new(@wise_item, wise_provider: second_provider).import

    assert_equal (sync.completed_at - 14.days).to_date, second_provider.statement_requests.first[:start_date]
    assert_equal Date.current, second_provider.statement_requests.first[:end_date]
  end

  test "records statements as unavailable once when Wise refuses them" do
    provider = FakeWiseProvider.new(statement_fail_balance_ids: [ "10000001" ], statement_error_type: :access_forbidden)

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count }, 1 do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert result[:success]
    assert_equal "unavailable", @wise_item.reload.statement_coverage("10000001")["state"]

    entry = DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").recent.first
    assert_equal "WiseItem::Importer", entry.source
    assert_equal @wise_item.id, entry.metadata["wise_item_id"]
    assert_equal false, entry.metadata["sca_private_key_configured"]
    assert_equal "access_forbidden", entry.metadata["error_type"]

    second = FakeWiseProvider.new(statement_fail_balance_ids: [ "10000001" ], statement_error_type: :access_forbidden)
    assert_no_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count } do
      WiseItem::Importer.new(@wise_item, wise_provider: second).import
    end
    assert_empty second.statement_requests, "an unavailable statement is retried weekly, not daily"
  end

  test "surfaces partial statement fetch failures without the transfer fallback" do
    balances = [
      {
        "id" => "10000001",
        "amount" => { "value" => 1964.88, "currency" => "EUR" },
        "type" => "STANDARD"
      },
      {
        "id" => "10000002",
        "amount" => { "value" => 500.0, "currency" => "USD" },
        "type" => "STANDARD"
      }
    ]
    provider = FakeWiseProvider.new(balances: balances, statement_fail_balance_ids: [ "10000002" ])

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_equal 1, result[:transactions_failed]
    assert_equal "ok", @wise_item.reload.statement_coverage("10000001")["state"]
  end

  test "backfills incoming statement rows into the window already covered by legacy transfers" do
    @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [
        {
          "id" => 1,
          "sourceCurrency" => "EUR",
          "targetCurrency" => "EUR",
          "sourceValue" => 100.0,
          "targetValue" => 100.0,
          "status" => "outgoing_payment_sent",
          "created" => "2024-01-10"
        }
      ]
    )
    statements = [
      { "date" => "2024-01-15T10:00:00Z", "amount" => { "value" => "-50.00", "currency" => "EUR" }, "referenceNumber" => "st-outgoing-in-window" },
      { "date" => "2024-01-20T10:00:00Z", "amount" => { "value" => "6780.00", "currency" => "EUR" }, "referenceNumber" => "st-incoming-in-window" },
      { "date" => "2024-01-05T10:00:00Z", "amount" => { "value" => "20.00", "currency" => "EUR" }, "referenceNumber" => "st-before-window" }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    refs = account.raw_transactions_payload.filter_map { |t| t["referenceNumber"] }

    assert_includes refs, "st-incoming-in-window"
    assert_includes refs, "st-before-window"
    refute_includes refs, "st-outgoing-in-window"
  end

  test "keeps an incoming statement row that coincidentally shares its date and amount with a legacy transfer" do
    # A same-day, same-amount external payment must never be dropped just
    # because it looks like it could be the credit leg of a prior internal
    # conversion -- silently losing a real transaction is worse than an
    # occasional visible duplicate (see legacy_overlap_outgoing_row?).
    @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
      raw_transactions_payload: [
        {
          "id" => 10,
          "targetAccount" => 99999001,
          "sourceCurrency" => "USD",
          "targetCurrency" => "EUR",
          "sourceValue" => 500.0,
          "targetValue" => 450.0,
          "status" => "incoming_payment_received",
          "created" => "2024-02-01"
        }
      ]
    )
    statements = [
      { "date" => "2024-02-01T09:00:00Z", "amount" => { "value" => "450.00", "currency" => "EUR" }, "referenceNumber" => "st-same-date-and-amount" }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    refs = account.raw_transactions_payload.filter_map { |t| t["referenceNumber"] }

    assert_includes refs, "st-same-date-and-amount"
  end

  # Activity routing

  test "jar moves and jar interest are reconstructed, not routed by title" do
    savings = {
      "id" => "10000002", "type" => "SAVINGS", "name" => "Jar",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" }
    }
    provider = FakeWiseProvider.new(savings_balances: [ savings ], activities: [ build_interbalance("To <strong>Jar</strong>", resource_id: "5001") ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_empty Array(@wise_item.wise_accounts.find_by(balance_id: "10000002").raw_transactions_payload)
    legs = @wise_item.ledger_records.where(category: "jar_move").index_by { |record| record.provider_account.balance_id }
    assert_equal BigDecimal("1000"), legs["10000001"].amount, "out of the main balance"
    assert_equal BigDecimal("-1000"), legs["10000002"].amount, "into the jar"
  end

  test "stops activity pagination when Wise repeats a cursor" do
    activity = build_interbalance("To <strong>Jar</strong>", resource_id: "5001")
    repeated_cursor = "repeated-cursor"
    provider = FakeWiseProvider.new
    provider.define_singleton_method(:get_activities) do |_profile_id, cursor: nil, size: 100, since: nil, until_time: nil|
      calls << :get_activities
      { "activities" => Array.new(size, activity), "cursor" => repeated_cursor }
    end

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal 2, provider.calls.count(:get_activities)
    assert_nil @wise_item.reload.checkpoint("activities")["covered_to"], "an incomplete window must not advance the checkpoint"
  end

  # Activity reconstruction (statements unavailable)

  test "reconstructs card payments, incoming payments and conversions without duplicating on re-sync" do
    eur, usd = link_standard_balances
    activities = [
      card_activity("2001", "<strong>LIDL 1234 MARIBOR</strong>", "23.45 EUR"),
      card_activity("2999", "<strong>Hotel</strong>", "80 EUR", status: "IN_PROGRESS"),
      { "id" => "in-1", "type" => "TRANSFER", "status" => "COMPLETED", "resource" => { "type" => "TRANSFER", "id" => "9901" },
        "title" => "<strong>Example Client</strong>", "primaryAmount" => "<positive>+ 1,200 EUR</positive>", "createdOn" => 3.days.ago.iso8601 },
      { "id" => "conv-1", "type" => "INTERBALANCE", "status" => "COMPLETED", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "3001" },
        "title" => "<strong>USD</strong>", "primaryAmount" => "108.03 USD", "secondaryAmount" => "100 EUR", "createdOn" => 2.days.ago.iso8601 }
    ]

    2.times do
      provider = FakeWiseProvider.new(balances: two_balances, activities: activities, statement_fail_balance_ids: %w[10000001 10000002], statement_error_type: :access_forbidden)
      WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      @wise_item.process_accounts
      @wise_item.process_ledger_records
    end

    eur_entries = eur.reload.entries.where(source: "wise", entryable_type: "Transaction")
    usd_entries = usd.reload.entries.where(source: "wise", entryable_type: "Transaction")
    assert_equal 3, eur_entries.count, "card payment, incoming payment and conversion debit; the pending payment is not imported"
    assert_equal 1, usd_entries.count

    card = eur_entries.find_by(external_id: "wise_activity_card-2001")
    assert_equal "LIDL 1234 MARIBOR", card.name
    assert_equal "Lidl", card.transaction.merchant.name
    assert_equal "inferred", card.transaction.extra.dig("wise", "provenance")

    income = eur_entries.find_by(external_id: "wise_activity_in-1")
    assert_equal BigDecimal("-1200"), income.amount
    assert_equal "standard", income.transaction.kind

    conversion = Transfer.find_by(outflow_transaction: eur_entries.find_by(external_id: "wise_activity_conv-1_source").transaction)
    assert conversion&.confirmed?
    assert_equal usd_entries.first.transaction, conversion.inflow_transaction

    pending = @wise_item.ledger_records.find_by(external_key: "activity:card-2999")
    assert pending.excluded?
    assert_equal "pending", pending.reason
  end

  test "advances the activity checkpoint and re-reads only the overlap" do
    first = FakeWiseProvider.new
    WiseItem::Importer.new(@wise_item, wise_provider: first).import

    covered_to = Time.zone.parse(@wise_item.reload.checkpoint("activities")["covered_to"])
    assert_in_delta WiseItem::Importer::DEFAULT_HISTORY_DAYS.days.ago.to_i, first.activity_requests.first[:since].to_i, 60

    second = FakeWiseProvider.new
    WiseItem::Importer.new(@wise_item, wise_provider: second).import

    assert_in_delta (covered_to - 14.days).to_i, second.activity_requests.first[:since].to_i, 2
  end

  test "a failed transfer fetch does not advance the checkpoint" do
    provider = FakeWiseProvider.new(raise_on: { get_transfers: "server error" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_nil @wise_item.reload.checkpoint("activities")["covered_to"]
  end

  test "marks balances Wise no longer lists as closed and keeps their history" do
    closed = @wise_item.wise_accounts.create!(balance_id: "10000009", currency: "GBP", name: "Wise GBP",
                                              raw_payload: { "type" => "STANDARD" }, raw_transactions_payload: [ { "id" => 1 } ])

    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new).import

    assert closed.reload.closed?
    assert closed.closed_at.present?
    assert_equal [ { "id" => 1 } ], closed.raw_transactions_payload
  end

  test "adds a balance that funded a transfer but is no longer listed" do
    transfer = build_transfer(id: 7101).merge("quoteUuid" => "q-7101")
    quote = { "payInId" => 10000077, "payInMethod" => "BALANCE", "profile" => 11111111 }
    provider = FakeWiseProvider.new(transfers: [ transfer ], quotes: { "q-7101" => quote })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    discovered = @wise_item.wise_accounts.find_by(balance_id: "10000077")
    assert discovered.discovered?
    assert_equal "EUR", discovered.currency
    assert_equal discovered.first_observed_at, discovered.last_observed_at
    assert_equal 1, @wise_item.unlinked_accounts_count, "a no-longer-listed balance never blocks account setup"
  end

  test "a verified statement line is the only entry for a card payment" do
    eur, = link_standard_balances
    statement = { "date" => 2.days.ago.iso8601, "amount" => { "value" => "-23.45", "currency" => "EUR" },
                  "referenceNumber" => "CARD-2001", "details" => { "description" => "Card transaction at Lidl" } }
    provider = FakeWiseProvider.new(balances: two_balances, statements: [ statement ],
                                    statement_fail_balance_ids: [ "10000002" ], statement_error_type: :access_forbidden,
                                    activities: [ card_activity("2001", "<strong>Lidl</strong>", "23.45 EUR") ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    @wise_item.process_accounts
    @wise_item.process_ledger_records

    assert @wise_item.ledger_records.find_by(external_key: "activity:card-2001").superseded?
    assert_equal [ "wise_statement_CARD-2001" ], eur.reload.entries.where(source: "wise").where.not(entryable_type: "Valuation").pluck(:external_id)
  end

  test "records the Wise balance as the current balance anchor, not as a transaction" do
    eur, = link_standard_balances

    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(balances: two_balances)).import
    @wise_item.process_accounts

    anchor = eur.reload.valuations.current_anchor.first
    assert_equal BigDecimal("1964.88"), anchor.entry.amount
    assert_equal 0, eur.entries.where(entryable_type: "Transaction").count
  end

  # Lifecycle

  test "a pending card payment is imported once it completes" do
    eur, = link_standard_balances
    sync_with(activities: [ card_activity("2001", "<strong>Lidl</strong>", "23.45 EUR", status: "IN_PROGRESS") ])
    assert_equal 0, eur.entries.where(source: "wise").count

    sync_with(activities: [ card_activity("2001", "<strong>Lidl</strong>", "23.45 EUR") ])

    assert_equal [ BigDecimal("23.45") ], eur.entries.where(source: "wise").pluck(:amount)
  end

  test "a transfer cancelled months later is found by the refresh window and stops counting" do
    eur, = link_standard_balances
    sent = { "id" => "tr-7101", "type" => "TRANSFER", "status" => "COMPLETED", "resource" => { "type" => "TRANSFER", "id" => "7101" },
             "title" => "<strong>Shop</strong>", "primaryAmount" => "100 EUR", "createdOn" => 60.days.ago.iso8601 }
    transfer = build_transfer(id: 7101).merge("created" => 60.days.ago.strftime("%Y-%m-%d %H:%M:%S"), "quoteUuid" => "q-1")
    quotes = { "q-1" => { "payInId" => 10000001, "payInMethod" => "BALANCE", "payOut" => "BANK_TRANSFER",
                          "paymentOptions" => [ { "payIn" => "BALANCE", "payOut" => "BANK_TRANSFER", "fee" => { "total" => 0 } } ] } }
    sync_with(activities: [ sent ], transfers: [ transfer ], quotes: quotes)
    entry = eur.entries.find_by(source: "wise", amount: 100)
    assert entry

    @wise_item.update_checkpoint!("activities", "refreshed_at" => 30.days.ago.iso8601)
    provider = sync_with(activities: [ sent.merge("status" => "CANCELLED", "description" => "Cancelled") ], transfers: [ transfer ], quotes: quotes)

    assert_operator provider.activity_requests.first[:since], :<, 100.days.ago
    assert entry.reload.excluded?
    assert @wise_item.ledger_records.find_by(external_key: "activity:tr-7101").withdrawn?
  end

  test "a rate-limited backfill keeps its checkpoint and continues from cached details" do
    transfers = (1..3).map { |i| build_transfer(id: 7200 + i).merge("quoteUuid" => "q-#{i}", "targetAccount" => nil) }
    quotes = (1..3).to_h { |i| [ "q-#{i}", { "payInId" => 10000001, "payInMethod" => "BALANCE" } ] }
    limited = FakeWiseProvider.new(transfers: transfers, quotes: quotes)
    served = 0
    limited.define_singleton_method(:get_quote) do |_profile, quote_id|
      calls << :get_quote
      served += 1
      raise Provider::Wise::WiseError.new("slow down", :rate_limited) if served > 1

      quotes.fetch(quote_id)
    end
    importer = WiseItem::Importer.new(@wise_item, wise_provider: limited)
    WiseItem::LedgerCollector.any_instance.stubs(:sleep)

    result = importer.import

    assert_not result[:success]
    assert_nil @wise_item.reload.checkpoint("activities")["covered_to"]
    assert_equal 1, @wise_item.ledger_records.where(category: "transfer_order").count { |record| record.raw_payload["quote"] }

    resumed = FakeWiseProvider.new(transfers: transfers, quotes: quotes)
    assert WiseItem::Importer.new(@wise_item, wise_provider: resumed).import[:success]
    assert_equal 2, resumed.calls.count(:get_quote), "only the quotes still missing are requested"
  end

  test "a batch imported as one debit is replaced by its members once they come to light" do
    eur, = link_standard_balances
    at = 5.days.ago.utc.change(usec: 0)
    batch = { "id" => "batch-9", "type" => "BATCH_TRANSFER", "status" => "COMPLETED", "resource" => { "type" => "BATCH_TRANSFER", "id" => "b-9" },
              "title" => "<strong>salaries</strong>", "primaryAmount" => "300 EUR", "secondaryAmount" => "301 EUR", "createdOn" => at.iso8601 }
    sync_with(activities: [ batch ])
    batch_entry = eur.entries.find_by(external_id: "wise_activity_batch-9")
    assert_equal BigDecimal("300"), batch_entry.amount
    batch_fee = @wise_item.ledger_records.find_by(external_key: "activity:batch-9").fee_entry

    legacy = eur.entries.create!(name: "Wise", date: at.to_date, amount: 100, currency: "EUR", external_id: "wise_transfer_7401",
                                 source: "wise", excluded: true, entryable: Transaction.new)
    transfers = [ [ 7401, 100 ], [ 7402, 200 ] ].map do |id, value|
      build_transfer(id: id).merge("sourceValue" => value, "targetValue" => value, "quoteUuid" => "q-#{id}",
                                   "reference" => "Salary #{id}", "created" => at.strftime("%Y-%m-%d %H:%M:%S"))
    end
    quotes = [ 7401, 7402 ].to_h do |id|
      [ "q-#{id}", { "payInId" => 10000001, "payInMethod" => "BALANCE", "payOut" => "BANK_TRANSFER",
                    "paymentOptions" => [ { "payIn" => "BALANCE", "payOut" => "BANK_TRANSFER", "fee" => { "total" => 0.5 } } ] } ]
    end
    2.times { sync_with(activities: [ batch ], transfers: transfers, quotes: quotes) }

    assert batch_entry.reload.excluded?
    assert batch_fee.reload.excluded?
    assert @wise_item.ledger_records.find_by(external_key: "activity:batch-9").withdrawn?
    members = eur.entries.where(source: "wise", excluded: false, entryable_type: "Transaction")
    assert_equal [ BigDecimal("0.5"), BigDecimal("0.5"), BigDecimal("100"), BigDecimal("200") ], members.map(&:amount).sort
    assert_equal BigDecimal("301"), members.sum(:amount)
    assert legacy.reload.excluded?, "a legacy member entry excluded as a double count is not revived"
    assert_equal "unpacked", @wise_item.ledger_records.find_by(external_key: "transfer:7401").relationship["status"]
  end

  test "an operator resolution survives the next sync" do
    link_standard_balances
    split = card_activity("3006", "<strong>Hotel</strong>", "300 CHF").merge("secondaryAmount" => "EUR, USD")
    sync_with(activities: [ split ])
    record = @wise_item.ledger_records.find_by(external_key: "activity:card-3006")
    assert record.needs_review?

    WiseItem::LedgerResolution.record!(record, balance_id: "10000001", amount: "280.50", direction: "outflow")
    sync_with(activities: [ split ])

    record.reload
    assert_equal [ "user_confirmed", BigDecimal("280.50"), "imported" ], [ record.provenance, record.amount, record.status ]
  end

  test "two profiles syncing twice create each entry once and keep salary as income" do
    personal = WiseItem.create!(family: @family, name: "Personal", token: "t2", profile_id: "22222222", profile_type: :personal)
    business_eur, = link_standard_balances
    personal_eur = @family.accounts.create!(name: "Personal EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    AccountProvider.create!(account: personal_eur, provider: personal.wise_accounts.create!(balance_id: "20000001", currency: "EUR", name: "Wise EUR", raw_payload: { "type" => "STANDARD" }))
    transfer = build_transfer(id: 7301).merge("quoteUuid" => "q-s", "reference" => "Salary")
    quotes = { "q-s" => { "payInId" => 10000001, "payInMethod" => "BALANCE", "payOut" => "BALANCE",
                          "paymentOptions" => [ { "payIn" => "BALANCE", "payOut" => "BALANCE", "fee" => { "total" => 0 } } ] } }
    debit = { "id" => "b-1", "type" => "TRANSFER", "status" => "COMPLETED", "resource" => { "type" => "TRANSFER", "id" => "7301" },
              "title" => "<strong>Me</strong>", "primaryAmount" => "100 EUR", "createdOn" => 7.days.ago.iso8601 }
    credit = debit.merge("id" => "p-1", "title" => "<strong>My Company</strong>", "primaryAmount" => "<positive>+ 100 EUR</positive>")

    2.times do
      sync_with(activities: [ debit ], transfers: [ transfer ], quotes: quotes)
      personal_provider = FakeWiseProvider.new(balances: [ { "id" => "20000001", "amount" => { "value" => 100, "currency" => "EUR" }, "type" => "STANDARD" } ],
                                               activities: [ credit ], statement_fail_balance_ids: [ "20000001" ], statement_error_type: :access_forbidden)
      WiseItem::Importer.new(personal, wise_provider: personal_provider).import
      personal.process_accounts
      personal.process_ledger_records
    end

    salary = personal_eur.entries.where(source: "wise", entryable_type: "Transaction").sole
    assert_equal BigDecimal("-100"), salary.amount
    assert_equal "standard", salary.transaction.kind
    assert_equal "business_to_personal", salary.transaction.extra.dig("wise", "relationship", "type")
    assert_equal 1, business_eur.entries.where(source: "wise", entryable_type: "Transaction").count
  end

  # Returns failed result when balances fetch fails

  test "returns failed result when STANDARD balances fetch fails" do
    provider = FakeWiseProvider.new(raise_on: { get_balances: "server error" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_equal "Failed to fetch balances", result[:error]
  end

  private

    def build_transfer(id:, source_currency: "EUR", target_currency: "EUR", target_account: 9999)
      {
        "id" => id,
        "targetAccount" => target_account,
        "sourceCurrency" => source_currency,
        "targetCurrency" => target_currency,
        "sourceValue" => 100.0,
        "targetValue" => 100.0,
        "status" => "outgoing_payment_sent",
        "created" => 7.days.ago.strftime("%Y-%m-%d %H:%M:%S")
      }
    end

    def sync_with(activities: [], transfers: [], quotes: {})
      provider = FakeWiseProvider.new(balances: two_balances, activities: activities, transfers: transfers, quotes: quotes,
                                      statement_fail_balance_ids: %w[10000001 10000002], statement_error_type: :access_forbidden)
      WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      @wise_item.process_accounts
      @wise_item.process_ledger_records
      provider
    end

    def two_balances
      [
        { "id" => "10000001", "amount" => { "value" => 1964.88, "currency" => "EUR" }, "type" => "STANDARD" },
        { "id" => "10000002", "amount" => { "value" => 500.0, "currency" => "USD" }, "type" => "STANDARD" }
      ]
    end

    def link_standard_balances
      two_balances.map do |balance|
        currency = balance.dig("amount", "currency")
        wise_account = @wise_item.wise_accounts.create!(balance_id: balance["id"], currency: currency, name: "Wise #{currency}", raw_payload: { "type" => "STANDARD" })
        account = @family.accounts.create!(name: "Wise #{currency}", balance: 0, currency: currency, accountable: Depository.new)
        AccountProvider.create!(account: account, provider: wise_account)
        account
      end
    end

    def card_activity(id, title, primary, status: "COMPLETED")
      { "id" => "card-#{id}", "type" => "CARD_PAYMENT", "resource" => { "type" => "CARD_TRANSACTION", "id" => id },
        "title" => title, "description" => "", "primaryAmount" => primary, "secondaryAmount" => "",
        "status" => status, "createdOn" => 4.days.ago.iso8601 }
    end

    def build_interbalance(title, resource_id:)
      {
        "id" => "interbalance_#{resource_id}",
        "type" => "INTERBALANCE",
        "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title,
        "primaryAmount" => "1,000 EUR",
        "status" => "COMPLETED",
        "createdOn" => 7.days.ago.iso8601
      }
    end

    def build_cashback(resource_id)
      {
        "id" => "cashback_#{resource_id}",
        "type" => "BALANCE_CASHBACK",
        "resource" => { "type" => "BALANCE_CASHBACK", "id" => resource_id },
        "title" => "<strong>Cashback</strong>",
        "primaryAmount" => "<positive>+ 1.12 EUR</positive>",
        "status" => "COMPLETED",
        "createdOn" => 3.days.ago.iso8601
      }
    end
end
