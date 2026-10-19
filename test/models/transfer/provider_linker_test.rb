require "test_helper"

class Transfer::ProviderLinkerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @eur = @family.accounts.create!(name: "EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    @usd = @family.accounts.create!(name: "USD", balance: 0, currency: "USD", accountable: Depository.new)
    @outflow = entry(@eur, 100, "EUR")
    @inflow = entry(@usd, -108.03, "USD")
  end

  test "links two stated legs with different currencies and amounts" do
    result = Transfer::ProviderLinker.new(outflow_entry: @outflow, inflow_entry: @inflow).link

    assert_equal :linked, result.status
    assert result.transfer.confirmed?
    assert_equal "funds_movement", @outflow.transaction.reload.kind
    assert_equal :existing, Transfer::ProviderLinker.new(outflow_entry: @outflow, inflow_entry: @inflow).link.status
  end

  test "respects a pair the user rejected" do
    RejectedTransfer.create!(inflow_transaction: @inflow.transaction, outflow_transaction: @outflow.transaction)

    assert_equal :rejected, Transfer::ProviderLinker.new(outflow_entry: @outflow, inflow_entry: @inflow).link.status
    assert_not Transfer.exists?(outflow_transaction: @outflow.transaction)
  end

  private
    def entry(account, amount, currency)
      account.entries.create!(name: "Leg", date: Date.new(2024, 5, 1), amount: amount, currency: currency, entryable: Transaction.new)
    end
end
