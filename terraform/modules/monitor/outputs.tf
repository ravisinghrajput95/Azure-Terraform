################################################################################
# Action group
################################################################################

output "action_group_id" {
  description = "Action group resource ID. Any alert rule built outside this module attaches to it through this."
  value       = azurerm_monitor_action_group.this.id
}

output "action_group_name" {
  description = "Action group name."
  value       = azurerm_monitor_action_group.this.name
}

output "receiver_count" {
  description = "Number of email receivers attached. Zero is rejected by a precondition, because alerts that notify nobody look identical to alerts that work."
  value       = length(var.email_receivers)
}

################################################################################
# Alert rules
################################################################################

output "alert_rule_ids" {
  description = "Map of alert key to resource ID."
  value       = { for k, a in azurerm_monitor_metric_alert.this : k => a.id }
}

output "alert_rule_names" {
  description = "Map of alert key to the deployed rule name."
  value       = { for k, a in azurerm_monitor_metric_alert.this : k => a.name }
}

output "metrics_monitored" {
  description = "Map of alert key to the metric it watches. Useful for confirming coverage without opening the portal."
  value       = { for k, a in local.alerts : k => a.metric_name }
}

################################################################################
# Coverage posture
#
# Reported rather than assumed. A deployed alerting stack that observes nothing
# is indistinguishable from a working one in the portal, so the degraded states
# are stated in plain language here.
################################################################################

output "enabled_alert_count" {
  description = "Number of alert rules actually evaluating."
  value       = local.enabled_alert_count
}

output "disabled_alerts" {
  description = "Alert keys deployed but switched off. These exist in Azure and never evaluate."
  value       = local.disabled_alerts
}

output "notifications_are_delivered" {
  description = "Whether the action group delivers. False means every rule still fires and resolves, and no notification leaves Azure."
  value       = var.action_group_enabled
}

output "coverage_summary" {
  description = "Consolidated alerting posture, so the interacting settings can be reviewed without reading the configuration."
  value = join(" ", compact([
    "${local.enabled_alert_count} of ${length(local.alerts)} alert rule(s) evaluating against ${length(var.email_receivers)} receiver(s).",
    local.all_alerts_disabled ? "WARNING: every alert rule is disabled — this stack observes nothing." : "",
    !var.action_group_enabled ? "WARNING: the action group is disabled — rules fire but no notification is delivered." : "",
    length(local.disabled_alerts) > 0 && !local.all_alerts_disabled ? "Disabled: ${join(", ", local.disabled_alerts)}." : "",
  ]))
}

################################################################################
# Cost
################################################################################

output "indicative_monthly_cost_usd" {
  description = "ORDER-OF-MAGNITUDE monthly estimate at approximate US list price, counting one time series per enabled rule. Metric alerts bill per evaluated time series, so any rule splitting on a dimension costs more than this counts — treat it as a floor, not a budget figure."
  value       = local.indicative_monthly_cost_usd
}
