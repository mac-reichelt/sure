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
      klutch_account_id: KlutchAccount.card_account_id,
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
    expect_fallback_sums(spending: "-125.00", credits: "0.00")

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
    expect_fallback_sums(spending: "-300.00", credits: "0.00")
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

  test "derives fallback balance from transaction types regardless of sum signs" do
    expect_fallback_sums(spending: "200.00", credits: "-75.00")

    @importer.send(:derive_balance_from_transactions, @klutch_account, fallback_reason: "balance_response_unavailable")

    assert_equal BigDecimal("125.00"), @klutch_account.reload.current_balance
    assert_equal 2, @importer.send(:stats)["api_requests"]
  end

  test "uses the same synthetic account id on repeated imports without pruning it" do
    @item.klutch_accounts.create!(
      name: "Stale account",
      klutch_account_id: "stale-account",
      currency: "USD"
    )
    @importer.send(:import_accounts)
    @importer.send(:import_accounts)

    assert_equal [ KlutchAccount.card_account_id ], @item.klutch_accounts.pluck(:klutch_account_id)
    assert_equal KlutchAccount.card_account_id, @klutch_account.reload.klutch_account_id
    assert_equal "Klutch Card", @klutch_account.name
    assert_nil @klutch_account.institution_metadata["cards"]
    assert_equal accounts(:credit_card), @klutch_account.account_provider.reload.account
  end

  test "does not make an API request to import the shared account" do
    @importer.send(:import_accounts)

    assert_equal 0, @importer.send(:stats).fetch("api_requests", 0)
  end

  test "counts every transaction page and requests all documented transaction types" do
    @provider.expects(:get_transactions).with do |types:, on_page:, **|
      assert_equal %w[CHARGE PAYMENT REFUND OTHER], types
      2.times { on_page.call }
      true
    end.returns([])

    @importer.send(:import_transactions, @klutch_account)

    assert_equal 2, @importer.send(:stats)["api_requests"]
  end

  test "logs a warning and item context when transaction pagination reaches its limit" do
    @provider.expects(:get_transactions).with do |on_page_limit:, **|
      on_page_limit.call(Provider::Klutch::MAX_TRANSACTION_PAGES)
      true
    end.returns([])

    assert_difference "DebugLogEntry.count", 1 do
      @importer.send(:import_transactions, @klutch_account)
    end

    warning = DebugLogEntry.order(:created_at).last
    assert_equal "warn", warning.level
    assert_equal "klutch", warning.provider_key
    assert_equal @item.id, warning.metadata["klutch_item_id"]
    assert_equal Provider::Klutch::MAX_TRANSACTION_PAGES, warning.metadata["page_count"]
  end

  private

    def expect_fallback_sums(spending:, credits:)
      @provider.expects(:sum_transactions).with do |types:, **|
        types == %w[CHARGE OTHER]
      end.returns(BigDecimal(spending))
      @provider.expects(:sum_transactions).with do |types:, **|
        types == %w[PAYMENT REFUND]
      end.returns(BigDecimal(credits))
    end
end
