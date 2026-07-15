# frozen_string_literal: true

class CreateKlutchItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :klutch_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # Provider-specific credential fields (Klutch / AlloyCard GraphQL API)
      t.text :client_id
      t.text :secret_key
      t.string :base_url

      t.timestamps
    end

    add_index :klutch_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :klutch_accounts, id: :uuid do |t|
      t.references :klutch_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :klutch_account_id
      t.string :account_number

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :klutch_accounts, :klutch_account_id, unique: true
  end
end
