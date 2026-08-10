################################################################################
# Placement
################################################################################

variable "name" {
  description = "Workspace name, from the naming module's names.log_analytics_workspace."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{2,61}[a-zA-Z0-9]$", var.name))
    error_message = "Log Analytics workspace names must be 4-63 characters, alphanumerics and hyphens, and may not start or end with a hyphen."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the workspace in. This should be the monitoring scope, deliberately separate from the application group so that tearing down an app stack does not destroy its own audit trail."
  type        = string
}

variable "location" {
  description = "Azure region, normalised form."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Capacity and retention
################################################################################

variable "sku" {
  description = "Pricing tier. PerGB2018 is the current pay-as-you-go tier and the only one appropriate for a new workspace — the legacy Free, Standalone, PerNode and Standard tiers are retired for new deployments. CapacityReservation trades a daily commitment for a lower unit rate and only pays off above roughly 100 GB/day."
  type        = string
  default     = "PerGB2018"

  validation {
    condition     = contains(["PerGB2018", "CapacityReservation", "LACluster"], var.sku)
    error_message = "sku must be PerGB2018, CapacityReservation or LACluster. The legacy Free, Standalone, PerNode and Standard tiers are not available for new workspaces."
  }
}

variable "retention_in_days" {
  description = "Interactive retention. Pass the profile module's log_retention_days. The first 31 days are included at no additional charge on PerGB2018, so 30 is the free choice and anything above it is billed per GB per month."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "retention_in_days must be between 30 and 730."
  }
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB, or -1 for uncapped. Pass the profile module's log_daily_quota_gb. WARNING: when the cap is reached, ingestion STOPS for the rest of the UTC day and the dropped data is not recoverable — including security signals. Appropriate in dev to protect a free-tier allowance; never in production."
  type        = number
  default     = -1

  validation {
    condition     = var.daily_quota_gb == -1 || var.daily_quota_gb >= 0.023
    error_message = "daily_quota_gb must be -1 (uncapped) or at least 0.023, which is the minimum daily cap Azure accepts."
  }
}

################################################################################
# Network exposure
#
# Both default to true because disabling them requires an Azure Monitor Private
# Link Scope (AMPLS) to be in place first. Turning either off without an AMPLS
# silently severs ingestion — agents keep running and no data arrives.
#
# AMPLS is the correct hardening step for production and is deferred to its own
# module rather than half-implemented here.
################################################################################

variable "internet_ingestion_enabled" {
  description = "Whether agents may send data over the public endpoint. Set false ONLY once an Azure Monitor Private Link Scope covers this workspace, otherwise ingestion stops silently."
  type        = bool
  default     = true
}

variable "internet_query_enabled" {
  description = "Whether the workspace may be queried over the public endpoint. Set false ONLY with an AMPLS in place, otherwise the portal and every query tool lose access."
  type        = bool
  default     = true
}

variable "local_authentication_enabled" {
  description = "Whether shared-key ingestion is permitted. Setting false forces Entra ID authentication, which is the correct posture — Azure Monitor Agent authenticates with a managed identity through Data Collection Rules and never needs the workspace key. Left true by default because any legacy component still using the key breaks the moment it is disabled. Note this is the positive form; the older `local_authentication_disabled` argument is deprecated and removed in azurerm v5."
  type        = bool
  default     = true
}

variable "private_link_scope_configured" {
  description = "Assert that an Azure Monitor Private Link Scope (AMPLS) covers this workspace. Required before either public endpoint may be disabled. Set true only when an AMPLS genuinely exists — disabling a public endpoint without one severs the data path silently."
  type        = bool
  default     = false
}

variable "allow_resource_only_permissions" {
  description = "Whether a principal with read access to a resource can read that resource's logs without workspace-level permissions. Keeping this true supports least privilege: an application team reads its own logs without being granted the whole workspace."
  type        = bool
  default     = true
}

################################################################################
# Identity
################################################################################

variable "enable_system_assigned_identity" {
  description = "Attach a system-assigned managed identity. Required for customer-managed key encryption and for the workspace to authenticate outbound to other services. Costs nothing when unused."
  type        = bool
  default     = true
}
