################################################################################
# Placement
################################################################################

variable "action_group_name" {
  description = "Action group name, from naming.action_group. Lives in the monitoring resource group so it outlives the resources it observes."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"mon\" lifecycle scope, deliberately outside the app group so tearing down a dev app stack does not destroy its own alerting."
  type        = string
}

variable "location" {
  description = "Azure region for the metric alert rules. The action group itself is always global — Azure ignores a region on it — so this is only used where a region is genuinely required."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Notification
#
# An action group with no receivers is the module's worst silent failure: every
# alert rule evaluates correctly, fires correctly, resolves correctly, and
# tells nobody. Azure reports this as a healthy configuration.
################################################################################

variable "action_group_short_name" {
  description = "Short name shown as the SMS/email sender. Azure caps this at 12 characters and rejects anything longer at apply time."
  type        = string

  validation {
    condition     = length(var.action_group_short_name) > 0 && length(var.action_group_short_name) <= 12
    error_message = "action_group_short_name must be 1-12 characters; Azure rejects longer values."
  }
}

variable "email_receivers" {
  description = <<-EOT
    Map of receiver name to email address. Empty means alerts notify NOBODY —
    rejected by a precondition rather than deployed, because the resulting
    configuration looks entirely healthy in the portal.

    Common alert schema is used for every receiver so the payload shape does
    not depend on which alert type fired.
  EOT
  type        = map(string)
  default     = {}
}

variable "action_group_enabled" {
  description = "Whether the action group delivers notifications. False keeps the rules and the group in place but silences delivery — useful during an incident, dangerous if forgotten, so it is reported in an output."
  type        = bool
  default     = true
}

################################################################################
# Target
################################################################################

variable "cluster_id" {
  description = "Resource ID of the AKS cluster the metric alerts are scoped to."
  type        = string
}

variable "alert_name_prefix" {
  description = "Prefix for generated alert rule names, e.g. \"alrt-cloudcart-dev-cus\". Each rule appends its own key."
  type        = string
}

################################################################################
# Alert rules
#
# Defaults cover the health of a single-node, non-HA cluster. Every threshold
# is an input because the correct value depends on the node size and the
# workload, not on the module.
################################################################################

variable "metric_alerts" {
  description = <<-EOT
    Metric alert rules, keyed by a short stable name that becomes part of the
    rule's resource name. Keys must be statically known — they drive for_each.

    `metric_name` and every `dimension.name` are validated against the AKS
    metric catalogue in locals.tf, which was read from the Azure metric
    definitions API rather than from documentation. A rule naming a metric or
    dimension that does not exist is accepted by Azure and then never fires.

    Omitted optional fields fall back to the module defaults below.
  EOT

  type = map(object({
    metric_name = string
    aggregation = string
    operator    = string
    threshold   = number

    description   = optional(string)
    severity      = optional(number)
    frequency     = optional(string)
    window_size   = optional(string)
    enabled       = optional(bool, true)
    auto_mitigate = optional(bool, true)

    dimensions = optional(map(object({
      operator = optional(string, "Include")
      values   = list(string)
    })), {})
  }))

  default = {
    node-not-ready = {
      metric_name = "kube_node_status_condition"
      aggregation = "Total"
      operator    = "GreaterThan"
      threshold   = 0
      severity    = 0
      description = "A node has been reporting NotReady. On a single-node cluster this is a total outage, not a degradation."

      dimensions = {
        condition = { values = ["Ready"] }
        status    = { values = ["false", "unknown"] }
      }
    }

    node-cpu-high = {
      metric_name = "node_cpu_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      description = "Sustained node CPU above 85%. Pods are being throttled before this becomes visible as an outage."
    }

    node-memory-high = {
      metric_name = "node_memory_working_set_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      description = "Sustained node memory above 85%. The kubelet begins evicting pods under memory pressure well before the node fails."
    }

    node-disk-high = {
      metric_name = "node_disk_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      description = "Node disk above 85%. Disk pressure taints the node and evicts pods, and image pulls start failing."
    }

    pods-failed = {
      metric_name = "kube_pod_status_phase"
      aggregation = "Total"
      operator    = "GreaterThan"
      threshold   = 0
      severity    = 2
      description = "Pods in the Failed phase. Distinguishes a genuine workload failure from the pending state a full node produces."

      dimensions = {
        phase = { values = ["Failed"] }
      }
    }

    pods-pending = {
      metric_name = "kube_pod_status_phase"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 0
      severity    = 2
      description = "Pods stuck Pending. On a capacity-constrained cluster the cause is usually the vCPU quota rather than a workload defect, and no amount of waiting resolves it. NOT cluster_autoscaler_unschedulable_pods_count, which publishes nothing at all unless the cluster autoscaler is running."

      dimensions = {
        phase = { values = ["Pending"] }
      }
    }

    apiserver-cpu-high = {
      metric_name = "apiserver_cpu_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 90
      severity    = 1
      description = "API server CPU above 90%. The Free SKU tier carries NO control-plane SLA, so there is no recourse other than reducing load or upgrading the tier."
    }

    etcd-database-high = {
      metric_name = "etcd_database_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 1
      description = "etcd database above 85%. A full etcd puts the cluster into read-only and is materially harder to recover from than to prevent."
    }
  }
}

variable "threshold_overrides" {
  description = <<-EOT
    Per-rule threshold overrides, keyed by the same key as `metric_alerts`.

    Thresholds are the most environment-specific part of an alert rule, and the
    correct value is a measured property of the cluster rather than a module
    default. A rule whose threshold sits below the environment's steady state
    fires permanently, which disables it as surely as never firing at all —
    the failure is just louder.

    Keys that match no rule are rejected, since a typo here silently leaves the
    default threshold in place.
  EOT
  type        = map(number)
  default     = {}
}

variable "cluster_autoscaler_enabled" {
  description = <<-EOT
    Whether the cluster autoscaler runs on this cluster.

    The `cluster_autoscaler_*` metrics exist on every AKS cluster and are
    accepted by every alert rule, but the component only PUBLISHES them when
    autoscaling is actually enabled on a node pool. With it off, a rule on one
    of those metrics receives no data, never fires, and reports no error — the
    catalogue check cannot catch it, because the metric genuinely exists.
  EOT
  type        = bool
  default     = false
}

################################################################################
# Log Analytics daily cap alert
#
# A capability flag and its inputs, not an environment branch. The module never
# learns which environment it is in.
#
# When a workspace hits its daily ingestion cap, collection STOPS for the rest
# of the UTC day and the dropped telemetry is gone — it is not queued, not
# backfilled, and not recoverable by raising the cap afterwards. Every other
# alert rule in this module goes blind at the same moment, because the metrics
# they watch stop arriving.
################################################################################

variable "enable_daily_cap_alert" {
  description = <<-EOT
    Whether to deploy the Log Analytics daily-cap alert.

    A capability flag. Environments that do not cap ingestion do not need it,
    and deploying it there produces a rule that can never fire — see
    `log_analytics_daily_quota_gb`.
  EOT
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Full ARM resource ID of the workspace to watch. Required when enable_daily_cap_alert is true. This is the scope the log query runs against."
  type        = string
  default     = null
}

variable "log_analytics_daily_quota_gb" {
  description = <<-EOT
    The workspace's configured daily cap in GB, or -1 when uncapped.

    Passed in rather than read from the workspace so that the precondition can
    evaluate at PLAN time. An uncapped workspace never emits the OverQuota
    event, so the rule would be created, display as healthy, and never fire.
  EOT
  type        = number
  default     = -1
}

variable "daily_cap_alert_severity" {
  description = "Severity for the daily-cap rule. Defaults to 1 (Error): the data is already being dropped by the time this fires, and every other rule in this module is blind until the cap resets."
  type        = number
  default     = 1

  validation {
    condition     = var.daily_cap_alert_severity >= 0 && var.daily_cap_alert_severity <= 4
    error_message = "Severity must be between 0 (Critical) and 4 (Verbose)."
  }
}

variable "daily_cap_alert_evaluation_frequency" {
  description = "How often the log query runs, ISO 8601. Log search alerts bill per rule, and more frequent evaluation costs more."
  type        = string
  default     = "PT15M"

  validation {
    condition     = contains(["PT5M", "PT10M", "PT15M", "PT30M", "PT1H"], var.daily_cap_alert_evaluation_frequency)
    error_message = "daily_cap_alert_evaluation_frequency must be one of PT5M, PT10M, PT15M, PT30M, PT1H."
  }
}

variable "daily_cap_alert_window_duration" {
  description = <<-EOT
    Lookback window each evaluation considers, ISO 8601.

    Deliberately LONGER than the evaluation frequency. The OverQuota record
    appears once, and its TimeGenerated is when the cap was hit, not when the
    row became queryable — ingestion latency sits between the two. A window
    equal to the frequency can step past a late-arriving row and miss the only
    notification there will be that day.
  EOT
  type        = string
  default     = "PT1H"

  validation {
    condition     = contains(["PT15M", "PT30M", "PT1H", "PT6H", "PT12H", "P1D", "P2D"], var.daily_cap_alert_window_duration)
    error_message = "daily_cap_alert_window_duration must be one of PT15M, PT30M, PT1H, PT6H, PT12H, P1D, P2D. Azure caps the window at 2 days."
  }
}

variable "daily_cap_alert_mute_duration" {
  description = <<-EOT
    How long to suppress repeat notifications after the rule fires, ISO 8601.

    A window longer than the evaluation frequency means the same OverQuota row
    is matched by several consecutive evaluations. Without muting, one cap hit
    produces a stream of identical alerts until the row falls out of the window.
    The cap resets once per UTC day, so muting for hours loses nothing.
  EOT
  type        = string
  default     = "PT6H"

  validation {
    condition     = contains(["PT5M", "PT10M", "PT15M", "PT30M", "PT1H", "PT6H", "PT12H", "P1D"], var.daily_cap_alert_mute_duration)
    error_message = "daily_cap_alert_mute_duration must be one of PT5M, PT10M, PT15M, PT30M, PT1H, PT6H, PT12H, P1D."
  }
}

################################################################################
# Daily cap WARNING alert
#
# The rule above fires when the cap is HIT, which is after data has already
# been lost. This one fires while there is still time to act.
################################################################################

variable "enable_daily_cap_warning_alert" {
  description = <<-EOT
    Whether to deploy the "approaching the daily cap" warning.

    Independent of `enable_daily_cap_alert` — they answer different questions,
    and either is useful without the other. Both require a capped workspace.
  EOT
  type        = bool
  default     = false
}

variable "daily_cap_warning_percent" {
  description = <<-EOT
    Percentage of the daily cap at which to warn.

    Must be below 100. At or above 100 the warning fires only once the cap has
    already been hit, which is what the other rule is for, and leaves this one
    contributing nothing but a duplicate notification.
  EOT
  type        = number
  default     = 80

  validation {
    condition     = var.daily_cap_warning_percent > 0 && var.daily_cap_warning_percent < 100
    error_message = "daily_cap_warning_percent must be between 1 and 99. At 100 or above the warning arrives after the data is already lost; at 0 or below it fires permanently."
  }
}

variable "daily_cap_reset_hour_utc" {
  description = <<-EOT
    The UTC hour at which the workspace's daily cap resets. NO DEFAULT — it
    must be read from the workspace and stated explicitly:

      az monitor log-analytics workspace show -g <rg> -n <name> \
        --query workspaceCapping.quotaNextResetTime -o tsv

    The cap counts data ingested since the last reset, so this value defines
    the window the warning query sums over. It is NOT midnight everywhere: this
    platform's workspace resets at 11:00 UTC. A wrong value produces a query
    that sums the wrong period, and one that is too late in the day sums a
    window that has barely started — so the total stays near zero and the
    warning never fires. Azure accepts the query either way.

    There is no way to check this at plan time, which is why it has no default
    to fall back to silently.
  EOT
  type        = number
  default     = null

  validation {
    # coalesce, not a bare comparison, because `||` does not reliably
    # short-circuit here. On Terraform 1.9.8 — the version CI pins — the
    # right-hand side is evaluated even when the left is true, so a null
    # reaches `>=` and validation fails outright with "argument must not be
    # null". It is not a validation failure the user can act on; it is an
    # evaluation error that stops `terraform validate` dead.
    #
    # This is why qa, stage and prod could not validate: dev supplies an hour,
    # the other three leave it null. Newer Terraform short-circuits and hides
    # it, which is exactly how it survived — see the aks, firewall, diagnostics
    # and private-dns modules, which already coalesce for the same reason.
    condition = var.daily_cap_reset_hour_utc == null || (
      coalesce(var.daily_cap_reset_hour_utc, 0) >= 0 &&
      coalesce(var.daily_cap_reset_hour_utc, 0) <= 23
    )
    error_message = "daily_cap_reset_hour_utc must be an hour from 0 to 23."
  }
}

variable "daily_cap_warning_evaluation_frequency" {
  description = "How often the warning query runs. The Usage table is written hourly, so evaluating much more often than that costs money without detecting anything sooner."
  type        = string
  default     = "PT15M"

  validation {
    condition     = contains(["PT5M", "PT10M", "PT15M", "PT30M", "PT1H"], var.daily_cap_warning_evaluation_frequency)
    error_message = "daily_cap_warning_evaluation_frequency must be one of PT5M, PT10M, PT15M, PT30M, PT1H."
  }
}

variable "daily_cap_warning_window_duration" {
  description = <<-EOT
    Lookback window for the warning query. Must be at least P1D.

    The query sums everything ingested since the last reset, which is up to 24
    hours ago. The window is the rule's outer time filter, so a window shorter
    than the cap period CLIPS the sum: the total comes out low, the threshold
    is never reached, and the rule never fires while the workspace sails past
    its cap. Azure accepts it and reports the rule healthy.
  EOT
  type        = string
  default     = "P1D"

  validation {
    condition     = contains(["P1D", "P2D"], var.daily_cap_warning_window_duration)
    error_message = "daily_cap_warning_window_duration must be P1D or P2D. Anything shorter clips the cap period and the rule silently never fires; Azure caps the window at 2 days."
  }
}

# There is deliberately no daily_cap_warning_mute_duration. Azure rejects a
# mute duration alongside auto-mitigation — "auto mitigation must be disabled
# when mute action duration is set" — and the warning rule uses auto-mitigation,
# which makes it stateful: it notifies once and resolves itself when the cap
# period rolls over. Muting is the alternative for stateless rules, and it is
# what the cap-HIT rule uses instead.

variable "daily_cap_warning_severity" {
  description = "Severity for the warning. Defaults to 2 (Warning): unlike the cap-hit rule, nothing has been lost yet and there is still time to act."
  type        = number
  default     = 2

  validation {
    condition     = var.daily_cap_warning_severity >= 0 && var.daily_cap_warning_severity <= 4
    error_message = "Severity must be between 0 (Critical) and 4 (Verbose)."
  }
}

################################################################################
# Rule defaults
################################################################################

variable "default_severity" {
  description = "Severity for rules that do not set one. 0 Critical, 1 Error, 2 Warning, 3 Informational, 4 Verbose."
  type        = number
  default     = 2

  validation {
    condition     = var.default_severity >= 0 && var.default_severity <= 4
    error_message = "Severity must be between 0 (Critical) and 4 (Verbose)."
  }
}

variable "default_frequency" {
  description = "How often rules are evaluated, ISO 8601. Shorter frequencies cost more because billing is per evaluated time series."
  type        = string
  default     = "PT5M"

  validation {
    condition     = contains(["PT1M", "PT5M", "PT15M", "PT30M", "PT1H"], var.default_frequency)
    error_message = "default_frequency must be one of PT1M, PT5M, PT15M, PT30M, PT1H."
  }
}

variable "default_window_size" {
  description = "Lookback window each evaluation considers, ISO 8601. Must be at least the frequency, or Azure rejects the rule."
  type        = string
  default     = "PT15M"

  validation {
    condition     = contains(["PT1M", "PT5M", "PT15M", "PT30M", "PT1H", "PT6H", "PT12H", "P1D"], var.default_window_size)
    error_message = "default_window_size must be one of PT1M, PT5M, PT15M, PT30M, PT1H, PT6H, PT12H, P1D."
  }
}
