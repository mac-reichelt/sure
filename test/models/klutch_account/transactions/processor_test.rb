# frozen_string_literal: true

require "test_helper"

class KlutchAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = KlutchItem.create!(
      family: @family, name: "Klutch", client_id: "cid", secret_key: "sk"
    )
    @account = accounts(:credit_card)
  end

  test "negates charge amounts and preserves payment sign" do
    klutch_account = create_klutch_account("kl_signs", raw_transactions: [
      {
        "id" => "tx_charge", "amount" => "-100.0", "merchantName" => "Coffee Shop",
        "transactionStatus" => "SETTLED", "transactionType" => "CHARGE",
        "transactionDate" => "2026-01-02T00:00:00Z",
        "card" => { "lastFour" => "4242" }
      },
      {
        "id" => "tx_payment", "amount" => "50.0", "merchantName" => "Card Payment",
        "transactionStatus" => "SETTLED", "transactionType" => "PAYMENT",
        "transactionDate" => "2026-01-03T00:00:00Z"
      }
    ])

    assert_difference "@account.entries.count", 2 do
      KlutchAccount::Transactions::Processor.new(klutch_account).process
    end

    charge = @account.entries.find_by(external_id: "tx_charge", source: "klutch")
    payment = @account.entries.find_by(external_id: "tx_payment", source: "klutch")

    # Klutch charge (-100) -> +100 (money out); payment (+50) -> -50 (money in)
    assert_in_delta 100.0, charge.amount, 0.01
    assert_in_delta(-50.0, payment.amount, 0.01)
    assert_equal "Coffee Shop", charge.name
    assert_equal "4242", charge.transaction.extra.dig("klutch", "last_four")
  end

  test "flags pending transactions via extra metadata" do
    klutch_account = create_klutch_account("kl_pending", raw_transactions: [
      {
        "id" => "tx_pending", "amount" => "-30.0", "merchantName" => "Pending Store",
        "transactionStatus" => "PENDING", "transactionType" => "CHARGE",
        "transactionDate" => "2026-01-04T00:00:00Z"
      }
    ])

    KlutchAccount::Transactions::Processor.new(klutch_account).process

    entry = @account.entries.find_by(external_id: "tx_pending", source: "klutch")

    assert entry.transaction.pending?
    assert_equal "PENDING", entry.transaction.extra.dig("klutch", "status")
  end

  test "skips transactions with blank external ids" do
    klutch_account = create_klutch_account("kl_blank", raw_transactions: [
      {
        "id" => "", "amount" => "-10.0", "merchantName" => "No Id",
        "transactionStatus" => "SETTLED", "transactionType" => "CHARGE",
        "transactionDate" => "2026-01-05T00:00:00Z"
      }
    ])

    assert_no_difference "@account.entries.count" do
      KlutchAccount::Transactions::Processor.new(klutch_account).process
    end
  end

  private

    def create_klutch_account(external_id, raw_transactions: [])
      ka = @item.klutch_accounts.create!(
        name: external_id, klutch_account_id: external_id, currency: "USD",
        account_type: "credit_card", raw_transactions_payload: raw_transactions
      )
      AccountProvider.create!(provider: ka, account: @account)
      ka
    end
end
