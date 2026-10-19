# frozen_string_literal: true

# Finds the merchant a provider transaction belongs to, preferring merchants
# the family already uses, so capitalization, accents, whitespace or store
# numbers never produce a second "Lidl". Creates a FamilyMerchant only when
# nothing matches. Provider-independent; one instance per sync caches the
# family's merchants.
class Merchant::FamilyResolver
  def initialize(family, normalizer: Merchant::NameNormalizer.default)
    @family = family
    @normalizer = normalizer
  end

  def normalized_name(raw_name)
    @normalizer.normalize(raw_name)
  end

  # `remembered_id` is the merchant this raw name resolved to before. Reusing
  # it keeps working after the user renames that merchant.
  def resolve(raw_name, remembered_id: nil)
    name = normalized_name(raw_name)
    return nil if name.blank?

    remembered = known_by_id[remembered_id] if remembered_id.present?
    return remembered if remembered

    key = Merchant::NameNormalizer.key(name)
    return nil if key.blank?

    known_by_key[key] ||= begin
      merchant, _created = FamilyMerchant.find_or_create_with_name(@family, name)
      known_by_id[merchant.id] = merchant
    end
  end

  private
    def known_merchants
      @known_merchants ||= (@family.merchants.to_a + @family.assigned_merchants.to_a).uniq(&:id)
    end

    def known_by_id
      @known_by_id ||= known_merchants.index_by(&:id)
    end

    # Family-owned merchants win over provider merchants with the same key.
    def known_by_key
      @known_by_key ||= known_merchants
        .sort_by { |merchant| merchant.is_a?(FamilyMerchant) ? 0 : 1 }
        .each_with_object({}) { |merchant, map| map[Merchant::NameNormalizer.key(merchant.name)] ||= merchant }
    end
end
