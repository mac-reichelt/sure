require "test_helper"

class KlutchItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "select accounts without credentials renders setup instructions in the modal" do
    get select_accounts_klutch_items_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1 do
      assert_select "h2", text: "Klutch Setup Required"
      assert_select "a[href=?][data-turbo=false]", settings_providers_path
    end
    refute_includes response.body, "<html"
  end

  test "select accounts without credentials redirects normal requests to provider settings" do
    get select_accounts_klutch_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("klutch_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select accounts with credentials renders unlinked Klutch accounts" do
    klutch_item = @user.family.klutch_items.create!(
      name: "Klutch", client_id: "test_client_id", secret_key: "test_secret_key"
    )
    Provider::Klutch.any_instance.stubs(:list_cards).returns([])
    available_account = klutch_item.klutch_accounts.create!(
      name: "Klutch Card", currency: "USD", klutch_account_id: "available", account_status: "active"
    )
    linked_account = klutch_item.klutch_accounts.create!(
      name: "Linked Card", currency: "USD", klutch_account_id: "linked"
    )
    linked_account.ensure_account_provider!(accounts(:credit_card))

    get select_accounts_klutch_items_url,
        params: { accountable_type: "CreditCard", return_to: accounts_path },
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1 do
      assert_select "h2", text: "Select Klutch Accounts"
      assert_select "form[action=?][method=post][data-turbo-frame=_top]", link_accounts_klutch_items_path do
        assert_select "input[name='selected_account_ids[]'][value=?]", available_account.id
        assert_select "input[name='selected_account_ids[]'][value=?]", linked_account.id, count: 0
        assert_select "input[name=accountable_type][value=CreditCard]"
        assert_select "input[name=return_to][value=?]", accounts_path
      end
      assert_select "a[href=?]", accounts_path
    end
    refute_includes response.body, "<html"
    refute_includes response.body, "translation missing"
  end

  test "select accounts rejects unsafe return paths" do
    @user.family.klutch_items.create!(
      name: "Klutch", client_id: "test_client_id", secret_key: "test_secret_key"
    )

    get select_accounts_klutch_items_url,
        params: { return_to: "javascript:alert(1)" },
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "a[href=?]", new_account_path
    refute_includes response.body, "javascript:alert(1)"
  end

  test "other modal linking actions without credentials render setup instructions" do
    [
      [ :get, preload_accounts_klutch_items_url, {} ],
      [ :get, select_existing_account_klutch_items_url, { account_id: accounts(:credit_card).id } ],
      [ :post, link_accounts_klutch_items_url, {} ],
      [ :post, link_existing_account_klutch_items_url, { account_id: accounts(:credit_card).id } ]
    ].each do |method, url, params|
      public_send(method, url, params: params, headers: { "Turbo-Frame" => "modal" })

      assert_response :success
      assert_select "turbo-frame#modal h2", text: "Klutch Setup Required"
    end
  end
end
