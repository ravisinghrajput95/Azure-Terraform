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

  duration_minutes = {
    PT1M  = 1
    PT5M  = 5
    PT15M = 15
    PT30M = 30
    PT1H  = 60
    PT6H  = 360
    PT12H = 720
    P1D   = 1440
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
  ##############################################################################
  enabled_alert_count = length(local.enabled_alerts)

  indicative_monthly_cost_usd = local.enabled_alert_count * 0.10
}
