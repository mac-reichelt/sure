# frozen_string_literal: true

class KlutchConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(klutch_item_id:, account_id:)
    Rails.logger.info(
      "KlutchConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    klutch_item = KlutchItem.find_by(id: klutch_item_id)
    return unless klutch_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("KlutchConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "KlutchConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
