# frozen_string_literal: true

# Parsing for Wise activity-feed display text. Activities carry no numeric
# amounts: "<positive>+ 2,500 EUR</positive>", "4,517.28 DKK", "EUR, USD".
# Anything that does not match the documented shapes returns nil rather than
# a guess.
module WiseActivity::Text
  TAG = %r{</?[a-z]+>}i
  AMOUNT = /\A\s*([+\-−])?\s*(\d{1,3}(?:,\d{3})*(?:\.\d+)?|\d+(?:\.\d+)?)\s+([A-Z]{3,5})\s*\z/
  CURRENCY_LIST = /\A\s*[A-Z]{3}(?:\s*,\s*[A-Z]{3})+\s*\z/

  Amount = Data.define(:value, :currency, :credit) do
    def magnitude = value&.abs
  end

  module_function

  def strip_tags(text)
    text.to_s.gsub(TAG, "").strip
  end

  # @return [Amount] value and currency are nil when the text is not a single amount
  def parse_amount(text)
    raw = text.to_s
    credit = raw.include?("<positive>")
    match = AMOUNT.match(strip_tags(raw))
    return Amount.new(value: nil, currency: nil, credit: credit) unless match

    sign, number, currency = match.captures
    value = number.delete(",").to_d
    value = -value if sign.in?([ "-", "−" ])
    Amount.new(value: value, currency: currency, credit: credit || sign == "+")
  end

  # "EUR, USD": a card payment or batch funded from several balances, with no
  # per-balance amounts.
  def currency_list?(text)
    CURRENCY_LIST.match?(strip_tags(text))
  end
end
