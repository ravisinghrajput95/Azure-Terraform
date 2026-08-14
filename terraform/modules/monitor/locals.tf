################################################################################
# AKS metric catalogue
#
# Read from the Azure metric definitions API against a live cluster, not from
# documentation:
#
#   az monitor metrics list-definitions --resource <cluster id>
#
# This table exists because of how Azure fails here. A metric alert naming a
# metric that does not exist, an aggregation the metric does not support, or a
# dimension it does not carry is ACCEPTED. The rule is created, shows as
# healthy in the portal, and never fires. There is no error to find, and the
# gap is only discovered when an incident goes unalerted.
#
# All are free platform metrics — none of them require Container Insights or
# managed Prometheus, so alerting on them adds no ingestion cost.
################################################################################

locals {
  aks_metric_catalogue = {
    apiserver_cpu_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = []
    }
    apiserver_current_inflight_requests = {
      aggregations = ["Total", "Average"]
      dimensions   = ["requestKind"]
    }
    apiserver_flowcontrol_executing_seats = {
      aggregations = ["Total", "Average"]
      dimensions   = ["priority_level"]
    }
    apiserver_memory_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = []
    }
    cluster_autoscaler_cluster_safe_to_autoscale = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    cluster_autoscaler_scale_down_in_cooldown = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    cluster_autoscaler_unneeded_nodes_count = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    cluster_autoscaler_unschedulable_pods_count = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    etcd_cpu_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["partition"]
    }
    etcd_database_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["partition"]
    }
    etcd_memory_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["partition"]
    }
    kube_node_status_allocatable_cpu_cores = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    kube_node_status_allocatable_memory_bytes = {
      aggregations = ["Total", "Average"]
      dimensions   = []
    }
    kube_node_status_condition = {
      aggregations = ["Total", "Average"]
      dimensions   = ["condition", "node", "status", "status2"]
    }
    kube_pod_status_phase = {
      aggregations = ["Total", "Average"]
      dimensions   = ["namespace", "phase", "pod"]
    }
    kube_pod_status_ready = {
      aggregations = ["Total", "Average"]
      dimensions   = ["condition", "namespace", "pod"]
    }
    node_cpu_usage_millicores = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_cpu_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_disk_usage_bytes = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["device", "node", "nodepool"]
    }
    node_disk_usage_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["device", "node", "nodepool"]
    }
    node_memory_rss_bytes = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_memory_rss_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_memory_working_set_bytes = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_memory_working_set_percentage = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_network_in_bytes = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    node_network_out_bytes = {
      aggregations = ["Maximum", "Average"]
      dimensions   = ["node", "nodepool"]
    }
    scheduler_schedule_attempts_rate = {
      aggregations = ["Average"]
      dimensions   = ["result"]
    }
  }

  metric_namespace = "Microsoft.ContainerService/managedClusters"
}

################################################################################
# Effective rule configuration
#
# Module defaults are resolved here rather than inline so that every
# precondition below validates the values actually sent to Azure.
################################################################################

locals {
  alerts = {
    for key, a in var.metric_alerts : key => {
      metric_name   = a.metric_name
      aggregation   = a.aggregation
      operator      = a.operator
      threshold     = lookup(var.threshold_overrides, key, a.threshold)
      description   = coalesce(a.description, "AKS ${a.metric_name} ${a.operator} ${a.threshold}.")
      severity      = a.severity != null ? a.severity : var.default_severity
      frequency     = coalesce(a.frequency, var.default_frequency)
      window_size   = coalesce(a.window_size, var.default_window_size)
      enabled       = a.enabled
      auto_mitigate = a.auto_mitigate
      dimensions    = a.dimensions
    }
  }

  enabled_alerts  = { for k, a in local.alerts : k => a if a.enabled }
  disabled_alerts = sort([for k, a in local.alerts : k if !a.enabled])
}

################################################################################
# Coherence checks
#
# Every one of these describes a configuration Azure ACCEPTS and then fails to
# act on. None of them produce an error at apply time.
################################################################################

