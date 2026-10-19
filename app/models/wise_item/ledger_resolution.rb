# frozen_string_literal: true

# An operator's resolution of an unresolved Wise leg: the balance it touched
# and, when Wise did not state it, the amount. Stored in
# `details["resolution"]` and applied again after every re-derivation, so a
# decision outlives later syncs. The provider's own values stay visible in
# the raw payload; provenance becomes user_confirmed, never provider data.
class WiseItem::LedgerResolution
  DIRECTIONS = %w[inflow outflow].freeze

  def self.record!(record, balance_id:, amount: nil, direction: nil)
    raise ArgumentError, "direction must be inflow or outflow" if amount.present? && !DIRECTIONS.include?(direction)

    resolution = { "balance_id" => balance_id.to_s, "amount" => amount&.to_s, "direction" => direction, "resolved_at" => Time.current.iso8601 }.compact
    record.details = record.details.merge("resolution" => resolution)
    raise ArgumentError, "unknown balance #{balance_id}" unless apply(record)

    record.status = :ready unless record.imported?
    record.save!
  end

  # @return [Boolean] whether a resolution was applied
  def self.apply(record)
    resolution = record.resolution
    return false if resolution["balance_id"].blank?

    wise_account = record.item.wise_accounts.find_by(balance_id: resolution["balance_id"])
    return false unless wise_account

    record.provider_account = wise_account
    record.currency = wise_account.currency
    if resolution["amount"].present?
      magnitude = resolution["amount"].to_d.abs
      record.amount = resolution["direction"] == "inflow" ? -magnitude : magnitude
    end
    record.provenance = "user_confirmed"
    record.field_provenance = record.field_provenance.merge(
      "balance" => "user_confirmed",
      "amount" => resolution["amount"].present? ? "user_confirmed" : record.field_provenance["amount"]
    ).compact
    record.reason = "resolved_by_operator"
    true
  end
end
