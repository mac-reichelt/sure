# frozen_string_literal: true

require "test_helper"

class Provider::KlutchAdapterTest < ActiveSupport::TestCase
  test "supports banking account types" do
    types = Provider::KlutchAdapter.supported_account_types

    assert_includes types, "Depository"
    assert_includes types, "CreditCard"
    assert_includes types, "Loan"
  end

  test "provider_name is klutch" do
    adapter = Provider::KlutchAdapter.allocate
    assert_equal "klutch", adapter.provider_name
  end

  test "is registered with the provider factory" do
    assert Provider::Factory.registered?("KlutchAccount")
  end
end
