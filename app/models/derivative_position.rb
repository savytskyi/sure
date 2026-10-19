# frozen_string_literal: true

# A derivatives position (perpetual or dated future) as a provider reported
# it. Provider-independent.
#
# A position is exposure, not an asset. What it is worth to the owner is
# already in the margin wallet as unrealized P&L, so the notional value here
# is never added to an account balance or to net worth; it is kept so the
# exposure can be shown and reasoned about.
#
# One row per episode: the row stays `open` while the provider keeps
# reporting the position, becomes `closed` the first time a complete report
# no longer contains it, and a later position on the same symbol and side is
# a new row. A one-way position that flips from long to short is a close and
# a reopen.
class DerivativePosition < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
  end

  QUANTITY_UNITS = %w[contracts base].freeze

  enum :status, { open: "open", closed: "closed" }, validate: true

  belongs_to :family
  belongs_to :item, polymorphic: true
  belongs_to :provider_account, polymorphic: true, optional: true
  belongs_to :account, optional: true

  validates :provider_key, :market, :symbol, :position_side, presence: true
  validates :quantity, :first_observed_at, :last_observed_at, presence: true
  validates :quantity_unit, inclusion: { in: QUANTITY_UNITS }

  scope :for_provider, ->(key) { where(provider_key: key) }

  def long?
    quantity.positive?
  end

  def short?
    quantity.negative?
  end

  # Reconciles one market's complete position report with the stored
  # episodes. Only call it with a report that was read in full: anything
  # missing from it is taken as closed.
  #
  # @param reported [Array<Hash>] attributes per open position; each needs
  #   :symbol, :position_side and a non-zero :quantity
  # @return [Hash] counts of :opened, :updated and :closed episodes
  def self.reconcile!(item:, provider_key:, market:, reported:, observed_at: Time.current, provider_account: nil, account: nil)
    counts = { opened: 0, updated: 0, closed: 0 }
    scope = where(item: item, market: market)

    transaction do
      open_by_key = scope.open.index_by { |position| [ position.symbol, position.position_side ] }

      reported.each do |attributes|
        key = [ attributes.fetch(:symbol), attributes.fetch(:position_side) ]
        current = open_by_key.delete(key)

        # Same side of the book, so the same episode, whatever its size did.
        if current && current.quantity.positive? == attributes.fetch(:quantity).to_d.positive?
          current.update!(attributes.merge(last_observed_at: observed_at, account: account || current.account))
          counts[:updated] += 1
          next
        end

        if current
          current.update!(status: :closed, closed_at: observed_at)
          counts[:closed] += 1
        end

        create!(
          attributes.merge(
            family: item.family, item: item, provider_key: provider_key, market: market,
            provider_account: provider_account, account: account, status: :open,
            opened_at: observed_at, first_observed_at: observed_at, last_observed_at: observed_at
          )
        )
        counts[:opened] += 1
      end

      open_by_key.each_value do |position|
        position.update!(status: :closed, closed_at: observed_at)
        counts[:closed] += 1
      end
    end

    counts
  end
end
