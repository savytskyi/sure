# frozen_string_literal: true

Rails.configuration.x.wise.tap do |wise|
  wise.base_url = ENV.fetch("WISE_BASE_URL", "https://api.wise.com")
  # Days re-read before the last fully collected point on incremental syncs.
  wise.overlap_days = ENV.fetch("WISE_SYNC_OVERLAP_DAYS", "14").to_i.clamp(1, 365)
  # Every refresh_interval_days, the last refresh_days are re-read in full so
  # late cancellations, refunds and reversals reach the ledger.
  wise.refresh_days = ENV.fetch("WISE_SYNC_REFRESH_DAYS", "120").to_i.clamp(14, 730)
  wise.refresh_interval_days = ENV.fetch("WISE_SYNC_REFRESH_INTERVAL_DAYS", "7").to_i.clamp(1, 90)
  # Quote and recipient requests per sync. A large first backfill continues
  # on the next sync instead of hammering Wise's rate limit.
  wise.detail_requests_per_sync = ENV.fetch("WISE_DETAIL_REQUESTS_PER_SYNC", "400").to_i.clamp(10, 10_000)
  # Business <-> personal payments are income/expense by default (salary is
  # not a neutral transfer). "true" links both legs as a transfer instead.
  wise.link_own_profile_transfers = ENV.fetch("WISE_LINK_OWN_PROFILE_TRANSFERS", "false") == "true"
end