locals {
  # An action group with no receivers. Rules fire, resolve, and notify nobody.
  no_receivers = length(var.email_receivers) == 0

  # A metric that does not exist on this resource type. The rule never fires.
  unknown_metrics = sort([
    for k, a in local.alerts : "${k} (${a.metric_name})"
    if !contains(keys(local.aks_metric_catalogue), a.metric_name)
  ])

  # An aggregation the metric does not publish. The rule never fires.
  unsupported_aggregations = sort([
    for k, a in local.alerts : "${k} (${a.aggregation} on ${a.metric_name})"
    if contains(keys(local.aks_metric_catalogue), a.metric_name)
    && !contains(local.aks_metric_catalogue[a.metric_name].aggregations, a.aggregation)
  ])

  # A dimension the metric does not carry. The filter matches nothing, so the
  # rule never fires — the most deceptive of the three, because the rule looks
  # more precisely targeted than an unfiltered one.
  invalid_dimensions = sort(flatten([
    for k, a in local.alerts : [
      for dim_name, dim in a.dimensions : "${k} (${dim_name} on ${a.metric_name})"
      if contains(keys(local.aks_metric_catalogue), a.metric_name)
      && !contains(local.aks_metric_catalogue[a.metric_name].dimensions, dim_name)
    ]
  ]))

  # Metrics that exist on every cluster but are only PUBLISHED when the
  # component producing them is running. The catalogue cannot catch these —
  # the metric name, aggregation and dimensions are all genuinely valid — so
  # the dependency is declared instead.
  autoscaler_dependent_metrics = [
    "cluster_autoscaler_cluster_safe_to_autoscale",
    "cluster_autoscaler_scale_down_in_cooldown",
    "cluster_autoscaler_unneeded_nodes_count",
    "cluster_autoscaler_unschedulable_pods_count",
  ]

  autoscaler_metrics_without_autoscaler = var.cluster_autoscaler_enabled ? [] : sort([
    for k, a in local.alerts : "${k} (${a.metric_name})"
    if contains(local.autoscaler_dependent_metrics, a.metric_name)
  ])

  # A threshold override that matches no rule leaves the default silently in
  # place, which is indistinguishable from the override having been applied.
  unknown_threshold_overrides = sort([
    for k, _ in var.threshold_overrides : k
    if !contains(keys(var.metric_alerts), k)
  ])

  # Every duration accepted by any variable in this module must appear here.
  # lookup() falls back to 0 for a missing key, which would make the window
  # comparisons below silently pass rather than fail.
  duration_minutes = {
    PT1M  = 1
    PT5M  = 5
    PT10M = 10
    PT15M = 15
    PT30M = 30
    PT1H  = 60
    PT6H  = 360
    PT12H = 720
    P1D   = 1440
    P2D   = 2880
  }

  # Azure rejects a window shorter than the evaluation frequency, but names
  # neither value in the error.
  windows_shorter_than_frequency = sort([
    for k, a in local.alerts : "${k} (window ${a.window_size} < frequency ${a.frequency})"
    if lookup(local.duration_minutes, a.window_size, 0) < lookup(local.duration_minutes, a.frequency, 0)
  ])

  # Every rule disabled is a deployed alerting stack that observes nothing.
  # Legitimate during an incident, so it is surfaced rather than rejected.
  all_alerts_disabled = length(local.alerts) > 0 && length(local.enabled_alerts) == 0

  ##############################################################################
  # Indicative cost
  #
  # Metric alerts bill per evaluated TIME SERIES, not per rule. A rule with no
  # dimension filter is one series; splitting by a dimension multiplies it by
  # the number of values that dimension takes. This counts rules, so it is a
  # floor rather than an estimate wherever dimensions are used.
  #
  # The log search alert is priced differently again — per rule, per evaluation
  # frequency — so it is added as a separate term rather than folded in.
  ##############################################################################
  enabled_alert_count = length(local.enabled_alerts)

  log_search_alert_count = (var.enable_daily_cap_alert ? 1 : 0) + (var.enable_daily_cap_warning_alert ? 1 : 0)

  indicative_monthly_cost_usd = (local.enabled_alert_count * 0.10) + (local.log_search_alert_count * 0.50)
}

################################################################################
# Log Analytics daily cap alert
#
# THE QUERY IS NOT THE ONE MICROSOFT DOCUMENTS, AND THAT IS DELIBERATE.
#
# The documented form filters on the Operation column:
#
#   _LogOperation
#   | where Category =~ "Ingestion"
#   | where Operation =~ "Data collection Status"   <-- matches NOTHING here
#   | where Detail contains "OverQuota"
#
# On this platform's workspace the Operation column holds a GUID, not that
# string. Verified against the live workspace on 2026-08-14, on a day the cap
# had genuinely been hit:
#
#   Category  Operation                             Detail
#   Ingestion 995abe77-99ad-4625-9b17-10f3023cc330  "Data collection stopped due
#                                                    to daily limit of free data
#                                                    reached. Ingestion status =
#                                                    OverQuota"
#
# The documented query returned 0 rows against that same record; the query
# below returned 1. A rule built on the documented form is accepted by Azure,
# passes query validation because the syntax is valid and the table exists,
# displays as healthy, and never fires — while the workspace silently drops
# data. This is the exact failure mode this module exists to prevent, and it is
# why the query is fixed in the module rather than exposed as a variable for a
# caller to "correct" back to the documented version.
#
# Filtering is on Category and Detail only. Level is not filtered: it carries
# "Warning" today, and narrowing on it buys nothing while adding one more
# column whose values can change.
################################################################################

