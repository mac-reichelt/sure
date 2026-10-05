# frozen_string_literal: true

# GraphQL SDK client for the Klutch Card API (built on the AlloyCard platform).
#
# Klutch exposes a single GraphQL endpoint. Authentication is a two-step flow:
#   1. POST a `createSessionToken` mutation with the family's developer
#      client_id + secret_key. This returns a short-lived JWT.
#   2. Send that JWT as a Bearer token on subsequent queries.
#
# The root query type is `AlloyQuery`, exposing `cards`, `transactionsPaginated`,
# `account`, and aggregate helpers like `sumTransactions`.
#
# NOTE: Klutch does not publish an official Ruby SDK and introspection is
# disabled on their endpoint.
class Provider::Klutch
  include HTTParty

  headers "User-Agent" => "Sure Finance Klutch Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  DEFAULT_BASE_URL = "https://graphql.klutchcard.com/graphql"
  TRANSACTION_PAGE_SIZE = 100
  MAX_TRANSACTION_PAGES = 25

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :client_id, :secret_key, :base_url

  def initialize(client_id:, secret_key:, base_url: nil)
    @client_id = client_id
    @secret_key = secret_key
    @base_url = base_url.presence || DEFAULT_BASE_URL
    validate_configuration!
  end

  # Fetch the account's outstanding balance and credit limit.
  #
  # Klutch/AlloyCard model the card as a revolving loan, exposing the current
  # amount owed via `account.revolvingLoan.balance` and the credit limit via
  # `account.revolvingLoan.limit`. The live API returns both values as positive
  # numbers, with `balance` representing the amount owed.
  #
  # Returns { balance: BigDecimal|nil, limit: BigDecimal|nil }, or nil when the
  # revolving-loan field is unavailable (e.g. an older schema or an account with
  # no revolving loan), so callers can fall back to summing settled transactions.
  def get_balance
    data = execute(ACCOUNT_BALANCE_QUERY, operation_name: "get_balance")
    revolving_loan = data.dig(:account, :revolvingLoan)
    return nil if revolving_loan.blank?

    revolving_loan = revolving_loan.with_indifferent_access
    {
      balance: to_big_decimal(revolving_loan[:balance]),
      limit: to_big_decimal(revolving_loan[:limit])
    }
  end

  # Fetch transactions within a date window.
  # statuses: array of transaction statuses (e.g. %w[SETTLED PENDING])
  # types:    array of transaction types (e.g. %w[CHARGE PAYMENT])
  # Returns an array of transaction hashes.
  def get_transactions(start_date:, end_date: Date.current, statuses: nil, types: nil, on_page: nil, on_page_limit: nil)
    filter = build_transaction_filter(start_date: start_date, end_date: end_date, statuses: statuses, types: types)
    transactions = []
    seen_cursors = Set.new
    cursor = nil
    page_count = 0

    loop do
      page_count += 1
      on_page&.call

      data = execute(
        TRANSACTIONS_QUERY,
        variables: {
          filter: filter,
          sortOrder: "UPDATED_DATE_DESC",
          limit: TRANSACTION_PAGE_SIZE,
          nextCursor: cursor
        },
        operation_name: "get_transactions"
      )
      page = data[:transactionsPaginated].to_h.with_indifferent_access
      transactions.concat(normalize_list(page[:list]))

      next_cursor = page[:nextCursor].presence
      break if next_cursor.blank?

      if seen_cursors.include?(next_cursor)
        raise Error.new("Klutch transaction pagination returned a repeated cursor", :pagination_error)
      end

      if page_count >= MAX_TRANSACTION_PAGES
        on_page_limit&.call(page_count)
        break
      end

      seen_cursors.add(next_cursor)
      cursor = next_cursor
    end

    transactions
  end

  # Aggregate the amount of transactions within a window. Used as a fallback for
  # balance derivation when the revolving-loan balance (see #get_balance) is
  # unavailable. Returns a BigDecimal.
  def sum_transactions(start_date:, end_date: Date.current, statuses: nil, types: nil)
    filter = build_transaction_filter(start_date: start_date, end_date: end_date, statuses: statuses, types: types)
    data = execute(SUM_TRANSACTIONS_QUERY, variables: { filter: filter }, operation_name: "sum_transactions")
    to_big_decimal(data[:sumTransactions])
  end

  # Obtain (and memoize) a session JWT for the configured credentials.
  def session_token
    @session_token ||= create_session_token
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    CREATE_SESSION_TOKEN_MUTATION = <<~GRAPHQL
      mutation CreateSessionToken($clientId: String!, $secretKey: String!) {
        createSessionToken(clientId: $clientId, secretKey: $secretKey)
      }
    GRAPHQL

    ACCOUNT_BALANCE_QUERY = <<~GRAPHQL
      query AccountBalance {
        account {
          revolvingLoan {
            balance
            limit
          }
        }
      }
    GRAPHQL

    TRANSACTIONS_QUERY = <<~GRAPHQL
      query TransactionsPaginated($filter: TransactionFilter, $sortOrder: TransactionSortOrder, $limit: Int, $nextCursor: String) {
        transactionsPaginated(filter: $filter, sortOrder: $sortOrder, limit: $limit, nextCursor: $nextCursor) {
          nextCursor
          list {
            id
            amount
            merchantName
            transactionStatus
            transactionType
            transactionDate
            declineReason
            card {
              id
              name
              lastFour
            }
            category {
              id
              name
            }
          }
        }
      }
    GRAPHQL

    SUM_TRANSACTIONS_QUERY = <<~GRAPHQL
      query SumTransactions($filter: TransactionFilter) {
        sumTransactions(filter: $filter)
      }
    GRAPHQL

    def validate_configuration!
      raise ConfigurationError, "Client is required" if @client_id.blank?
      raise ConfigurationError, "Secret key is required" if @secret_key.blank?
    end

    def create_session_token
      body = {
        query: CREATE_SESSION_TOKEN_MUTATION,
        variables: { clientId: client_id, secretKey: secret_key }
      }

      response = with_retries("create_session_token") do
        self.class.post(base_url, headers: base_headers, body: body.to_json)
      end

      data = handle_response(response, authenticating: true)
      session_jwt = data[:createSessionToken]

      if session_jwt.blank?
        raise AuthenticationError.new("Klutch did not return a session token", :unauthorized)
      end

      session_jwt
    end

    # Execute an authenticated GraphQL query/mutation.
    def execute(query, variables: {}, operation_name: nil)
      body = { query: query }
      body[:variables] = variables if variables.present?

      response = with_retries(operation_name || "graphql") do
        self.class.post(base_url, headers: authenticated_headers, body: body.to_json)
      end

      handle_response(response)
    end

    def build_transaction_filter(start_date:, end_date:, statuses:, types:)
      filter = {}
      filter[:startDate] = format_datetime(start_date) if start_date.present?
      filter[:endDate] = format_datetime(end_date) if end_date.present?
      filter[:transactionStatus] = Array(statuses) if statuses.present?
      filter[:transactionTypes] = Array(types) if types.present?
      filter
    end

    def format_datetime(value)
      value.respond_to?(:iso8601) ? value.to_time.utc.iso8601 : value.to_s
    end

    def to_big_decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    # Klutch's `transactions`/`cards` fields are assumed to be plain lists, but
    # defensively handle a Relay-style connection ({ edges: [{ node: {...} }] })
    # in case the schema differs.
    def normalize_list(value)
      return [] if value.blank?
      return value if value.is_a?(Array)

      if value.is_a?(Hash)
        indifferent = value.with_indifferent_access
        if indifferent[:edges].is_a?(Array)
          return indifferent[:edges].map { |edge| edge.is_a?(Hash) ? edge.with_indifferent_access[:node] : edge }.compact
        end
        return Array(indifferent[:nodes]) if indifferent[:nodes].is_a?(Array)
      end

      Array(value)
    end

    def base_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def authenticated_headers
      # AlloyCard authenticates the JWT via the standard "Bearer" scheme,
      # confirmed against Klutch's official api-samples.
      base_headers.merge("Authorization" => "Bearer #{session_token}")
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Klutch API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Klutch API: #{operation_name} failed after #{max_retries} retries: #{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def handle_response(response, authenticating: false)
      case response.code
      when 200, 201
        parse_graphql_body(response.body, authenticating: authenticating)
      when 400
        Rails.logger.error "Klutch API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your Klutch API permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Klutch server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Klutch API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end

    def parse_graphql_body(body, authenticating:)
      parsed = JSON.parse(body, symbolize_names: true)

      if parsed[:errors].present?
        handle_graphql_errors(parsed[:errors], authenticating: authenticating)
      end

      parsed[:data] || {}
    rescue JSON::ParserError => e
      Rails.logger.error "Klutch API: Failed to parse response body: #{e.message}"
      raise Error.new("Failed to parse Klutch response: #{e.message}", :parse_error)
    end

    def handle_graphql_errors(errors, authenticating:)
      messages = Array(errors).map { |err| err.is_a?(Hash) ? (err[:message] || err["message"]) : err.to_s }
      combined = messages.compact.join("; ").presence || "Unknown GraphQL error"

      if authenticating || auth_related?(combined)
        raise AuthenticationError.new(combined, :unauthorized)
      end

      raise Error.new(combined, :graphql_error)
    end

    def auth_related?(message)
      message.to_s.downcase.match?(/unauthor|unauthenticat|forbidden|token|credential|session|permission denied/)
    end
end
