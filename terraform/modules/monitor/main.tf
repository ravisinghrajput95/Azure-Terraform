################################################################################
# Action group
#
# Lives in the monitoring resource group, deliberately outside the app group,
# so tearing down a dev app stack does not destroy the thing that would have
# told you it went down.
#
# The location is always "global". Action groups are not regional resources and
# Azure silently normalises anything else, which makes a regional value look
# meaningful in the configuration when it is not.
################################################################################

resource "azurerm_monitor_action_group" "this" {
  name                = var.action_group_name
  resource_group_name = var.resource_group_name
  short_name          = var.action_group_short_name
  enabled             = var.action_group_enabled

  dynamic "email_receiver" {
    for_each = var.email_receivers

    content {
      name          = email_receiver.key
      email_address = email_receiver.value

      # Without this, the payload shape depends on which alert type fired,
      # so anything parsing it has to handle several schemas.
      use_common_alert_schema = true
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.no_receivers
      error_message = join(" ", [
        "email_receivers is empty.",
        "The action group would be created successfully and every alert rule would evaluate, fire and resolve correctly while notifying NOBODY.",
        "Azure reports this as a healthy configuration and the portal shows the rules as enabled,",
        "so the gap is discovered only when an incident passes unnoticed.",
        "Supply at least one receiver, or do not deploy the module."
      ])
    }
  }
}

################################################################################
# AKS metric alert rules
#
# for_each is over a statically-known map from variables. It must never be
# derived from another resource's attributes: that works on an incremental
# apply, where the attributes are already in state, and breaks on a cold apply
# where they are not yet known.
#
# Every precondition here guards a configuration Azure ACCEPTS and then never
# acts on. See locals.tf for why each one is silent.
################################################################################

resource "azurerm_monitor_metric_alert" "this" {
  for_each = local.alerts

  name                = "${var.alert_name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  scopes              = [var.cluster_id]
  description         = each.value.description

  severity      = each.value.severity
  frequency     = each.value.frequency
  window_size   = each.value.window_size
  enabled       = each.value.enabled
  auto_mitigate = each.value.auto_mitigate

  criteria {
    metric_namespace = local.metric_namespace
    metric_name      = each.value.metric_name
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold

    dynamic "dimension" {
      for_each = each.value.dimensions

      content {
        name     = dimension.key
        operator = dimension.value.operator
        values   = dimension.value.values
      }
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags

  lifecycle {
    ############################################################################
    # Targeting. Each of these produces a rule that is created successfully,
    # displays as healthy, and never fires.
    ############################################################################
    precondition {
      condition = length(local.unknown_metrics) == 0
      error_message = join(" ", [
        "Metric alert(s) name a metric that AKS does not publish: ${join(", ", local.unknown_metrics)}.",
        "Azure ACCEPTS a rule on a non-existent metric — it is created, shows as enabled and healthy, and never fires.",
        "There is no error to find later.",
        "Valid metric names are in the catalogue in locals.tf, read from the metric definitions API."
      ])
    }

    precondition {
      condition = length(local.unsupported_aggregations) == 0
      error_message = join(" ", [
        "Metric alert(s) use an aggregation the metric does not publish: ${join(", ", local.unsupported_aggregations)}.",
        "As with an unknown metric name, Azure accepts this and the rule never fires.",
        "Each metric's supported aggregations are in the catalogue in locals.tf."
      ])
    }

    precondition {
      condition = length(local.invalid_dimensions) == 0
      error_message = join(" ", [
        "Metric alert(s) filter on a dimension the metric does not carry: ${join(", ", local.invalid_dimensions)}.",
        "The filter matches no time series, so the rule never fires.",
        "This is the most deceptive of the three, because a dimension-filtered rule reads as MORE precisely targeted than an unfiltered one.",
        "Each metric's dimensions are in the catalogue in locals.tf."
      ])
    }

    precondition {
      condition = length(local.autoscaler_metrics_without_autoscaler) == 0
      error_message = join(" ", [
        "Metric alert(s) watch a cluster_autoscaler_* metric while cluster_autoscaler_enabled is false: ${join(", ", local.autoscaler_metrics_without_autoscaler)}.",
        "Those metrics exist on every AKS cluster and are accepted by every rule, but the autoscaler only PUBLISHES them when it is actually running.",
        "With it off the rule receives no data, never fires, and reports no error — the metric catalogue cannot catch this, because the metric genuinely exists.",
        "Use kube_pod_status_phase with phase=Pending to detect unschedulable pods without the autoscaler, or set cluster_autoscaler_enabled."
      ])
    }

    precondition {
      condition = length(local.unknown_threshold_overrides) == 0
      error_message = join(" ", [
        "threshold_overrides names rule(s) that do not exist: ${join(", ", local.unknown_threshold_overrides)}.",
        "The override is ignored and the default threshold stays in place, which looks identical to the override having been applied."
      ])
    }

    ############################################################################
    # Evaluation window
    ############################################################################
    precondition {
      condition = length(local.windows_shorter_than_frequency) == 0
      error_message = join(" ", [
        "Metric alert(s) have a window shorter than their evaluation frequency: ${join(", ", local.windows_shorter_than_frequency)}.",
        "Azure rejects this, but its error names neither value."
      ])
    }
  }
}
