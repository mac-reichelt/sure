# frozen_string_literal: true

require "test_helper"

class Provider::KlutchTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  def token_response
    FakeResponse.new(code: 200, message: "OK", body: { data: { createSessionToken: "test-jwt" } }.to_json)
  end

  test "raises configuration error when client_id is blank" do
    assert_raises Provider::Klutch::ConfigurationError do
      Provider::Klutch.new(client_id: "", secret_key: "secret")
    end
  end

  test "raises configuration error when secret_key is blank" do
    assert_raises Provider::Klutch::ConfigurationError do
      Provider::Klutch.new(client_id: "client", secret_key: "")
    end
  end

  test "authenticates then fetches transactions with a bearer token and filter" do
    transactions_body = {
      data: {
        transactions: [
          {
            id: "tx_1", amount: "-100.0", merchantName: "Coffee Shop",
            transactionStatus: "SETTLED", transactionType: "CHARGE",
            transactionDate: "2026-01-02T00:00:00Z"
          }
        ]
      }
    }.to_json

    responses = [ token_response, FakeResponse.new(code: 200, message: "OK", body: transactions_body) ]
    requests = []

    Provider::Klutch.stub(:post, ->(url, headers:, body:) {
      requests << { url: url, headers: headers, body: JSON.parse(body) }
      responses.shift
    }) do
      client = Provider::Klutch.new(
        client_id: "client", secret_key: "secret",
        base_url: "https://sandbox.klutchcard.com/graphql"
      )

      transactions = client.get_transactions(
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 1, 31),
        statuses: %w[SETTLED],
        types: %w[CHARGE]
      )

      assert_equal [ "tx_1" ], transactions.map { |tx| tx[:id] }
    end

    # First request authenticates with the developer credentials.
    auth_request = requests.first
    assert_equal "https://sandbox.klutchcard.com/graphql", auth_request[:url]
    assert_includes auth_request[:body]["query"], "createSessionToken"
    assert_equal "client", auth_request[:body].dig("variables", "clientId")
    assert_equal "secret", auth_request[:body].dig("variables", "secretKey")

    # Second request carries the bearer token and the transaction filter.
    data_request = requests.second
    assert_equal "Bearer test-jwt", data_request[:headers]["Authorization"]
    filter = data_request[:body].dig("variables", "filter")
    # Dates are serialized as UTC ISO8601 (compare against the same transform
    # so the assertion is independent of the host timezone).
    assert_equal Date.new(2026, 1, 1).to_time.utc.iso8601, filter["startDate"]
    assert_equal Date.new(2026, 1, 31).to_time.utc.iso8601, filter["endDate"]
    assert_equal %w[SETTLED], filter["transactionStatus"]
    assert_equal %w[CHARGE], filter["transactionTypes"]
  end

  test "sum_transactions returns a BigDecimal in Klutch's raw sign convention" do
    responses = [ token_response, FakeResponse.new(code: 200, message: "OK", body: { data: { sumTransactions: "-500.0" } }.to_json) ]

    Provider::Klutch.stub(:post, ->(_url, headers:, body:) { responses.shift }) do
      client = Provider::Klutch.new(client_id: "client", secret_key: "secret")
      result = client.sum_transactions(start_date: Date.new(2026, 1, 1), statuses: %w[SETTLED])

      assert_equal BigDecimal("-500.0"), result
    end
  end

  test "raises AuthenticationError when the token mutation returns GraphQL errors" do
    error_response = FakeResponse.new(
      code: 200, message: "OK",
      body: { errors: [ { message: "invalid credentials" } ] }.to_json
    )

    Provider::Klutch.stub(:post, ->(_url, headers:, body:) { error_response }) do
      client = Provider::Klutch.new(client_id: "client", secret_key: "bad")

      assert_raises Provider::Klutch::AuthenticationError do
        client.list_cards
      end
    end
  end

  test "raises AuthenticationError on HTTP 401" do
    responses = [ token_response, FakeResponse.new(code: 401, message: "Unauthorized", body: "{}") ]

    Provider::Klutch.stub(:post, ->(_url, headers:, body:) { responses.shift }) do
      client = Provider::Klutch.new(client_id: "client", secret_key: "secret")

      assert_raises Provider::Klutch::AuthenticationError do
        client.list_cards
      end
    end
  end
end
