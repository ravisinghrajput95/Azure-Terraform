################################################################################
# Unit tests for the diagnostics module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# This module reads azurerm_monitor_diagnostic_categories to discover what the
# target resource can emit, so the data source is mocked with a realistic AKS
# category set — including kube-audit, which is the category that mattered:
# measured at 995 MB/day against dev's 512 MB/day cap, 97% of the environment's
# whole ingestion budget and twice the cap on its own.
#
# The failures guarded here are all silent. A diagnostic setting collecting
# nothing is accepted and reports healthy. An exclusion naming a category that
# does not exist keeps collecting the category it was meant to stop, and
# surfaces as an ingestion bill weeks later.
################################################################################

mock_provider "azurerm" {
  mock_data "azurerm_monitor_diagnostic_categories" {
    defaults = {
      log_category_types  = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "cluster-autoscaler"]
      log_category_groups = ["allLogs", "audit"]
      metrics             = ["AllMetrics"]
    }
  }
}

variables {
  target_resource_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.ContainerService/managedClusters/aks"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mon/providers/Microsoft.OperationalInsights/workspaces/log"
  name                       = "diag-aks"
}

################################################################################
# Valid configuration
################################################################################

run "accepts_the_default_collect_everything_setting" {
  command = plan

  # "all" uses the allLogs category GROUP where the resource supports it, so
  # categories Azure adds later are collected without a code change.
  assert {
    condition     = output.uses_category_group == true
    error_message = "A resource exposing allLogs must be collected by group, not by enumerating today's categories."
  }

  assert {
    condition     = contains(output.available_log_categories, "kube-audit")
    error_message = "The discovered category set must include what the resource actually exposes."
  }
}

################################################################################
# Excluding a category requires explicit selection
#
# An exclusion has no effect under the allLogs group — the group collects
# everything by definition. Accepting the combination would silently keep
# collecting the category the caller asked to drop, which is exactly how dev
# hit its cap every day.
################################################################################

run "rejects_exclusions_while_collecting_by_group" {
  command = plan

  variables {
    log_selection           = "all"
    excluded_log_categories = ["kube-audit"]
  }

  expect_failures = [azurerm_monitor_diagnostic_setting.this]
}

run "accepts_exclusions_under_explicit_selection" {
  command = plan

  # This is what dev actually ran once kube-audit was found to be 97% of the
  # ingestion budget. The security cost is recorded in SECURITY.md rather than
  # absorbed quietly.
  variables {
    log_selection           = "explicit"
    excluded_log_categories = ["kube-audit", "kube-audit-admin"]
  }

  assert {
    condition     = output.uses_category_group == false
    error_message = "Explicit selection must enumerate categories rather than using a group."
  }

  assert {
    condition     = !contains(output.collected_log_categories, "kube-audit")
    error_message = "An excluded category must not be collected."
  }

  assert {
    condition     = contains(output.collected_log_categories, "kube-apiserver")
    error_message = "Excluding one category must not drop the others."
  }
}

################################################################################
# Exclusions naming something that does not exist
#
# Almost always a typo, and it fails in the most expensive direction: the
# category the caller meant to exclude keeps being collected.
################################################################################

run "rejects_an_unknown_excluded_log_category" {
  command = plan

  variables {
    log_selection           = "explicit"
    excluded_log_categories = ["kube-audit", "kube-audi"]
  }

  expect_failures = [azurerm_monitor_diagnostic_setting.this]
}

run "rejects_an_unknown_excluded_metric" {
  command = plan

  variables {
    excluded_metric_categories = ["AllMetric"]
  }

  expect_failures = [azurerm_monitor_diagnostic_setting.this]
}

################################################################################
# A setting that collects nothing
#
# Azure accepts a diagnostic setting with no logs and no metrics. It is created,
# displays in the portal, and sends nothing anywhere.
################################################################################

run "rejects_a_setting_that_collects_nothing" {
  command = plan

  variables {
    log_selection              = "explicit"
    excluded_log_categories    = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "cluster-autoscaler"]
    enable_metrics             = false
    excluded_metric_categories = []
  }

  expect_failures = [azurerm_monitor_diagnostic_setting.this]
}

run "accepts_metrics_only_collection" {
  command = plan

  # Logs entirely excluded is fine as long as metrics are still flowing — the
  # setting is doing something.
  variables {
    log_selection           = "explicit"
    excluded_log_categories = ["kube-apiserver", "kube-audit", "kube-audit-admin", "kube-controller-manager", "cluster-autoscaler"]
    enable_metrics          = true
  }

  assert {
    condition     = length(output.collected_metrics) == 1
    error_message = "Metrics must still be collected when every log category is excluded."
  }

  assert {
    condition     = length(output.collected_log_categories) == 0
    error_message = "Every log category was excluded, so none may be collected."
  }
}
