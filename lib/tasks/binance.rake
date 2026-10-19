# frozen_string_literal: true

# Operator tools for Binance futures data. `futures` and `positions` only
# read; `legacy_futures_trades` is a dry run unless CONFIRM=yes.
namespace :binance do
  desc "Futures balances, positions, income coverage and Binance's own wallet valuation per connection"
  task futures: :environment do
    BinanceItem.includes(:family, :binance_accounts).find_each do |item|
      binance_account = item.binance_accounts.find { |ba| ba.account_type == "combined" }
      puts "#{item.name} (family #{item.family_id})"
      next puts("  no combined account yet") unless binance_account

      restrictions = item.raw_payload&.dig("api_restrictions") || {}
      if restrictions["error"]
        puts "  key permissions: unavailable (#{restrictions['error']})"
      elsif restrictions.any?
        flags = restrictions.slice("enableReading", "enableFutures", "enableSpotAndMarginTrading", "enableMargin",
                                   "enableWithdrawals", "enableInternalTransfer", "permitsUniversalTransfer", "ipRestrict")
        puts "  key permissions: #{flags.map { |k, v| "#{k}=#{v}" }.join(' ')}"
        unsafe = flags.slice("enableFutures", "enableSpotAndMarginTrading", "enableMargin", "enableWithdrawals", "enableInternalTransfer", "permitsUniversalTransfer").select { |_, v| v }.keys
        puts "  WARNING: the key can do more than read: #{unsafe.join(', ')}" if unsafe.any?
      end

      (binance_account.raw_payload&.dig("futures_summary") || {}).each do |market, summary|
        state = summary["stale"] ? "STALE (#{summary['error_class']}: #{summary['error']})" : "read #{summary['read_at']}"
        puts "  #{market}: #{state}"
        (summary["assets"] || {}).each do |asset, figures|
          puts format("    %-6s wallet %s  equity %s  available %s  unrealized %s", asset,
                      figures["wallet_balance"], figures["margin_balance"], figures["available_balance"], figures["unrealized_pnl"])
        end
        puts "    open positions #{summary['open_positions']}, notional #{summary['notional'].inspect} (exposure, not in the balance)" unless summary["open_positions"].nil?
        puts "    positions unavailable: #{summary['positions_error']}" if summary["positions_error"]
      end

      (binance_account.extra.dig("binance", "futures_income") || {}).each do |market, checkpoint|
        covered = checkpoint["covered_to_ms"] ? Time.zone.at(checkpoint["covered_to_ms"].to_i / 1000).iso8601 : "nothing"
        started = checkpoint["started_from_ms"] ? Time.zone.at(checkpoint["started_from_ms"].to_i / 1000).iso8601 : "-"
        puts "  #{market} income: #{started}..#{covered} backfill_complete=#{checkpoint['backfill_complete']} #{checkpoint['stopped'] && "stopped=#{checkpoint['stopped']}"} #{checkpoint['error']}"
      end
      item.derivative_ledger_events.group(:market, :category, :asset, :status).count.sort_by { |key, _| key.map(&:to_s) }.each do |(market, category, asset, status), count|
        total = item.derivative_ledger_events.where(market: market, category: category, asset: asset, status: status).sum(:amount)
        puts format("    %-7s %-13s %-6s %-13s %6d  %s", market, category, asset, status, count, total.to_s("F"))
      end

      imported = (binance_account.raw_payload&.dig("assets") || []).group_by { |a| a["source"] }
      overview = item.raw_payload&.dig("wallet_overview")
      if overview.is_a?(Array)
        puts "  Binance wallet valuation (USDT) vs. sources imported:"
        overview.each do |wallet|
          next if wallet["balance"].to_d.zero? && !wallet["activate"]

          puts format("    %-22s %16s", wallet["walletName"], wallet["balance"])
        end
        puts "    imported sources: #{imported.transform_values { |assets| assets.map { |a| "#{a['total']} #{a['symbol']}" } }.inspect}"
      elsif overview
        puts "  Binance wallet valuation unavailable: #{overview['error']}"
      end
    end
  end

  desc "Open (and with ALL=1 closed) futures position episodes"
  task positions: :environment do
    scope = DerivativePosition.for_provider("binance").order(:market, :symbol, :first_observed_at)
    scope = scope.open unless ENV["ALL"] == "1"
    scope.find_each do |position|
      puts [
        position.status, position.market, position.symbol, position.position_side,
        "#{position.quantity.to_s('F')} #{position.quantity_unit}",
        position.contract_size && "x #{position.contract_size.to_s('F')} #{position.contract_size_currency}",
        "entry #{position.entry_price&.to_s('F')}", "mark #{position.mark_price&.to_s('F')}",
        "notional #{position.notional&.to_s('F')} #{position.notional_currency}",
        "uPnL #{position.unrealized_pnl&.to_s('F')} #{position.unrealized_pnl_currency}",
        "#{position.first_observed_at.to_date}..#{position.closed_at&.to_date || 'open'}"
      ].compact.join(" | ")
    end
  end

  # Earlier versions recorded every USDⓈ-M fill as a spot buy or sell of the
  # base coin, with the fill's notional as cash. Those rows move historical
  # holdings and cash by amounts that never left the account, so they are
  # removed rather than excluded (excluded trades still count in holdings).
  # Rows the user edited are kept. OUT=<path> writes every row first.
  desc "Report (and with CONFIRM=yes delete) futures fills recorded as spot trades (FAMILY_ID required to delete)"
  task legacy_futures_trades: :environment do
    scope = Entry.where(source: "binance", entryable_type: "Trade")
                 .where("entries.external_id LIKE 'binance\\_futures\\_%'")
    scope = scope.joins(:account).where(accounts: { family_id: ENV["FAMILY_ID"] }) if ENV["FAMILY_ID"].present?
    entries = scope.preload(:account, entryable: :security).order(:date).to_a
    removable, kept = entries.partition { |entry| !entry.user_modified? }

    entries.group_by(&:account).each do |account, rows|
      puts "#{account.name} (#{account.id}): #{rows.size} futures fills recorded as trades, #{rows.count(&:user_modified?)} edited by the user"
    end

    if ENV["OUT"].present?
      require "csv"
      CSV.open(ENV["OUT"], "w") do |csv|
        csv << %w[entry_id account_id date external_id name amount currency qty price security user_modified]
        entries.each do |entry|
          trade = entry.entryable
          csv << [ entry.id, entry.account_id, entry.date, entry.external_id, entry.name, entry.amount, entry.currency,
                   trade.qty, trade.price, trade.security&.ticker, entry.user_modified? ]
        end
      end
      puts "Wrote #{entries.size} rows to #{ENV['OUT']}"
    end

    abort "Dry run. Re-run with FAMILY_ID=<id> CONFIRM=yes (and OUT=<csv>) to delete #{removable.size}; #{kept.size} edited rows stay." unless ENV["CONFIRM"] == "yes" && ENV["FAMILY_ID"].present?
    abort "Refusing to delete without OUT=<csv>." if ENV["OUT"].blank?

    Entry.transaction { removable.each(&:destroy!) }
    removable.map(&:account).uniq.each(&:sync_later)
    puts "Deleted #{removable.size} entries; #{kept.size} edited rows kept."
  end
end
