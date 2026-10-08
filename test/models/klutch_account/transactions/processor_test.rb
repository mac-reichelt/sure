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

  test "uses transaction type to determine direction regardless of amount sign" do
    klutch_account = create_klutch_account("kl_signs", raw_transactions: [
      {
        "id" => "tx_charge", "amount" => "-100.0", "merchantName" => "Coffee Shop",
        "transactionStatus" => "SETTLED", "transactionType" => "CHARGE",
        "transactionDate" => "2026-01-02T00:00:00Z",
        "card" => { "id" => "card_1", "name" => "Virtual Card", "lastFour" => "4242" }
      },
      {
        "id" => "tx_payment", "amount" => "50.0", "merchantName" => "Card Payment",
        "transactionStatus" => "SETTLED", "transactionType" => "PAYMENT",
        "transactionDate" => "2026-01-03T00:00:00Z"
      },
      {
        "id" => "tx_other", "amount" => "-20.0", "merchantName" => "Other charge",
        "transactionStatus" => "SETTLED", "transactionType" => "OTHER",
        "transactionDate" => "2026-01-04T00:00:00Z",
        "card" => { "id" => "card_2", "name" => "Single-use Card", "lastFour" => "9876" }
      },
      {
        "id" => "tx_positive_charge", "amount" => "40.0", "merchantName" => "Another charge",
        "transactionStatus" => "SETTLED", "transactionType" => "CHARGE",
        "transactionDate" => "2026-01-05T00:00:00Z"
      },
      {
        "id" => "tx_negative_payment", "amount" => "-75.0", "merchantName" => "Another payment",
        "transactionStatus" => "SETTLED", "transactionType" => "PAYMENT",
        "transactionDate" => "2026-01-06T00:00:00Z"
      }
    ])

    assert_difference "@account.entries.count", 5 do
      KlutchAccount::Transactions::Processor.new(klutch_account).process
    end

    charge = @account.entries.find_by(external_id: "tx_charge", source: "klutch")
    payment = @account.entries.find_by(external_id: "tx_payment", source: "klutch")
    other = @account.entries.find_by(external_id: "tx_other", source: "klutch")
    positive_charge = @account.entries.find_by(external_id: "tx_positive_charge", source: "klutch")
    negative_payment = @account.entries.find_by(external_id: "tx_negative_payment", source: "klutch")

    assert_in_delta 100.0, charge.amount, 0.01
    assert_in_delta(-50.0, payment.amount, 0.01)
    assert_in_delta 20.0, other.amount, 0.01
    assert_in_delta 40.0, positive_charge.amount, 0.01
    assert_in_delta(-75.0, negative_payment.amount, 0.01)
    assert_equal "Coffee Shop", charge.name
    assert_equal "card_1", charge.transaction.extra.dig("klutch", "card_id")
    assert_equal "Virtual Card", charge.transaction.extra.dig("klutch", "card_name")
    assert_equal "4242", charge.transaction.extra.dig("klutch", "last_four")
    assert payment.transaction.extra.dig("klutch").key?("card_id")
    assert payment.transaction.extra.dig("klutch").key?("card_name")
    assert payment.transaction.extra.dig("klutch").key?("last_four")
    assert_equal "card_2", other.transaction.extra.dig("klutch", "card_id")
    assert_equal "Single-use Card", other.transaction.extra.dig("klutch", "card_name")
    assert_equal "9876", other.transaction.extra.dig("klutch", "last_four")
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

  test "converts transaction timestamp to the family's timezone" do
    @family.update!(timezone: "America/Los_Angeles")
    klutch_account = create_klutch_account("kl_timezone", raw_transactions: [
      {
        "id" => "tx_timezone", "amount" => "10.0", "transactionType" => "CHARGE",
        "transactionDate" => "2026-10-08T00:30:00Z"
      }
    ])

    KlutchAccount::Transactions::Processor.new(klutch_account).process

    entry = @account.entries.find_by(external_id: "tx_timezone", source: "klutch")
    assert_equal Date.new(2026, 10, 7), entry.date
  end

  test "keeps date-only transaction dates unchanged" do
    @family.update!(timezone: "America/Los_Angeles")
    klutch_account = create_klutch_account("kl_date_only", raw_transactions: [
      {
        "id" => "tx_date_only", "amount" => "10.0", "transactionType" => "CHARGE",
        "transactionDate" => "2026-10-08"
      }
    ])

    KlutchAccount::Transactions::Processor.new(klutch_account).process

    entry = @account.entries.find_by(external_id: "tx_date_only", source: "klutch")
    assert_equal Date.new(2026, 10, 8), entry.date
  end

  test "skips transactions with a nil date" do
    klutch_account = create_klutch_account("kl_nil_date", raw_transactions: [
      {
        "id" => "tx_nil_date", "amount" => "10.0", "transactionType" => "CHARGE",
        "transactionDate" => nil, "date" => nil
      }
    ])

    result = KlutchAccount::Transactions::Processor.new(klutch_account).process

    assert_equal 1, result[:failed]
    assert_nil @account.entries.find_by(external_id: "tx_nil_date", source: "klutch")
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
