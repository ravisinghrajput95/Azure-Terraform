################################################################################
# Diagnostic setting
################################################################################

output "id" {
  description = "ARM resource ID of the diagnostic setting."
  value       = azurerm_monitor_diagnostic_setting.this.id
}

output "name" {
  description = "Name of the diagnostic setting."
  value       = azurerm_monitor_diagnostic_setting.this.name
}

output "target_resource_id" {
  description = "Resource these diagnostics were attached to."
  value       = var.target_resource_id
}

################################################################################
# What was discovered and what was collected
#
# Exposed so a caller can see the difference between "this resource emits
# nothing" and "our configuration excluded everything" without reading the
# module source or querying the API by hand.
################################################################################

output "available_log_categories" {
  description = "Log categories the target resource type exposes, as discovered at plan time."
  value       = local.available_log_categories
}

output "available_log_groups" {
  description = "Log category groups the target exposes, typically \"allLogs\" and sometimes \"audit\"."
  value       = local.available_log_groups
}

output "available_metrics" {
  description = "Metric categories the target exposes. Most resource types expose only \"AllMetrics\"."
  value       = local.available_metrics
}

output "collected_log_categories" {
  description = "Log categories actually enabled. Empty when the allLogs category group is used instead — check uses_category_group to distinguish that from collecting nothing."
  value       = local.use_category_group ? [] : local.explicit_log_categories
}

output "collected_metrics" {
  description = "Metric categories actually enabled."
  value       = sort(tolist(local.metric_entries))
}

output "uses_category_group" {
  description = "True when the allLogs category group is used, meaning categories Azure adds in future are collected automatically without a code change. False means categories were enumerated individually and a new one would go uncollected until the next plan."
  value       = local.use_category_group
}
