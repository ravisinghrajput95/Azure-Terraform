################################################################################
# Unit tests for the monitor module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# The preconditions under test all guard the same class of defect: a
# configuration Azure ACCEPTS, creates, displays as healthy, and never acts on.
# None of them produce an error at apply time, and none are visible in a plan.
# A test is the only thing that proves the guard is still wired up, because the
# failure it prevents is invisible by construction.
################################################################################

mock_provider "azurerm" {}

variables {
  action_group_name       = "ag-cloudcart-test-cus-001"
  action_group_short_name = "ccrt-test"
  resource_group_name     = "rg-cloudcart-test-cus-mon"
  location                = "centralus"
  tags                    = { environment = "test" }

  alert_name_prefix = "alrt-cloudcart-test-cus"
  cluster_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks-test"

  email_receivers = {
    platform = "platform@example.com"
  }
}

################################################################################
# Valid configuration
#
# The default rule set is the one dev deploys, so this also proves the defaults
# are internally consistent with the metric catalogue.
################################################################################

run "accepts_the_default_alert_set" {
  command = plan

  assert {
    condition     = output.enabled_alert_count == 8
    error_message = "The default rule set should deploy 8 enabled alerts."
  }

  assert {
    condition     = length(output.disabled_alerts) == 0
    error_message = "No default rule should ship disabled."
  }

  assert {
    condition     = output.receiver_count == 1
    error_message = "The fixture supplies one receiver."
  }
}

run "default_rules_target_the_single_node_failure_modes" {
  command = plan

  assert {
    condition     = output.metrics_monitored["node-not-ready"] == "kube_node_status_condition"
    error_message = "Node readiness is the critical signal on a single-node cluster."
  }

  assert {
    condition     = output.metrics_monitored["pods-pending"] == "kube_pod_status_phase"
    error_message = "Stuck-pending pods must be detected via kube_pod_status_phase, which publishes regardless of whether the autoscaler runs."
  }
}

################################################################################
# Notification delivery
################################################################################

run "rejects_an_action_group_with_no_receivers" {
  command = plan

  # Every rule evaluates, fires and resolves correctly, and tells nobody.
  variables {
    email_receivers = {}
  }

  expect_failures = [azurerm_monitor_action_group.this]
}

run "reports_a_disabled_action_group" {
  command = plan

  # Legitimate during an incident, dangerous if forgotten, so it is surfaced
  # rather than rejected.
  variables {
    action_group_enabled = false
  }

  assert {
    condition     = output.notifications_are_delivered == false
    error_message = "A disabled action group must report that notifications are not delivered."
  }

  assert {
    condition     = strcontains(output.coverage_summary, "no notification is delivered")
    error_message = "The coverage summary must state the delivery gap in plain language."
  }
}

################################################################################
# Targeting
#
# The three ways to build a rule that is created successfully and never fires.
################################################################################

