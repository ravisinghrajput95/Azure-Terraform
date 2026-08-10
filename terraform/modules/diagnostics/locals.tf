################################################################################
# Discovered capability
################################################################################

locals {
  available_log_categories = sort(data.azurerm_monitor_diagnostic_categories.this.log_category_types)
  available_log_groups     = sort(data.azurerm_monitor_diagnostic_categories.this.log_category_groups)
  available_metrics        = sort(data.azurerm_monitor_diagnostic_categories.this.metrics)

  # Most modern resource types expose an "allLogs" group. Older ones expose
  # only individual categories, so the "all" mode has to fall back rather than
  # assume.
  supports_all_logs_group = contains(local.available_log_groups, "allLogs")

  use_category_group = var.log_selection == "all" && local.supports_all_logs_group
}

################################################################################
# Selection
################################################################################

locals {
  explicit_log_categories = var.log_selection == "none" ? [] : [
    for category in local.available_log_categories : category
    if !contains(var.excluded_log_categories, category)
  ]

  # A map, not a list, so for_each keys on the category name. Keying on an
  # index would mean a category being added upstream re-indexes the rest and
  # Terraform plans to replace unrelated entries.
  log_entries = local.use_category_group ? {
    allLogs = {
      category       = null
      category_group = "allLogs"
    }
    } : {
    for category in local.explicit_log_categories :
    category => {
      category       = category
      category_group = null
    }
  }

  metric_entries = var.enable_metrics ? toset([
    for metric in local.available_metrics : metric
    if !contains(var.excluded_metric_categories, metric)
  ]) : toset([])
}

################################################################################
# Exclusion validation
#
# An exclusion naming a category the resource does not expose is almost always
# a typo. It fails silently — the intended category keeps being collected —
# and surfaces weeks later as an unexplained ingestion bill.
################################################################################

locals {
  unknown_excluded_logs = sort(tolist(setsubtract(
    toset(var.excluded_log_categories),
    toset(local.available_log_categories)
  )))

  unknown_excluded_metrics = sort(tolist(setsubtract(
    toset(var.excluded_metric_categories),
    toset(local.available_metrics)
  )))
}
