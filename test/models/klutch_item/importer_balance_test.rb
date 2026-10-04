# frozen_string_literal: true

require "test_helper"

class KlutchItem::ImporterBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = KlutchItem.create!(
      family: @family,
      name: "Klutch",
      client_id: "client",
      secret_key: "secret"
    )
    @klutch_account = @item.klutch_accounts.create!(
      name: "Klutch Card",
      klutch_account_id: "klutch-account-1",
      currency: "USD",
      current_balance: BigDecimal("-10")
    )
    AccountProvider.create!(account: accounts(:credit_card), provider: @klutch_account)
    @provider = mock("klutch_provider")
    @importer = KlutchItem::Importer.new(@item, klutch_provider: @provider)
  end

  test "stores the positive amount owed and credit limit reported by Klutch" do
    @provider.expects(:get_balance).returns(
      balance: BigDecimal("250.00"),
      limit: BigDecimal("1000.00")
    )
    @provider.expects(:sum_transactions).never

    assert_no_difference "DebugLogEntry.count" do
      @importer.send(:update_balance, @klutch_account)
    end

    assert_equal BigDecimal("250.00"), @klutch_account.reload.current_balance
    assert_equal BigDecimal("1000.00"), @klutch_account.credit_limit
  end

  test "normalizes a negative upstream balance to positive amount owed" do
    @provider.expects(:get_balance).returns(
      balance: BigDecimal("-250.00"),
      limit: BigDecimal("1000.00")
    )

    @importer.send(:update_balance, @klutch_account)

    assert_equal BigDecimal("250.00"), @klutch_account.reload.current_balance
    assert_equal BigDecimal("1000.00"), @klutch_account.credit_limit
  end

  test "falls back and logs a warning when the reported balance is missing" do
    @provider.expects(:get_balance).returns(nil)
    @provider.expects(:sum_transactions).returns(BigDecimal("-125.00"))

    assert_difference "DebugLogEntry.count", 1 do
      @importer.send(:update_balance, @klutch_account)
    end

    assert_equal BigDecimal("125.00"), @klutch_account.reload.current_balance
    fallback_log = DebugLogEntry.order(:created_at).last
    assert_equal "warn", fallback_log.level
    assert_equal "klutch", fallback_log.provider_key
    assert_equal "settled_transactions", fallback_log.metadata["balance_source"]
    assert_equal "balance_response_unavailable", fallback_log.metadata["fallback_reason"]
  end

  test "logs a failed balance request and falls back without raising" do
    error = Provider::Klutch::Error.new("balance endpoint unavailable", :server_error)
    @provider.expects(:get_balance).raises(error)
    @provider.expects(:sum_transactions).returns(BigDecimal("-300.00"))
    Rails.logger.expects(:warn).with do |message|
      message.include?(@klutch_account.id) &&
        message.include?("Provider::Klutch::Error") &&
        message.include?("balance endpoint unavailable")
    end

    assert_difference "DebugLogEntry.count", 2 do
      assert_nothing_raised { @importer.send(:update_balance, @klutch_account) }
    end

    assert_equal BigDecimal("300.00"), @klutch_account.reload.current_balance
    logs = DebugLogEntry.where(provider_key: "klutch").order(:created_at).to_a
    failure_log = logs.find { |entry| entry.metadata["error_class"] }
    fallback_log = logs.find { |entry| entry.metadata["balance_source"] }
    assert_equal "Provider::Klutch::Error", failure_log.metadata["error_class"]
    assert_equal "balance endpoint unavailable", failure_log.metadata["error"]
    assert_equal @family.id, failure_log.family_id
    assert_equal @klutch_account.account_provider.id, failure_log.account_provider_id
    assert_equal "settled_transactions", fallback_log.metadata["balance_source"]
  end

  test "keeps linked account when fetching account information fails" do
    @provider.expects(:list_cards).twice.returns([])
    @provider.expects(:get_account).twice.returns(id: @klutch_account.klutch_account_id)
      .then.raises(Provider::Klutch::Error.new("account endpoint unavailable", :server_error))

    assert_difference "DebugLogEntry.count", 1 do
      @importer.send(:import_accounts, @item.klutch_credentials)
      @importer.send(:import_accounts, @item.klutch_credentials)
    end

    assert_equal [ @klutch_account.id ], @item.klutch_accounts.pluck(:id)
    assert_equal accounts(:credit_card), @klutch_account.account_provider.reload.account
  end
end
