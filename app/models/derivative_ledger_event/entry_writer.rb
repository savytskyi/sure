# frozen_string_literal: true

# Writes an account's importable derivative ledger events into its ledger.
# Provider-independent.
#
# A funding payment arrives every eight hours per position and a commission
# with every fill, so one entry per event would bury the account's real
# activity. Events are summed per day, market, category and asset instead:
# one entry says "funding on BTCUSD_PERP cost 0.00000231 BTC on this day".
# Sure's balances are daily, so nothing is lost; each event keeps its own
# provider id and points at the entry that carries it.
#
# The entry is a Trade with a zero amount and the summed quantity of the
# asset, the same shape KrakenAccount::LedgerProcessor gives coin movements:
# a futures wallet holds units of its margin asset, and P&L, funding and fees
# change how many it holds. A cash amount would invent money that never moved
# (and Balance::BaseCalculator would count it), while the quantity lets
# Holding::ReverseCalculator walk the position back through history.
#
# Idempotent: a day with a new event is recomputed from all of its events and
# the entry is updated in place; days without one are not touched. An entry the user edited keeps their edits; one
# the user deleted is never recreated, even when more events for that day
# arrive later.
class DerivativeLedgerEvent::EntryWriter
  ACTIVITY_LABELS = {
    "realized_pnl" => "Other",
    "funding" => "Interest",
    "commission" => "Fee",
    "rebate" => "Fee",
    "settlement" => "Other",
    "liquidation" => "Fee",
    "conversion" => "Exchange",
    "bonus" => "Other"
  }.freeze

  NAMES = {
    "realized_pnl" => "Realized P&L",
    "funding" => "Funding",
    "commission" => "Trading fees",
    "rebate" => "Fee rebates",
    "settlement" => "Delivery settlement",
    "liquidation" => "Liquidation fee",
    "conversion" => "Auto-exchange",
    "bonus" => "Bonus"
  }.freeze

  NETS_TO_ZERO = "nets_to_zero"

  attr_reader :account, :source

  # @param security_for [#call] asset -> Security or nil
  # @param price_for [#call] (asset, date) -> unit price in the account's
  #   currency, or nil when unknown
  # @param market_names [Hash] market -> display name
  def initialize(account:, source:, security_for:, price_for:, market_names: {})
    @account = account
    @source = source
    @security_for = security_for
    @price_for = price_for
    @market_names = market_names
  end

  def self.external_id_for(source, market:, category:, asset:, date:)
    "#{source}_derivatives_#{market}_#{category}_#{asset}_#{date.iso8601}"
  end

  # @return [Hash] counts of :created, :updated, :unchanged, :removed and
  #   :dismissed day entries, and :skipped days whose asset could not be resolved
  def write(events = DerivativeLedgerEvent.where(account: account).importable)
    counts = Hash.new(0)
    dismissed_days = DerivativeLedgerEvent.where(account: account).dismissed.map { |event| group_key(event) }.to_set
    unpriced = unpriced_entry_ids

    events.order(:occurred_at).to_a.group_by { |event| group_key(event) }.each do |key, group|
      # An event arriving for a day the user already deleted joins that
      # decision instead of bringing the day back.
      if dismissed_days.include?(key)
        dismiss!(group)
        counts[:dismissed] += 1
        next
      end

      # Only a new event, a deleted entry or a price still missing can change
      # a day; the rest of the history is left alone instead of being re-read
      # every sync. The price matters despite the zero amount: it is the cost
      # basis of the coins received.
      next unless group.any? { |event| event.ready? || event.deleted_by_user? || unpriced.include?(event.entry_id) }

      counts[write_day(*key, group)] += 1
    end

    counts
  end

  private

    def group_key(event)
      [ event.market, event.category, event.asset, event.occurred_at.in_time_zone.to_date ]
    end

    def write_day(market, category, asset, date, events)
      if events.any?(&:deleted_by_user?)
        dismiss!(events)
        return :dismissed
      end

      external_id = self.class.external_id_for(source, market: market, category: category, asset: asset, date: date)
      entry = account.entries.find_by(source: source, external_id: external_id)
      quantity = events.sum(&:amount)

      if quantity.zero?
        entry.destroy! if entry && !entry.user_modified?
        DerivativeLedgerEvent.where(id: events.map(&:id)).update_all(
          status: "ready", entry_id: nil, imported_at: nil, reason: NETS_TO_ZERO, updated_at: Time.current
        )
        return entry ? :removed : :unchanged
      end

      security = @security_for.call(asset)
      return :skipped unless security

      price = @price_for.call(asset, date)
      attributes = entry_attributes(market, category, asset, date, events, quantity, price)
      outcome = :unchanged

      Entry.transaction do
        if entry.nil?
          entry = account.entries.create!(
            attributes.merge(
              external_id: external_id, source: source,
              entryable: Trade.new(trade_attributes(security, category, quantity, price, attributes[:extra]))
            ).except(:extra)
          )
          outcome = :created
        elsif !entry.user_modified? && changed?(entry, quantity, attributes)
          entry.update!(name: attributes[:name], date: date)
          entry.entryable.update!(trade_attributes(security, category, quantity, price, attributes[:extra]))
          outcome = :updated
        end

        DerivativeLedgerEvent.where(id: events.map(&:id)).update_all(
          status: "imported", entry_id: entry.id, reason: nil, updated_at: Time.current
        )
        DerivativeLedgerEvent.where(id: events.map(&:id), imported_at: nil).update_all(imported_at: Time.current)
      end

      outcome
    end

    def unpriced_entry_ids
      account.entries.where(source: source, entryable_type: "Trade")
             .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
             .where("trades.extra -> ? ->> 'price_missing' = 'true'", source)
             .pluck(:id).to_set
    end

    def dismiss!(events)
      DerivativeLedgerEvent.where(id: events.map(&:id)).update_all(
        status: "dismissed", reason: "entry_deleted_by_user", updated_at: Time.current
      )
    end

    def changed?(entry, quantity, attributes)
      trade = entry.entryable
      trade.qty != quantity || entry.name != attributes[:name] ||
        trade.extra.dig(source, "event_count") != attributes[:extra][source]["event_count"] ||
        (trade.extra.dig(source, "price_missing") && attributes[:extra][source]["price_missing"].nil?)
    end

    def entry_attributes(market, category, asset, date, events, quantity, price)
      symbols = events.filter_map(&:symbol).reject(&:blank?).uniq.sort
      meta = {
        "market" => market,
        "category" => category,
        "asset" => asset,
        "event_count" => events.size,
        "symbols" => symbols,
        "provider_types" => events.map(&:provider_type).uniq.sort
      }
      meta["price_missing"] = true if price.nil?

      {
        date: date,
        name: entry_name(market, category, asset, quantity, symbols),
        amount: 0,
        currency: account.currency,
        extra: { source => meta }
      }
    end

    def trade_attributes(security, category, quantity, price, extra)
      {
        security: security,
        qty: quantity,
        price: price || 0,
        currency: account.currency,
        investment_activity_label: ACTIVITY_LABELS.fetch(category, "Other"),
        extra: extra
      }
    end

    def entry_name(market, category, asset, quantity, symbols)
      formatted = quantity.to_d.to_s("F").sub(/\.?0+\z/, "")
      formatted = "+#{formatted}" if quantity.positive?
      on = symbols.any? ? " on #{symbols.first(3).join(', ')}#{symbols.size > 3 ? ' …' : ''}" : ""
      "#{@market_names.fetch(market, market)} #{NAMES.fetch(category, category.humanize).downcase_first} #{formatted} #{asset}#{on}"
    end
end
