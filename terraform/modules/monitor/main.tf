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

################################################################################
# Log Analytics daily cap alert
#
# Hitting the daily cap stops ingestion for the remainder of the UTC day. The
# dropped telemetry is unrecoverable: raising the cap afterwards does not
# backfill it. Every metric alert above goes blind at the same moment, so this
# rule is the one that reports the others having stopped working.
#
# for_each is over a statically-known boolean, never over the workspace ID.
# Deriving it from an attribute of the log-analytics module would work on an
# incremental apply and fail on a cold one.
################################################################################

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "daily_cap" {
  for_each = var.enable_daily_cap_alert ? toset(["daily-cap"]) : toset([])

  name                = "${var.alert_name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location

  scopes      = [var.log_analytics_workspace_id]
  severity    = var.daily_cap_alert_severity
  description = "Log Analytics workspace hit its daily ingestion cap. Collection has STOPPED until the cap resets, and the data dropped in the meantime is unrecoverable. Every metric alert in this action group is blind until then."

  evaluation_frequency = var.daily_cap_alert_evaluation_frequency
  window_duration      = var.daily_cap_alert_window_duration

  # The OverQuota row appears ONCE per cap hit. Requiring more than one failing
  # period would wait for a repeat that never comes, so both are pinned to 1
  # rather than exposed — a caller raising them would silence the rule without
  # any indication it had been silenced.
  criteria {
    query                   = local.daily_cap_query
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  # Left FALSE deliberately. Auto-mitigation resolves the alert once the query
  # stops matching, which happens when the OverQuota row ages out of the window
  # — typically within the hour. The cap itself is still in force until the
  # daily reset, so an auto-resolved alert would signal "recovered" while data
  # is still being dropped. The alert stays open until a human closes it.
  auto_mitigation_enabled = false

  # One cap hit is matched by several consecutive evaluations, because the
  # window is longer than the frequency by design. Without muting, that is a
  # stream of identical notifications.
  mute_actions_after_alert_duration = var.daily_cap_alert_mute_duration

  # Left FALSE deliberately: Azure validates the query against the workspace at
  # create time, so a query naming a table that does not exist fails the apply
  # instead of deploying a rule that can never match.
  skip_query_validation = false

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.daily_cap_alert_without_cap
      error_message = join(" ", [
        "enable_daily_cap_alert is true but log_analytics_daily_quota_gb is ${var.log_analytics_daily_quota_gb}, which means the workspace is UNCAPPED.",
        "An uncapped workspace never stops ingesting, so it never emits the OverQuota record this rule matches.",
        "Azure creates the rule, validates the query successfully, displays it as healthy, and it never fires.",
        "Either set a daily cap on the workspace, or set enable_daily_cap_alert = false rather than deploying a rule that cannot work."
      ])
    }

    precondition {
      condition = !local.daily_cap_alert_without_workspace
      error_message = join(" ", [
        "enable_daily_cap_alert is true but log_analytics_workspace_id is null or empty.",
        "Pass the workspace's full ARM resource ID — the log-analytics module's `id` output, not `workspace_id`, which is the customer GUID and is not a valid alert scope."
      ])
    }

    precondition {
      condition = !local.daily_cap_window_shorter_than_frequency
      error_message = join(" ", [
        "daily_cap_alert_window_duration (${var.daily_cap_alert_window_duration}) is shorter than daily_cap_alert_evaluation_frequency (${var.daily_cap_alert_evaluation_frequency}).",
        "Azure rejects this, and its error names neither value.",
        "The window should be comfortably LONGER than the frequency here: the OverQuota row is written once, and ingestion latency sits between the moment the cap is hit and the moment the row becomes queryable."
      ])
    }
  }
}

