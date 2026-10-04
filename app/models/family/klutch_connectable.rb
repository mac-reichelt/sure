module Family::KlutchConnectable
  extend ActiveSupport::Concern

  included do
    has_many :klutch_items, dependent: :destroy
  end

  def can_connect_klutch?
    # Families configure their own Klutch developer credentials
    true
  end

  def create_klutch_item!(client_id:, secret_key:, base_url: nil, item_name: nil)
    klutch_item = klutch_items.create!(
      name: item_name || "Klutch Connection",
      client_id: client_id,
      secret_key: secret_key,
      base_url: base_url
    )

    klutch_item.sync_later

    klutch_item
  end

  def has_klutch_credentials?
    klutch_items.where.not(client_id: nil).exists?
  end
end
