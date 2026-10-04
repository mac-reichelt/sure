class Provider::KlutchAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("KlutchAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_klutch?

    [ {
      key: "klutch",
      name: "Klutch",
      description: "Connect your Klutch card via the Klutch developer API",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_klutch_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_klutch_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "klutch"
  end

  # Build a Klutch provider instance with family-specific credentials.
  # Klutch is fully per-family — each family brings its own developer credentials.
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Klutch, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    klutch_item = family.klutch_items.where.not(client_id: nil).first
    return nil unless klutch_item&.credentials_configured?

    Provider::Klutch.new(
      client_id: klutch_item.client_id,
      secret_key: klutch_item.secret_key,
      base_url: klutch_item.effective_base_url
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_klutch_item_path(item)
  end

  def item
    provider_account.klutch_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Klutch account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return item&.institution_name unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return item&.institution_url unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
