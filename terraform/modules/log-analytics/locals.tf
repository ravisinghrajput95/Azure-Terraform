################################################################################
# Derived state
################################################################################

locals {
  ingestion_is_capped = var.daily_quota_gb != -1

  # Retention above the included 31 days is billed per GB per month on top of
  # ingestion. Surfaced as an output so a caller can see that a retention
  # change has a recurring cost consequence, not just a compliance one.
  retention_is_billable = var.retention_in_days > 31

  # Disabling a public endpoint without an Azure Monitor Private Link Scope
  # does not fail — it silently severs the path. Agents continue running and
  # report healthy while no data arrives. Caught by a precondition instead.
  public_access_partially_disabled = !var.internet_ingestion_enabled || !var.internet_query_enabled
}