locals {
  daily_cap_query = <<-KQL
    _LogOperation
    | where Category =~ "Ingestion"
    | where Detail has "OverQuota"
  KQL

  # A workspace with no cap cannot emit the event this rule matches, so the
  # rule is created, validates, displays as healthy and never fires. -1 is the
  # uncapped sentinel; 0 and negatives other than -1 are not valid caps either.
  workspace_is_uncapped = var.log_analytics_daily_quota_gb <= 0

  daily_cap_alert_without_cap = var.enable_daily_cap_alert && local.workspace_is_uncapped

  # The rule needs something to scope to. Null here fails at apply with an
  # error naming the API path rather than the variable.
  daily_cap_alert_without_workspace = var.enable_daily_cap_alert && (
    var.log_analytics_workspace_id == null || var.log_analytics_workspace_id == ""
  )

  # Azure rejects a window shorter than the evaluation frequency. It is also a
  # correctness problem here specifically: see the window variable's docs.
  daily_cap_window_shorter_than_frequency = var.enable_daily_cap_alert && (
    lookup(local.duration_minutes, var.daily_cap_alert_window_duration, 0) <
    lookup(local.duration_minutes, var.daily_cap_alert_evaluation_frequency, 0)
  )
}

################################################################################
# Daily cap WARNING query
#
# Fires while there is still time to act, rather than once the data is gone.
#
# THREE THINGS HERE WERE MEASURED AGAINST THE LIVE WORKSPACE, NOT ASSUMED.
# All three are silent if wrong: the query stays valid, the rule stays healthy,
# and the total simply comes out wrong.
#
#   1. The period starts at the CAP RESET HOUR, not midnight, and not 24h ago.
#      This workspace resets at 11:00 UTC. A rolling ago(24h) window spans two
#      cap periods and over-counts; startofday() under-counts for the 11 hours
#      after midnight. Read the real value from:
#        az monitor log-analytics workspace show ... \
#          --query workspaceCapping.quotaNextResetTime
#
#   2. Filter and bin on EndTime, NOT TimeGenerated. EndTime is the usage
#      period the quantity belongs to; TimeGenerated is when the summary row
#      was written, and the two diverge under ingestion latency — which is
#      exactly the moment the number matters.
#
#   3. A GB is 1024 MB here. Usage.Quantity is in MB and dailyQuotaGb is in GB.
#      Dividing by 1000 reports ~2.4% low, which is enough to push an 80%
#      warning past the cap it was meant to precede.
#
# Reconciled against the real cap hit of 2026-08-13. Summing billable Usage by
# EndTime from 11:00 UTC gives 439.05 MB (85.8% of 0.5 GB) at 21:00 and 544.20
# MB (106%) at 22:00; Azure recorded OverQuota at 21:44. An 80% rule would have
# fired at the 21:00 record, roughly 44 minutes before ingestion stopped.
#
# The measure is a PERCENTAGE rather than an absolute size, so the rule's
# threshold reads as "80" in the portal and does not have to be recomputed if
# the cap changes.
################################################################################

locals {
  daily_cap_warning_query = <<-KQL
    let capGB = ${var.log_analytics_daily_quota_gb};
    let resetHour = ${coalesce(var.daily_cap_reset_hour_utc, 0)}h;
    let periodStart = iff(
        now() - startofday(now()) >= resetHour,
        startofday(now()) + resetHour,
        startofday(now() - 1d) + resetHour
    );
    Usage
    | where IsBillable == true
    | where EndTime > periodStart
    | summarize IngestedMB = sum(Quantity)
    | extend PercentOfDailyCap = IngestedMB / 1024.0 / capGB * 100.0
    | project PercentOfDailyCap
  KQL

  daily_cap_warning_without_cap = var.enable_daily_cap_warning_alert && local.workspace_is_uncapped

  daily_cap_warning_without_workspace = var.enable_daily_cap_warning_alert && (
    var.log_analytics_workspace_id == null || var.log_analytics_workspace_id == ""
  )

  # No default to fall back on, because a wrong reset hour cannot be detected
  # at plan time and produces a rule that quietly sums the wrong window.
  daily_cap_warning_without_reset_hour = var.enable_daily_cap_warning_alert && var.daily_cap_reset_hour_utc == null

  # The window is the rule's outer time filter. Shorter than the cap period and
  # the sum is clipped, so the threshold is never reached.
  daily_cap_warning_window_too_short = var.enable_daily_cap_warning_alert && (
    lookup(local.duration_minutes, var.daily_cap_warning_window_duration, 0) < 1440
  )
}
