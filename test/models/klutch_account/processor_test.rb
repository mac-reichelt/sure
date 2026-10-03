# frozen_string_literal: true

require "test_helper"

class KlutchAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = KlutchItem.create!(
      family: @family, name: "Klutch", client_id: "cid", secret_key: "sk"
    )
  end

  # ---------------------------------------------------------------------------
  # balance sign convention
  # ---------------------------------------------------------------------------

  test "converts Klutch negative settled sum into positive amount owed for credit cards" do
    account = accounts(:credit_card)
    klutch_account = create_klutch_account("kl_cc", account: account, balance: -250.0)

    KlutchAccount::Processor.new(klutch_account).process

    # Klutch reports settled charges as a negative sum (-250 => $250 spent);
    # Sure stores credit-card debt as a positive balance.
    assert_in_delta 250.0, account.reload.cash_balance, 0.01
  end

  test "sets available credit from the Klutch credit limit for credit cards" do
    account = accounts(:credit_card)
    klutch_account = create_klutch_account("kl_limit", account: account, balance: -250.0, credit_limit: 1000.0)

    KlutchAccount::Processor.new(klutch_account).process

    # $250 owed against a $1,000 limit leaves $750 of available credit.
    assert_in_delta 750.0, account.reload.accountable.available_credit, 0.01
  end

  # ---------------------------------------------------------------------------
  # no linked account
  # ---------------------------------------------------------------------------

  test "returns nil without error when there is no linked account" do
    klutch_account = @item.klutch_accounts.create!(
      name: "Unlinked", klutch_account_id: "kl_unlinked", currency: "USD", current_balance: -10
    )

    result = nil
    assert_nothing_raised do
      result = KlutchAccount::Processor.new(klutch_account).process
    end
    assert_nil result
  end

  # ---------------------------------------------------------------------------
  # transaction processing delegation
  # ---------------------------------------------------------------------------

  test "processes transactions stored in raw_transactions_payload" do
    account = accounts(:credit_card)
    klutch_account = create_klutch_account("kl_tx", account: account, balance: -100.0,
      raw_transactions: [
        {
          "id" => "tx_a", "amount" => "-100.0", "merchantName" => "Coffee",
          "transactionStatus" => "SETTLED", "transactionType" => "CHARGE",
          "transactionDate" => "2026-01-02T00:00:00Z"
        }
      ]
    )

    assert_difference 'account.entries.where(source: "klutch").count', 1 do
      KlutchAccount::Processor.new(klutch_account).process
    end
  end

  private

    def create_klutch_account(external_id, account:, balance: nil, credit_limit: nil, raw_transactions: [])
      ka = @item.klutch_accounts.create!(
        name: external_id, klutch_account_id: external_id, currency: "USD",
        account_type: "credit_card", current_balance: balance, credit_limit: credit_limit,
        raw_transactions_payload: raw_transactions
      )
      AccountProvider.create!(provider: ka, account: account)
      ka
    end
end
