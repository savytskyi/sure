# frozen_string_literal: true

# Operator tools for the reconstructed Wise ledger. `coverage`, `review`,
# `reconcile`, `closed_balances` and `legacy_entries` only read. `dismiss`,
# `resolve`, `accept_duplicate` and `classify` record a decision on one leg,
# which every later sync keeps.
namespace :wise do
  desc "Exact / inferred / unresolved Wise legs per connection and account"
  task coverage: :environment do
    WiseItem.includes(:family, :wise_accounts).find_each do |item|
      puts "#{item.name} (profile #{item.profile_id}, #{item.profile_type})"
      legs = item.ledger_records.where.not(category: "transfer_order")
      legs.group(:provider_account_id, :provenance, :status).count.sort_by { |key, _| key.map(&:to_s) }.each do |(account_id, provenance, status), count|
        account = item.wise_accounts.find { |wise_account| wise_account.id == account_id }
        label = account ? "#{account.currency} #{account.balance_id} (#{account.status})" : "no balance"
        puts format("  %-36s %-18s %-13s %6d", label, provenance, status, count)
      end
      item.sync_checkpoints.fetch("statements", {}).each do |balance_id, checkpoint|
        puts "  statements #{balance_id}: #{checkpoint['state']} #{checkpoint['covered_from']}..#{checkpoint['covered_to']}"
      end
      puts "  activities: #{item.checkpoint('activities').slice('covered_from', 'covered_to').values.join('..')}"
    end
  end

  desc "List Wise legs waiting for review (LIMIT=50)"
  task review: :environment do
    limit = ENV.fetch("LIMIT", "50").to_i
    ProviderLedgerRecord.for_provider("wise").needs_review.order(:occurred_at).limit(limit).each do |record|
      puts [
        record.id, record.occurred_at&.to_date, record.category, record.amount&.to_s("F"), record.currency,
        record.provenance, record.reason, record.name || record.counterparty_name,
        record.details["duplicate_candidate_entry_ids"]&.join(",")
      ].compact.join(" | ")
    end
  end

  desc "Never import one Wise ledger record (RECORD_ID=...)"
  task dismiss: :environment do
    record = ProviderLedgerRecord.for_provider("wise").find(ENV.fetch("RECORD_ID"))
    record.update!(status: :dismissed, reason: "dismissed_by_operator")
    puts "Dismissed #{record.external_key}"
  end

  desc "Resolve an unresolved Wise leg (RECORD_ID=... BALANCE_ID=... [AMOUNT=... DIRECTION=inflow|outflow])"
  task resolve: :environment do
    record = ProviderLedgerRecord.for_provider("wise").find(ENV.fetch("RECORD_ID"))
    WiseItem::LedgerResolution.record!(record, balance_id: ENV.fetch("BALANCE_ID"), amount: ENV["AMOUNT"], direction: ENV["DIRECTION"])
    puts "Resolved #{record.external_key}: #{record.amount&.to_s('F')} #{record.currency} on balance #{ENV['BALANCE_ID']} (imported on the next sync)"
  end

  desc "Decide a possible duplicate (RECORD_ID=... ENTRY_ID=<existing entry> or ENTRY_ID=new)"
  task accept_duplicate: :environment do
    record = ProviderLedgerRecord.for_provider("wise").find(ENV.fetch("RECORD_ID"))
    entry_id = ENV.fetch("ENTRY_ID")
    resolution = entry_id == "new" ? { "force_new" => true } : { "link_entry_id" => entry_id }
    record.update!(status: :ready, details: record.details.merge("resolution" => record.resolution.merge(resolution)))
    puts "#{record.external_key} will #{entry_id == 'new' ? 'be imported as a new entry' : "update entry #{entry_id}"} on the next sync"
  end

  desc "Classify a Wise movement (RECORD_ID=... AS=salary|income|expense|internal_transfer)"
  task classify: :environment do
    record = ProviderLedgerRecord.for_provider("wise").find(ENV.fetch("RECORD_ID"))
    classification = ENV.fetch("AS")
    raise ArgumentError, "AS must be salary, income, expense or internal_transfer" unless %w[salary income expense internal_transfer].include?(classification)

    record.update!(details: record.details.merge("classification" => classification))
    puts "#{record.external_key} classified as #{classification} (applied on the next sync)"
  end

  desc "Wise balances no longer listed by Wise (closed or only referenced), with their linked accounts"
  task closed_balances: :environment do
    WiseAccount.where(status: %w[closed discovered]).includes(:wise_item, account_provider: :account).find_each do |wise_account|
      account = wise_account.current_account
      window = wise_account.discovered? ? "used #{wise_account.first_observed_at&.to_date}..#{wise_account.last_observed_at&.to_date}" : "closed by #{wise_account.closed_at&.to_date}"
      puts [ wise_account.wise_item.name, wise_account.balance_id, wise_account.currency, wise_account.status, window,
             account ? "linked to #{account.name} (#{account.status})" : "not linked",
             "#{wise_account.ledger_records.where.not(status: :excluded).count} legs" ].join(" | ")
    end
  end

  desc "Compare each linked Wise balance with the balance its imported ledger implies"
  task reconcile: :environment do
    WiseAccount.includes(:wise_item, account_provider: :account).find_each do |wise_account|
      account = wise_account.current_account
      next unless account

      ledger_sum = account.entries.where(entryable_type: "Transaction", excluded: false).sum(:amount)
      coverage = wise_account.wise_item.statement_coverage(wise_account.balance_id)
      verified = coverage&.dig("state") == "ok"
      puts "#{account.name} #{wise_account.currency} #{wise_account.balance_id} (#{wise_account.status})"
      puts "  Wise-reported balance:        #{wise_account.current_balance&.to_s('F')}"
      puts "  net imported transactions:    #{(-ledger_sum).to_s('F')} (inflows minus outflows)"
      puts "  historical reconciliation:    #{verified ? 'statements available from ' + coverage['covered_from'].to_s : 'UNKNOWN - no balance statements; history is reconstructed from activities'}"
    end
  end

  desc "Wise entries from the old transfer fallback and conversion routing that no reconstructed leg claimed"
  task legacy_entries: :environment do
    Entry.where(source: "wise").where("external_id LIKE 'wise_transfer_%' OR external_id LIKE 'wise_fee_%' OR external_id LIKE 'wise_interbalance_%_outflow'")
      .includes(:account).order(:date).find_each do |entry|
      puts [ entry.id, entry.date, entry.account.name, entry.external_id, entry.amount.to_s("F"), entry.currency, entry.name ].join(" | ")
    end
  end
end
