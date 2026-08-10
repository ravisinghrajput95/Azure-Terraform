################################################################################
# Category discovery
#
# The reason this module exists. Every Azure resource type exposes a different
# set of diagnostic log and metric categories, and that set changes as Azure
# adds capabilities.
#
# Hardcoding category names per resource type is the usual approach and the
# usual source of breakage: a name that was valid last year fails the apply
# today, and a category added since is silently never collected. Reading the
# categories from the API at plan time means the configuration is correct for
# whatever the resource actually supports, now.
################################################################################

data "azurerm_monitor_diagnostic_categories" "this" {
  resource_id = var.target_resource_id
}

################################################################################
# Diagnostic setting
#
# Uses `enabled_log` and `enabled_metric`. The older `log` and `metric` blocks
# are deprecated — `metric` is flagged as such in the azurerm 4.x schema and is
# removed in v5 — and the `retention_policy` sub-block they carried no longer
# exists at all. Retention now belongs to the destination: workspace retention
# settings, or a storage account lifecycle policy.
################################################################################

resource "azurerm_monitor_diagnostic_setting" "this" {
  name               = var.name
  target_resource_id = var.target_resource_id

  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = var.log_analytics_destination_type
  storage_account_id             = var.storage_account_id

  # Either a single category-group entry or one entry per discovered category.
  # Keyed by name so that adding a category to the target resource type does
  # not re-index and recreate the others.
  dynamic "enabled_log" {
    for_each = local.log_entries

    content {
      category       = enabled_log.value.category
      category_group = enabled_log.value.category_group
    }
  }

  dynamic "enabled_metric" {
    for_each = local.metric_entries

    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    # Azure rejects a diagnostic setting that enables nothing. Without this the
    # failure arrives from the API as an opaque BadRequest, with no indication
    # that the cause is a resource type exposing no categories at all.
    precondition {
      condition = length(local.log_entries) > 0 || length(local.metric_entries) > 0
      error_message = join(" ", [
        "Diagnostic setting for ${var.target_resource_id} would enable no logs and no metrics, which Azure rejects.",
        "Discovered categories — logs: [${join(", ", local.available_log_categories)}],",
        "log groups: [${join(", ", local.available_log_groups)}],",
        "metrics: [${join(", ", local.available_metrics)}].",
        "Either the resource type supports no diagnostics, or log_selection/enable_metrics have excluded everything."
      ])
    }

    # A typo in an exclusion list silently collects the category it was meant
    # to drop, which surfaces as an unexplained ingestion bill rather than an
    # error.
    precondition {
      condition = length(local.unknown_excluded_logs) == 0
      error_message = join(" ", [
        "excluded_log_categories names categories this resource does not expose:",
        "[${join(", ", local.unknown_excluded_logs)}].",
        "Available: [${join(", ", local.available_log_categories)}]."
      ])
    }

    precondition {
      condition = length(local.unknown_excluded_metrics) == 0
      error_message = join(" ", [
        "excluded_metric_categories names categories this resource does not expose:",
        "[${join(", ", local.unknown_excluded_metrics)}].",
        "Available: [${join(", ", local.available_metrics)}]."
      ])
    }

    # Exclusions cannot be applied to a category group, which is all-or-nothing.
    precondition {
      condition = length(var.excluded_log_categories) == 0 || var.log_selection == "explicit"
      error_message = join(" ", [
        "excluded_log_categories is set but log_selection is \"${var.log_selection}\".",
        "A category group is all-or-nothing, so exclusions require log_selection = \"explicit\"."
      ])
    }
  }
}