################################################################################
# Daily cap WARNING alert
#
# The rule above reports a cap that has already been hit. This one reports a
# cap about to be hit, which is the only one of the two that can still be acted
# on. Against the real 2026-08-13 cap hit it would have fired roughly 44
# minutes early — see locals.tf for the reconciliation.
#
# Auto-mitigation is ON here, unlike the cap-hit rule: this is a threshold that
# genuinely falls back below itself when the cap period resets, so resolving is
# accurate rather than misleading.
################################################################################

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "daily_cap_warning" {
  for_each = var.enable_daily_cap_warning_alert ? toset(["daily-cap-warning"]) : toset([])

  name                = "${var.alert_name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location

  scopes      = [var.log_analytics_workspace_id]
  severity    = var.daily_cap_warning_severity
  description = "Log Analytics ingestion has passed ${var.daily_cap_warning_percent}% of the ${var.log_analytics_daily_quota_gb} GB daily cap for the current period. Nothing has been lost yet. When the cap is reached, collection STOPS until it resets and the dropped data is unrecoverable."

  evaluation_frequency = var.daily_cap_warning_evaluation_frequency
  window_duration      = var.daily_cap_warning_window_duration

  criteria {
    query = local.daily_cap_warning_query

    # The query returns a single row holding a percentage, so the threshold in
    # the portal reads as "80" and stays correct if the cap itself changes.
    # Maximum rather than Total: if the query ever returned more than one row,
    # Total would sum percentages into a meaningless number.
    metric_measure_column   = "PercentOfDailyCap"
    time_aggregation_method = "Maximum"
    operator                = "GreaterThan"
    threshold               = var.daily_cap_warning_percent

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  # ON here, unlike the cap-hit rule, and NOT accompanied by a mute duration —
  # Azure rejects that combination outright:
  #
  #   "auto mitigation must be disabled when mute action duration is set"
  #
  # The two are alternatives, not complements. Muting exists for stateless
  # rules, which re-notify on every evaluation that matches; with
  # auto-mitigation the alert is stateful, so it notifies once, stays open
  # while ingestion remains above the threshold, and resolves by itself when
  # the cap period rolls over and the percentage falls back. That is accurate
  # here, whereas on the cap-hit rule it would have claimed recovery while data
  # was still being dropped.
  auto_mitigation_enabled = true

  skip_query_validation = false

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.daily_cap_warning_without_cap
      error_message = join(" ", [
        "enable_daily_cap_warning_alert is true but log_analytics_daily_quota_gb is ${var.log_analytics_daily_quota_gb}, which means the workspace is UNCAPPED.",
        "There is no cap to approach, so the percentage the rule measures has no meaning and the rule can never fire.",
        "Either set a daily cap on the workspace, or set enable_daily_cap_warning_alert = false."
      ])
    }

    precondition {
      condition = !local.daily_cap_warning_without_workspace
      error_message = join(" ", [
        "enable_daily_cap_warning_alert is true but log_analytics_workspace_id is null or empty.",
        "Pass the workspace's full ARM resource ID — the log-analytics module's `id` output, not `workspace_id`, which is the customer GUID and is not a valid alert scope."
      ])
    }

    precondition {
      condition = !local.daily_cap_warning_without_reset_hour
      error_message = join(" ", [
        "enable_daily_cap_warning_alert is true but daily_cap_reset_hour_utc is null.",
        "The daily cap counts data ingested since its last reset, so the query has to know when that was. It is NOT midnight everywhere — this platform's workspace resets at 11:00 UTC.",
        "There is deliberately no default: a wrong hour produces a query that sums the wrong window, which Azure accepts and reports as healthy while the total is simply incorrect.",
        "Read the real value with: az monitor log-analytics workspace show -g <rg> -n <name> --query workspaceCapping.quotaNextResetTime -o tsv"
      ])
    }

    precondition {
      condition = !local.daily_cap_warning_window_too_short
      error_message = join(" ", [
        "daily_cap_warning_window_duration (${var.daily_cap_warning_window_duration}) is shorter than the 24-hour cap period.",
        "The window is the rule's outer time filter, so a shorter one CLIPS the sum: the total comes out low, the threshold is never crossed, and the rule never fires while the workspace sails past its cap.",
        "Azure accepts this and reports the rule healthy. Use P1D or P2D."
      ])
    }
  }
}
