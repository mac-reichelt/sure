# frozen_string_literal: true

module KlutchItem::Provided
  extend ActiveSupport::Concern

  def klutch_provider
    return nil unless credentials_configured?

    Provider::Klutch.new(
      client_id: client_id,
      secret_key: secret_key,
      base_url: effective_base_url
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def klutch_credentials
    return nil unless credentials_configured?

    {
      client_id: client_id,
      secret_key: secret_key
    }
  end
end
