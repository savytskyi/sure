# frozen_string_literal: true

class WiseAccount::Processor
  attr_reader :wise_account

  def initialize(wise_account)
    @wise_account = wise_account
  end

  def process
    unless wise_account.current_account.present?
      Rails.logger.info "WiseAccount::Processor - No linked account for wise_account #{wise_account.id}, skipping"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "WiseAccount::Processor - Failed to process account #{wise_account.id}: #{e.message}"
    Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    raise
  end

  private

    # Wise's balance snapshot is authoritative for the current balance. It is
    # recorded as the account's current anchor (a valuation, not a
    # transaction), so incomplete history never turns into invented income or
    # expense; earlier anchors become reconciliation points. A balance Wise no
    # longer lists has no current snapshot and keeps its last one.
    def process_account!
      account = wise_account.current_account
      return unless wise_account.active?

      balance = wise_account.current_balance || 0

      account.update!(cash_balance: balance, currency: wise_account.currency)
      result = account.set_current_balance(balance)
      return if result.success?

      Rails.logger.warn "WiseAccount::Processor - Could not set current balance for wise_account #{wise_account.id}: #{result.error}"
      account.update!(balance: balance)
    end

    def process_transactions
      WiseAccount::Transactions::Processor.new(wise_account).process
    rescue StandardError => e
      Rails.logger.error "WiseAccount::Processor - Failed to process transactions for wise_account #{wise_account.id}: #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    end
end
