# frozen_string_literal: true

# Links two provider-imported transactions that the provider itself states
# are the two legs of one movement between the family's own accounts (a
# currency conversion, a move between own balances) as a confirmed Transfer.
#
# Unlike Family::AutoTransferMatchable, nothing is guessed from amounts or
# dates: the caller supplies both legs. Legs may differ in currency and
# amount. A pair the user rejected before, or a leg that already belongs to a
# transfer, is left alone. Provider-independent.
class Transfer::ProviderLinker
  Result = Data.define(:transfer, :status, :error)

  def initialize(outflow_entry:, inflow_entry:)
    @outflow_entry = outflow_entry
    @inflow_entry = inflow_entry
  end

  def link
    outflow = @outflow_entry&.entryable
    inflow = @inflow_entry&.entryable
    return result(:invalid, "both legs must be transactions") unless outflow.is_a?(Transaction) && inflow.is_a?(Transaction)

    existing = Transfer.find_by(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
    return result(:existing, nil, existing) if existing

    if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
      return result(:rejected, "the user rejected this pair")
    end

    if Transfer.where(inflow_transaction_id: [ inflow.id, outflow.id ]).or(Transfer.where(outflow_transaction_id: [ inflow.id, outflow.id ])).exists?
      return result(:conflict, "a leg already belongs to another transfer")
    end

    transfer = Transfer.new(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    Transfer.transaction do
      transfer.save!
      # Applies the leg kinds (funds movement, investment contribution, ...)
      # exactly as a user confirmation would.
      transfer.confirm!
    end

    result(:linked, nil, transfer)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    result(:invalid, e.message)
  end

  private
    def result(status, error, transfer = nil)
      Result.new(transfer: transfer, status: status, error: error)
    end
end
