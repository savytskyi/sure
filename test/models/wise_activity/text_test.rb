require "test_helper"

class WiseActivity::TextTest < ActiveSupport::TestCase
  test "parses Wise display amounts exactly" do
    amount = WiseActivity::Text.parse_amount("<positive>+ 2,500.10 EUR</positive>")
    assert_equal [ BigDecimal("2500.10"), "EUR", true ], [ amount.value, amount.currency, amount.credit ]

    amount = WiseActivity::Text.parse_amount("4,517.28 DKK")
    assert_equal [ BigDecimal("4517.28"), "DKK", false ], [ amount.value, amount.currency, amount.credit ]

    assert_equal BigDecimal("-80"), WiseActivity::Text.parse_amount("<negative>- 80.00 EUR</negative>").value
  end

  test "returns no amount for text it does not recognize" do
    assert_nil WiseActivity::Text.parse_amount("EUR, USD").value
    assert_nil WiseActivity::Text.parse_amount("").currency
    assert WiseActivity::Text.currency_list?("EUR, USD")
    assert_not WiseActivity::Text.currency_list?("10 EUR")
  end
end
