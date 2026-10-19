# frozen_string_literal: true

# The profile's balances as they existed over time, for deciding which
# balance an activity touched when Wise does not say.
#
# A balance is eligible for currency inference only if it is a STANDARD
# balance (jars never are) of that currency that existed at the time: a
# closed balance is never reused for later activity, and a balance opened
# later never absorbs older activity. Wise allows one STANDARD balance per
# currency at a time, so "exactly one eligible" is a deterministic rule;
# zero or several means the account is not determinable.
class WiseItem::BalanceRegistry
  def initialize(wise_accounts)
    @accounts = wise_accounts.to_a
  end

  def eligible(currency, at)
    return [] if currency.blank? || at.nil?

    @accounts.select do |account|
      account.currency == currency && !account.jar? && account.existed_at?(at)
    end
  end

  # [account, basis] for the single eligible balance, or [nil, reason].
  def infer(currency, at)
    return [ nil, "no_currency" ] if currency.blank?

    found = eligible(currency, at)
    case found.size
    when 1 then [ found.first, "single_eligible_balance" ]
    when 0 then [ nil, "no_eligible_balance" ]
    else [ nil, "multiple_eligible_balances" ]
    end
  end

  def find(balance_id)
    @accounts.find { |account| account.balance_id.to_s == balance_id.to_s }
  end

  # A jar is identified by its name, the only thing activity titles give.
  def jar_named(name, currency)
    jars = @accounts.select do |account|
      account.jar? && account.currency == currency && account.name.to_s.strip.casecmp?(name.to_s.strip)
    end
    jars.one? ? jars.first : nil
  end

  def jars(currency)
    @accounts.select { |account| account.jar? && account.currency == currency }
  end

  def add(account)
    @accounts << account unless @accounts.include?(account)
  end
end
