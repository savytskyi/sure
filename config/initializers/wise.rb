# frozen_string_literal: true

Rails.configuration.x.wise.tap do |wise|
  wise.base_url = ENV.fetch("WISE_BASE_URL", "https://api.wise.com")
  wise.include_pending = ENV.fetch("WISE_INCLUDE_PENDING", "true") == "true"
  # Days re-read before the last fully collected point on incremental syncs.
  wise.overlap_days = ENV.fetch("WISE_SYNC_OVERLAP_DAYS", "14").to_i.clamp(1, 365)
  # Business <-> personal payments are income/expense by default (salary is
  # not a neutral transfer). "true" links both legs as a transfer instead.
  wise.link_own_profile_transfers = ENV.fetch("WISE_LINK_OWN_PROFILE_TRANSFERS", "false") == "true"
end