run "rejects_a_metric_aks_does_not_publish" {
  command = plan

  variables {
    metric_alerts = {
      typo = {
        metric_name = "node_cpu_usage_percent" # real one ends _percentage
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
      }
    }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

run "rejects_an_aggregation_the_metric_does_not_publish" {
  command = plan

  # node_cpu_usage_percentage publishes Maximum and Average, not Total.
  variables {
    metric_alerts = {
      wrong-agg = {
        metric_name = "node_cpu_usage_percentage"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 80
      }
    }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

run "rejects_a_dimension_the_metric_does_not_carry" {
  command = plan

  # kube_pod_status_phase carries namespace, phase and pod — not "node".
  # The filter would match no time series and the rule would never fire, while
  # reading as more precisely targeted than an unfiltered rule.
  variables {
    metric_alerts = {
      wrong-dim = {
        metric_name = "kube_pod_status_phase"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 0

        dimensions = {
          node = { values = ["aks-system-0"] }
        }
      }
    }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

run "accepts_a_dimension_the_metric_does_carry" {
  command = plan

  variables {
    metric_alerts = {
      right-dim = {
        metric_name = "kube_pod_status_phase"
        aggregation = "Total"
        operator    = "GreaterThan"
        threshold   = 0

        dimensions = {
          phase = { values = ["Failed"] }
        }
      }
    }
  }

  assert {
    condition     = output.enabled_alert_count == 1
    error_message = "A valid dimension filter should be accepted."
  }
}

################################################################################
# Evaluation window
################################################################################

run "rejects_a_window_shorter_than_the_frequency" {
  command = plan

  # Azure rejects this too, but its error names neither value.
  variables {
    metric_alerts = {
      bad-window = {
        metric_name = "node_cpu_usage_percentage"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
        frequency   = "PT15M"
        window_size = "PT5M"
      }
    }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

################################################################################
# Coverage reporting
################################################################################

run "reports_when_every_rule_is_disabled" {
  command = plan

  variables {
    metric_alerts = {
      off = {
        metric_name = "node_cpu_usage_percentage"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
        enabled     = false
      }
    }
  }

  assert {
    condition     = output.enabled_alert_count == 0
    error_message = "A disabled rule must not count as evaluating."
  }

  assert {
    condition     = strcontains(output.coverage_summary, "observes nothing")
    error_message = "An alerting stack with every rule disabled must say so in plain language."
  }
}

run "counts_cost_from_enabled_rules_only" {
  command = plan

  variables {
    metric_alerts = {
      on = {
        metric_name = "node_cpu_usage_percentage"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
      }
      off = {
        metric_name = "node_memory_working_set_percentage"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 80
        enabled     = false
      }
    }
  }

  assert {
    condition     = output.enabled_alert_count == 1
    error_message = "Only enabled rules are billed, so only they should be counted."
  }
}

################################################################################
# Metrics that exist but are not published
#
# The catalogue cannot catch these: the metric name, aggregation and dimensions
# are all genuinely valid. Only the component that emits them is absent.
################################################################################

run "rejects_autoscaler_metrics_when_the_autoscaler_is_off" {
  command = plan

  # Verified against a live cluster: with autoscaling disabled,
  # cluster_autoscaler_unschedulable_pods_count returns ZERO data points, so
  # the rule is created, looks healthy, and never fires.
  variables {
    cluster_autoscaler_enabled = false

    metric_alerts = {
      unschedulable = {
        metric_name = "cluster_autoscaler_unschedulable_pods_count"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 0
      }
    }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

run "allows_autoscaler_metrics_when_the_autoscaler_is_on" {
  command = plan

  variables {
    cluster_autoscaler_enabled = true

    metric_alerts = {
      unschedulable = {
        metric_name = "cluster_autoscaler_unschedulable_pods_count"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 0
      }
    }
  }

  assert {
    condition     = output.enabled_alert_count == 1
    error_message = "With the autoscaler running the metric publishes and the rule is valid."
  }
}

################################################################################
# Threshold overrides
################################################################################

run "applies_a_threshold_override" {
  command = plan

  variables {
    metric_alerts = {
      pods-pending = {
        metric_name = "kube_pod_status_phase"
        aggregation = "Average"
        operator    = "GreaterThan"
        threshold   = 0
        dimensions  = { phase = { values = ["Pending"] } }
      }
    }
    threshold_overrides = { pods-pending = 3 }
  }

  assert {
    condition     = output.enabled_alert_count == 1
    error_message = "An override on an existing rule should be accepted."
  }
}

run "rejects_a_threshold_override_for_a_rule_that_does_not_exist" {
  command = plan

  # The override is silently ignored and the default threshold stays in place,
  # which looks identical to the override having been applied.
  variables {
    threshold_overrides = { no-such-rule = 5 }
  }

  expect_failures = [azurerm_monitor_metric_alert.this]
}

################################################################################
# Log Analytics daily cap alert
#
# The rule is off by default, so the first test proves it stays off rather than
# appearing by accident, and the rest prove the guards around switching it on.
#
# Every failure below is silent in Azure: the rule is created, its query passes
# validation, the portal shows it enabled and healthy, and it never fires.
################################################################################

run "does_not_deploy_the_daily_cap_alert_by_default" {
  command = plan

  assert {
    condition     = output.daily_cap_alert_is_deployed == false
    error_message = "The daily-cap alert must be opt-in. A workspace with no cap does not need it."
  }

  assert {
    condition     = output.daily_cap_alert_id == null
    error_message = "No rule should exist when the capability flag is off."
  }
}

run "warns_in_the_summary_when_no_daily_cap_alert_is_deployed" {
  command = plan

  assert {
    condition     = strcontains(output.coverage_summary, "no daily-cap alert")
    error_message = "Coverage summary must state that ingestion can stop silently when the cap alert is absent."
  }
}

run "accepts_the_daily_cap_alert_on_a_capped_workspace" {
  command = plan

  variables {
    enable_daily_cap_alert       = true
    log_analytics_daily_quota_gb = 0.5
    log_analytics_workspace_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log-test"
  }

  assert {
    condition     = output.daily_cap_alert_is_deployed == true
    error_message = "A capped workspace with the flag on should deploy the rule."
  }

  assert {
    condition     = strcontains(output.coverage_summary, "0.5 GB/day")
    error_message = "Coverage summary should state the cap being watched."
  }
}

# The single most important guard in this section. An uncapped workspace never
# stops ingesting, so it never emits the record the query matches.
run "rejects_the_daily_cap_alert_on_an_uncapped_workspace" {
  command = plan

  variables {
    enable_daily_cap_alert       = true
    log_analytics_daily_quota_gb = -1
    log_analytics_workspace_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log-test"
  }

  expect_failures = [azurerm_monitor_scheduled_query_rules_alert_v2.daily_cap]
}

run "rejects_the_daily_cap_alert_with_no_workspace_id" {
  command = plan

  variables {
    enable_daily_cap_alert       = true
    log_analytics_daily_quota_gb = 0.5
    log_analytics_workspace_id   = null
  }

  expect_failures = [azurerm_monitor_scheduled_query_rules_alert_v2.daily_cap]
}

run "rejects_a_daily_cap_window_shorter_than_its_frequency" {
  command = plan

  variables {
    enable_daily_cap_alert               = true
    log_analytics_daily_quota_gb         = 0.5
    log_analytics_workspace_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log-test"
    daily_cap_alert_evaluation_frequency = "PT1H"
    daily_cap_alert_window_duration      = "PT15M"
  }

  expect_failures = [azurerm_monitor_scheduled_query_rules_alert_v2.daily_cap]
}

# Regression guard. Microsoft's documented query filters on Operation, which
# holds a GUID on this platform's workspace and therefore matches nothing. A
# rule built that way deploys cleanly and never fires. If someone "corrects"
# the query back to the documented form, this test fails.
run "daily_cap_query_does_not_filter_on_the_operation_column" {
  command = plan

  variables {
    enable_daily_cap_alert       = true
    log_analytics_daily_quota_gb = 0.5
    log_analytics_workspace_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log-test"
  }

  # Matches the FILTER, not the table name — "_LogOperation" legitimately
  # contains "Operation".
  assert {
    condition     = !strcontains(output.daily_cap_alert_query, "where Operation")
    error_message = "The query must not filter on the Operation column. It holds a GUID, not \"Data collection Status\", so the documented query matches nothing and the rule never fires."
  }

  assert {
    condition     = !strcontains(output.daily_cap_alert_query, "Data collection Status")
    error_message = "The query must not use the documented \"Data collection Status\" value. Verified against the live workspace: it matches zero rows on a day the cap was genuinely hit."
  }

  assert {
    condition     = strcontains(output.daily_cap_alert_query, "OverQuota")
    error_message = "The query must match the OverQuota detail string, which is what the workspace actually emits."
  }

  assert {
    condition     = strcontains(output.daily_cap_alert_query, "_LogOperation")
    error_message = "The query must read _LogOperation."
  }
}

run "counts_the_daily_cap_alert_in_indicative_cost" {
  command = plan

  variables {
    enable_daily_cap_alert       = true
    log_analytics_daily_quota_gb = 0.5
    log_analytics_workspace_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log-test"
  }

  # 8 metric alerts at 0.10 plus one log search alert at 0.50.
  assert {
    condition     = output.indicative_monthly_cost_usd == 1.3
    error_message = "Log search alerts are priced per rule, separately from metric alerts, and must be counted."
  }
}
