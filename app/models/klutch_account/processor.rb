# frozen_string_literal: true

class KlutchAccount::Processor
  include KlutchAccount::DataHelpers

  attr_reader :klutch_account

  def initialize(klutch_account)
    @klutch_account = klutch_account
  end

  def process
    account = klutch_account.current_account
    return unless account

    Rails.logger.info "KlutchAccount::Processor - Processing account #{klutch_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions)
    update_account_balance(account)

    # Process transactions
    transactions_count = klutch_account.raw_transactions_payload&.size || 0
    Rails.logger.info "KlutchAccount::Processor - Transactions payload has #{transactions_count} items"

    if klutch_account.raw_transactions_payload.present?
      Rails.logger.info "KlutchAccount::Processor - Processing transactions..."
      KlutchAccount::Transactions::Processor.new(klutch_account).process
    else
      Rails.logger.warn "KlutchAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "KlutchAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      # Klutch balances are positive amounts owed; use abs as a safeguard.
      balance = klutch_account.current_balance&.abs || 0

      Rails.logger.info "KlutchAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: klutch_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)

      update_available_credit(account, balance)
    end

    # Map the Klutch credit limit onto the CreditCard's available credit.
    # `amount_owed` is the positive balance owed computed above.
    def update_available_credit(account, amount_owed)
      return unless account.accountable_type == "CreditCard"

      limit = klutch_account.credit_limit
      return unless limit&.positive?

      Account::ProviderImportAdapter.new(account).update_accountable_attributes(
        attributes: { available_credit: [ limit - amount_owed, 0 ].max },
        source: "klutch"
      )
    end
end
