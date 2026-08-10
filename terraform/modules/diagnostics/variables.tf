################################################################################
# Target
################################################################################

variable "target_resource_id" {
  description = "ARM resource ID of the resource to collect diagnostics from. Any resource type is accepted — the module discovers which log and metric categories that type supports rather than being told."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]+/", var.target_resource_id))
    error_message = "target_resource_id must be a full ARM resource ID beginning /subscriptions/<guid>/."
  }
}

variable "name" {
  description = "Name of the diagnostic setting. Diagnostic setting names must be unique per target resource, not globally, so a constant is safe and keeps addresses predictable across the estate."
  type        = string
  default     = "diag-to-law"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,258}[a-zA-Z0-9_]$", var.name))
    error_message = "Diagnostic setting names must be 2-260 characters and may not end with a hyphen or period."
  }
}

################################################################################
# Destinations
################################################################################

variable "log_analytics_workspace_id" {
  description = "Workspace to send diagnostics to, from the log-analytics module's id output."
  type        = string
}

variable "log_analytics_destination_type" {
  description = "\"Dedicated\" routes logs to resource-specific tables, which are typed, cheaper to query and the modern default. \"AzureDiagnostics\" routes everything into one legacy wide table. Null lets Azure choose the appropriate mode for the resource type — correct for a generic helper, because not every resource type supports Dedicated and forcing it fails the apply."
  type        = string
  default     = null

  validation {
    condition     = var.log_analytics_destination_type == null || contains(["Dedicated", "AzureDiagnostics"], coalesce(var.log_analytics_destination_type, "Dedicated"))
    error_message = "log_analytics_destination_type must be \"Dedicated\", \"AzureDiagnostics\" or null."
  }
}

variable "storage_account_id" {
  description = "Optional storage account for long-term archive alongside the workspace. Archiving to storage is materially cheaper than extended workspace retention for data that is kept for compliance and rarely queried."
  type        = string
  default     = null
}

################################################################################
# Category selection
################################################################################

variable "log_selection" {
  description = <<-EOT
    How log categories are chosen:

      "all"      Use the allLogs category group when the resource supports it,
                 so categories Azure adds later are collected automatically
                 without a code change. Falls back to enumerating every
                 discovered category when the resource has no allLogs group.

      "explicit" Enumerate each discovered category individually. Required if
                 excluded_log_categories is used, since a category group cannot
                 be partially excluded.

      "none"     Collect no logs. Metrics only.
  EOT
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "explicit", "none"], var.log_selection)
    error_message = "log_selection must be one of: all, explicit, none."
  }
}

variable "excluded_log_categories" {
  description = "Log categories to omit. Only meaningful with log_selection = \"explicit\", because a category group is all-or-nothing. Use for a genuinely high-volume, low-value category — the usual reason a workspace bill grows unexpectedly."
  type        = list(string)
  default     = []
}

variable "enable_metrics" {
  description = "Whether to collect platform metrics. Metrics are low volume relative to logs and are what most alert rules evaluate, so disabling them is rarely the right cost lever."
  type        = bool
  default     = true
}

variable "excluded_metric_categories" {
  description = "Metric categories to omit. Most resource types expose only \"AllMetrics\"."
  type        = list(string)
  default     = []
}
