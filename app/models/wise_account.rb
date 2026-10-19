# frozen_string_literal: true

class WiseAccount < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  # active:     returned by the balances API on the last sync
  # closed:     listed before, no longer returned; its history stays
  # discovered: never listed, but referenced by Wise (a quote's payInId), so
  #             it existed at least between first/last_observed_at
  enum :status, { active: "active", closed: "closed", discovered: "discovered" }, default: :active

  belongs_to :wise_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider
  has_many :ledger_records, class_name: "ProviderLedgerRecord", as: :provider_account, dependent: :nullify

  validates :balance_id, :currency, presence: true
  validates :balance_id, uniqueness: { scope: :wise_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }

  def current_account
    account
  end

  def jar?
    raw_payload&.dig("type") == "SAVINGS"
  end

  # Whether this balance could have been the one Wise used at `time`.
  # Listed balances count from their creation until they were seen closed;
  # discovered balances only within the window Wise referenced them.
  def existed_at?(time)
    if discovered?
      first_observed_at.present? && last_observed_at.present? && time.between?(first_observed_at, last_observed_at)
    else
      (opened_at.nil? || opened_at <= time) && (closed_at.nil? || closed_at >= time)
    end
  end

  def account_subtype
    jar? ? "savings" : Depository::DEFAULT_SUBTYPE
  end

  def upsert_wise_snapshot!(balance_data, borderless_account_id: nil, recipient_id: nil)
    data = balance_data.with_indifferent_access
    payload = balance_data.is_a?(Hash) ? balance_data.dup : balance_data
    payload = payload.merge("borderless_account_id" => borderless_account_id) if borderless_account_id
    payload = payload.merge("recipient_id" => recipient_id) if recipient_id

    currency_code = data.dig(:amount, :currency).presence || data[:currency].presence || currency
    savings = data[:type] == "SAVINGS"
    api_name = data[:name].presence
    default_name = savings ? "Wise JAR #{currency_code}" : "Wise #{currency_code}"

    # cashAmount is everything held, including card holds that are reserved
    # but not yet settled. Pending holds never become transactions, so that is
    # the balance the imported ledger describes. Older payloads only carry
    # `amount` (the spendable part).
    standard_value = data.dig(:cashAmount, :value).presence || data.dig(:amount, :value)
    balance_value = savings ? data.dig(:totalWorth, :value).to_d : standard_value.to_d

    update!(
      current_balance: balance_value,
      reserved_balance: data.dig(:reservedAmount, :value).to_d,
      currency: currency_code,
      name: name.presence || api_name || default_name,
      raw_payload: payload,
      status: :active,
      closed_at: nil,
      opened_at: parse_time(data[:creationTime]) || opened_at
    )
  end

  def upsert_wise_transactions_snapshot!(transactions)
    update!(raw_transactions_payload: transactions)
  end

  private
    def parse_time(raw)
      Time.zone.parse(raw.to_s) if raw.present?
    rescue ArgumentError
      nil
    end
end
