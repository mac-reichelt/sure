# frozen_string_literal: true

class KlutchItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Loan].freeze

  before_action :set_klutch_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @klutch_items = Current.family.klutch_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @klutch_item = Current.family.klutch_items.build
  end

  def edit
  end

  def create
    @klutch_item = Current.family.klutch_items.build(klutch_item_params)
    @klutch_item.name ||= "Klutch Connection"

    if @klutch_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Klutch.")
        @klutch_items = Current.family.klutch_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "klutch-providers-panel",
            partial: "settings/providers/klutch_panel",
            locals: { klutch_items: @klutch_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @klutch_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "klutch-providers-panel",
          partial: "settings/providers/klutch_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @klutch_item.update(klutch_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Klutch configuration.")
        @klutch_items = Current.family.klutch_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "klutch-providers-panel",
            partial: "settings/providers/klutch_panel",
            locals: { klutch_items: @klutch_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @klutch_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "klutch-providers-panel",
          partial: "settings/providers/klutch_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @klutch_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Klutch connection for deletion.")
  end

  def sync
    unless @klutch_item.syncing?
      @klutch_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    klutch_item = Current.family.klutch_items.first
    unless klutch_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "klutch_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    klutch_item.sync_later unless klutch_item.syncing?
    redirect_to select_accounts_klutch_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = url_from(params[:return_to])

    klutch_item = Current.family.klutch_items.first
    unless klutch_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "klutch_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    @klutch_accounts = klutch_item.klutch_accounts
                                  .left_joins(:account_provider)
                                  .where(account_providers: { id: nil })
                                  .order(:name)

    render layout: false if turbo_frame_request?
  end

  def link_accounts
    klutch_item = Current.family.klutch_items.first
    unless klutch_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "klutch_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_api_key")
      end
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_klutch_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type].presence || "CreditCard"
    created_count = 0

    klutch_item.klutch_accounts.where(id: selected_ids).find_each do |klutch_account|
      next if klutch_account.account_provider.present?
      next if klutch_account.name.blank?

      link_klutch_account(klutch_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "KlutchItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      klutch_item.sync_later unless klutch_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_klutch_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @klutch_item = Current.family.klutch_items.first

    unless @klutch_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "klutch_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    @klutch_accounts = @klutch_item.klutch_accounts
                                   .left_joins(:account_provider)
                                   .where(account_providers: { id: nil })
                                   .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    klutch_item = Current.family.klutch_items.first

    unless klutch_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "klutch_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_api_key")
      end
      return
    end

    klutch_account = klutch_item.klutch_accounts.find(params[:klutch_account_id])

    if klutch_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    klutch_account.ensure_account_provider!(account)
    klutch_item.sync_later unless klutch_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @klutch_item.unlinked_klutch_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    selected_ids = params[:selected_accounts] || []

    if selected_ids.empty?
      redirect_to setup_accounts_klutch_item_path(@klutch_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    @klutch_item.klutch_accounts.where(id: selected_ids).find_each do |klutch_account|
      next if klutch_account.account_provider.present?

      # Klutch connections are always credit cards
      account = link_klutch_account(klutch_account, "CreditCard")

      if account&.persisted?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "KlutchItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @klutch_item.sync_later unless @klutch_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_klutch_item_path(@klutch_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_klutch_item
      @klutch_item = Current.family.klutch_items.find(params[:id])
    end

    def klutch_item_params
      params.require(:klutch_item).permit(
        :name,
        :sync_start_date,
        :client_id,
        :secret_key,
        :base_url
      )
    end

    def link_klutch_account(klutch_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: klutch_account.name,
        balance: klutch_account.current_balance || 0,
        currency: klutch_account.currency || "USD",
        accountable: accountable_class.new
      )

      klutch_account.ensure_account_provider!(account)
      account
    end

    def validated_accountable_class(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type.constantize
    end
end
