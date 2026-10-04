# frozen_string_literal: true

class KlutchItem::Importer
  include SyncStats::Collector
  include KlutchAccount::DataHelpers

  # Klutch transaction statuses and types (AlloyCard enums)
  SETTLED_STATUS = "SETTLED"
  PENDING_STATUS = "PENDING"
  TRANSACTION_TYPES = %w[CHARGE PAYMENT REFUND].freeze

  attr_reader :klutch_item, :klutch_provider, :sync

  def initialize(klutch_item, klutch_provider:, sync: nil)
    @klutch_item = klutch_item
    @klutch_provider = klutch_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "KlutchItem::Importer - Starting import for item #{klutch_item.id}"

    credentials = klutch_item.klutch_credentials
    unless credentials
      raise CredentialsError, "No Klutch credentials configured for item #{klutch_item.id}"
    end

    # Step 1: Fetch and store the Klutch card account
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch transactions + balance.
    # Unlinked accounts just need basic info (name) for the setup modal.
    linked_accounts = KlutchAccount
      .where(klutch_item_id: klutch_item.id)
      .joins(:account_provider)

    Rails.logger.info "KlutchItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |klutch_account|
      Rails.logger.info "KlutchItem::Importer - Processing linked account #{klutch_account.id}"
      import_account_data(klutch_account, credentials)
    end

    # Update raw payload on the item
    klutch_item.upsert_klutch_snapshot!(stats)
  rescue Provider::Klutch::AuthenticationError => e
    klutch_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts(credentials)
      Rails.logger.info "KlutchItem::Importer - Fetching cards and account"

      cards = klutch_provider.list_cards
      account_info = klutch_provider.get_account

      stats["api_requests"] = stats.fetch("api_requests", 0) + 2

      if Rails.configuration.x.klutch.debug_raw
        Rails.logger.debug "Klutch raw cards: #{cards.to_json}"
        Rails.logger.debug "Klutch raw account: #{account_info.to_json}"
      end

      # Klutch exposes a single card account per connection. Build one synthetic
      # account payload from the account info + cards metadata.
      account_data = build_account_payload(account_info, cards)
      stats["total_accounts"] = 1

      upstream_account_ids = []

      begin
        import_account(account_data, credentials)
        upstream_account_ids << account_data[:id].to_s if account_data[:id]
      rescue => e
        Rails.logger.error "KlutchItem::Importer - Failed to import account: #{e.message}"
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        register_error(e, account_data: account_data)
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    # Assemble a normalized account hash from Klutch cards + account info.
    def build_account_payload(account_info, cards)
      account_info = (account_info || {}).with_indifferent_access
      cards = Array(cards).map { |c| c.is_a?(Hash) ? c.with_indifferent_access : c }
      primary_card = cards.first || {}

      # Stable identifier: prefer the AlloyCard account id, fall back to a
      # deterministic per-item id so repeated syncs upsert the same record.
      account_id = account_info[:id].presence || "klutch_account_#{klutch_item.id}"

      last_four = primary_card[:lastFour].presence
      name = last_four ? "Klutch Card ••#{last_four}" : "Klutch Card"

      {
        id: account_id.to_s,
        name: name,
        currency: "USD",
        account_type: "credit_card",
        status: primary_card[:status],
        provider: "klutch",
        institution_name: "Klutch",
        cards: cards,
        account_info: account_info
      }.with_indifferent_access
    end

    def import_account(account_data, credentials)
      klutch_account_id = account_data[:id].to_s
      return if klutch_account_id.blank?

      klutch_account = klutch_item.klutch_accounts.find_or_initialize_by(
        klutch_account_id: klutch_account_id
      )

      # Update from API data
      klutch_account.upsert_from_klutch!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(klutch_account, credentials)
      # Import transactions
      import_transactions(klutch_account, credentials)

      # Fetch and store the account balance (revolving-loan balance + credit
      # limit, falling back to a settled-transaction sum when unavailable).
      update_balance(klutch_account)
    end

    def import_transactions(klutch_account, credentials)
      Rails.logger.info "KlutchItem::Importer - Fetching transactions for account #{klutch_account.id}"

      begin
        start_date = calculate_transaction_start_date(klutch_account)
        end_date = Date.current
        statuses = transaction_statuses

        transactions_data = klutch_provider.get_transactions(
          start_date: start_date,
          end_date: end_date,
          statuses: statuses,
          types: TRANSACTION_TYPES
        )

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if Rails.configuration.x.klutch.debug_raw
          Rails.logger.debug "Klutch raw transactions: #{transactions_data.to_json}"
        end

        if transactions_data.any?
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(klutch_account.raw_transactions_payload || [], transactions_hashes)
          klutch_account.upsert_klutch_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue Provider::Klutch::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "KlutchItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: klutch_account.id)
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Klutch transaction fetch failed for account #{klutch_account.klutch_account_id}",
          source: self.class.name,
          provider_key: "klutch",
          family: klutch_item.family,
          metadata: { account_id: klutch_account.klutch_account_id, error_class: e.class.name, error: e.message }
        )
      end
    end

    # Fetch and store the account balance. Klutch/AlloyCard expose the current
    # amount owed and credit limit via `account.revolvingLoan`; when available
    # that is used as the authoritative balance. If the revolving-loan field is
    # unavailable we fall back to summing settled transactions.
    def update_balance(klutch_account)
      revolving_loan = begin
        klutch_provider.get_balance
      rescue Provider::Klutch::Error => e
        log_balance_fetch_failure(klutch_account, e)
        nil
      ensure
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      end
      revolving_loan = revolving_loan.with_indifferent_access if revolving_loan.respond_to?(:with_indifferent_access)

      if revolving_loan && revolving_loan[:balance]
        # Klutch reports the amount owed as a positive number.
        klutch_account.update!(
          current_balance: revolving_loan[:balance].abs,
          credit_limit: revolving_loan[:limit]
        )
        return
      end

      fallback_reason = revolving_loan.nil? ? "balance_response_unavailable" : "balance_value_missing"
      derive_balance_from_transactions(klutch_account, fallback_reason: fallback_reason)
    rescue => e
      # Balance is best-effort; keep the previous value and record for support.
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Klutch balance update failed for account #{klutch_account.klutch_account_id}; keeping previous balance",
        source: self.class.name,
        provider_key: "klutch",
        family: klutch_item.family,
        metadata: { account_id: klutch_account.klutch_account_id, error_class: e.class.name, error: e.message }
      )
      Rails.logger.warn "KlutchItem::Importer - Failed to update balance for account #{klutch_account.id}: #{e.message}"
    end

    # Fallback balance derivation: sum SETTLED transactions. Klutch returns
    # charges as negative amounts, so negate their net sum to get amount owed.
    def derive_balance_from_transactions(klutch_account, fallback_reason:)
      start_date = balance_window_start(klutch_account)

      balance = klutch_provider.sum_transactions(
        start_date: start_date,
        end_date: Date.current,
        statuses: [ SETTLED_STATUS ],
        types: TRANSACTION_TYPES
      )

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      return if balance.nil?

      klutch_account.update!(current_balance: -balance)
      log_balance_fallback(klutch_account, fallback_reason:)
    end

    def log_balance_fetch_failure(klutch_account, error)
      message = "Klutch revolving-loan balance fetch failed for account #{klutch_account.id} " \
        "(#{klutch_account.klutch_account_id}): #{error.class}: #{error.message}; falling back to settled transactions"

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "klutch",
        family: klutch_item.family,
        account: klutch_account.current_account,
        account_provider: klutch_account.account_provider,
        metadata: {
          klutch_item_id: klutch_item.id,
          klutch_account_id: klutch_account.id,
          account_id: klutch_account.klutch_account_id,
          error_class: error.class.name,
          error: error.message
        }
      )
      Rails.logger.warn(message)
    end

    def log_balance_fallback(klutch_account, fallback_reason:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Using settled-transaction balance fallback for Klutch account #{klutch_account.id} " \
          "(#{klutch_account.klutch_account_id})",
        source: self.class.name,
        provider_key: "klutch",
        family: klutch_item.family,
        account: klutch_account.current_account,
        account_provider: klutch_account.account_provider,
        metadata: {
          klutch_item_id: klutch_item.id,
          klutch_account_id: klutch_account.id,
          account_id: klutch_account.klutch_account_id,
          balance_source: "settled_transactions",
          fallback_reason: fallback_reason
        }
      )
    end

    def transaction_statuses
      if Rails.configuration.x.klutch.include_pending
        [ SETTLED_STATUS, PENDING_STATUS ]
      else
        [ SETTLED_STATUS ]
      end
    end

    def calculate_transaction_start_date(klutch_account)
      # Use user-specified start date if available
      user_start = klutch_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      existing_count = (klutch_account.raw_transactions_payload || []).size
      if existing_count >= 10 && klutch_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch updates
        (klutch_item.last_synced_at - 7.days).to_date
      else
        # Full sync: go back 90 days
        90.days.ago.to_date
      end
    end

    # For the balance sum we always want the full settled history, capped at a
    # generous window (Klutch charges accrue over the statement lifetime).
    def balance_window_start(klutch_account)
      user_start = klutch_account.sync_start_date
      return user_start if user_start.present?

      3.years.ago.to_date
    end

    def merge_transactions(existing, new_transactions)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      # Use ID if available, otherwise generate key from date/amount/description
      transaction[:id] || transaction["id"] ||
        [ transaction[:transactionDate], transaction[:amount], transaction[:merchantName] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = klutch_item.klutch_accounts
        .where.not(klutch_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "KlutchItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
