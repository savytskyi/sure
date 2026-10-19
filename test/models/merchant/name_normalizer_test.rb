require "test_helper"

class Merchant::NameNormalizerTest < ActiveSupport::TestCase
  test "applies alias rules" do
    normalizer = Merchant::NameNormalizer.default

    assert_equal "Lidl", normalizer.normalize("LIDL 1234 MARIBOR")
    assert_equal "Spotify", normalizer.normalize("SPOTIFY AB STOCKHOLM")
    assert_equal "Amazon", normalizer.normalize("AMZN MKTP DE")
    assert_equal "Transport for London", normalizer.normalize("tfl.gov.uk/cp")
  end

  test "falls back to cleaning up processor prefixes, store numbers and capitals" do
    normalizer = Merchant::NameNormalizer.new

    assert_equal "Mercadona", normalizer.normalize("MERCADONA 4471 VALENCIA")
    assert_equal "Blue Bottle", normalizer.normalize("SQ *BLUE BOTTLE")
    assert_equal "dm-drogerie", normalizer.normalize("  dm-drogerie  ")
    assert_nil normalizer.normalize(" ")
  end

  test "keys ignore case, accents, punctuation and whitespace" do
    assert_equal Merchant::NameNormalizer.key("Café Lidl"), Merchant::NameNormalizer.key("CAFE  LIDL")
    assert_equal Merchant::NameNormalizer.key("dm-drogerie"), Merchant::NameNormalizer.key("DM Drogerie")
  end
end
