require "test_helper"

class Merchant::FamilyResolverTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "reuses an existing family merchant regardless of case, accents and store numbers" do
    existing = FamilyMerchant.create!(family: @family, name: "LIDL")

    assert_no_difference -> { Merchant.count } do
      assert_equal existing, Merchant::FamilyResolver.new(@family).resolve("LIDL 1234 MARIBOR")
      assert_equal existing, Merchant::FamilyResolver.new(@family).resolve("Lidl")
    end
  end

  test "creates one merchant per normalized name" do
    resolver = Merchant::FamilyResolver.new(@family)

    assert_difference -> { @family.merchants.count }, 1 do
      first = resolver.resolve("SPOTIFY AB STOCKHOLM")
      assert_equal first, resolver.resolve("Spotify P1234")
      assert_equal "Spotify", first.name
    end
  end

  test "keeps using a merchant the user renamed" do
    resolver = Merchant::FamilyResolver.new(@family)
    merchant = resolver.resolve("LIDL 1234 MARIBOR")
    merchant.update!(name: "Lidl Slovenija")

    assert_no_difference -> { Merchant.count } do
      assert_equal merchant, Merchant::FamilyResolver.new(@family).resolve("LIDL 99 LJUBLJANA", remembered_id: merchant.id)
    end
  end
end
