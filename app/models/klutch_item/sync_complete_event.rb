# frozen_string_literal: true

# Broadcasts UI updates after a Klutch item finishes syncing.
# Resolved by Syncable#sync_broadcaster as self.class::SyncCompleteEvent.
class KlutchItem::SyncCompleteEvent
  attr_reader :klutch_item

  def initialize(klutch_item)
    @klutch_item = klutch_item
  end

  def broadcast
    # Update UI with latest account data
    klutch_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    klutch_item.family.broadcast_sync_complete
  end
end
