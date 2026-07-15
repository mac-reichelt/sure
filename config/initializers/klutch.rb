# Klutch integration runtime configuration
Rails.application.configure do
  # Controls whether pending transactions are included in Klutch syncs
  # When true, adds PENDING to the transactionStatus filter on fetch requests
  # Default: false (only settled transactions)
  config.x.klutch.include_pending = ENV["KLUTCH_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes])

  # Debug logging for raw Klutch API responses
  # When enabled, logs the full raw JSON payload from the Klutch GraphQL API
  # Default: false (only log summary info)
  config.x.klutch.debug_raw = ENV["KLUTCH_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
