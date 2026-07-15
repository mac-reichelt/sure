# frozen_string_literal: true

class KlutchAccount < ApplicationRecord
  include CurrencyNormalizable
  include KlutchAccount::DataHelpers

  belongs_to :klutch_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  # Map a normalized Klutch account payload onto this record.
  # NOTE: current_balance is intentionally NOT set here — Klutch exposes no
  # balance field, so KlutchItem::Importer derives it from settled transactions
  # separately. Overwriting it here would clobber that derived value with nil.
  def upsert_from_klutch!(account_data)
    data = sdk_object_to_hash(account_data).with_indifferent_access

    update!(
      klutch_account_id: (data[:id] || data[:account_id])&.to_s,
      name: data[:name].presence || name,
      currency: extract_currency(data, fallback: "USD"),
      account_status: data[:status] || data[:account_status],
      account_type: data[:account_type] || "credit_card",
      provider: data[:provider] || "klutch",
      institution_metadata: extract_institution_metadata(data),
      raw_payload: data
    )
  end

  def upsert_klutch_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || "Klutch",
        cards: data[:cards]
      }.compact
    end

    def enqueue_connection_cleanup
      return unless klutch_item

      KlutchConnectionCleanupJob.perform_later(
        klutch_item_id: klutch_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Klutch account #{id}, defaulting to USD")
    end
end
