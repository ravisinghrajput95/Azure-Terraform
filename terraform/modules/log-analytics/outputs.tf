################################################################################
# Workspace
################################################################################

output "id" {
  description = "Full ARM resource ID. This is what diagnostic settings, Data Collection Rules and alert rules target."
  value       = azurerm_log_analytics_workspace.this.id
}

output "name" {
  description = "Workspace name."
  value       = azurerm_log_analytics_workspace.this.name
}

output "workspace_id" {
  description = "The workspace GUID (customer ID), distinct from the ARM resource ID. Some agent configurations and the query API use this form."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "resource_group_name" {
  description = "Resource group containing the workspace."
  value       = azurerm_log_analytics_workspace.this.resource_group_name
}

output "location" {
  description = "Region the workspace was created in."
  value       = azurerm_log_analytics_workspace.this.location
}

################################################################################
# Identity
################################################################################

output "principal_id" {
  description = "System-assigned managed identity principal ID, or null when the identity is disabled. Grant this access when the workspace must authenticate outbound, for example to a Key Vault holding a customer-managed key."
  value       = var.enable_system_assigned_identity ? azurerm_log_analytics_workspace.this.identity[0].principal_id : null
}

################################################################################
# Cost and configuration signals
#
# Surfaced so the operational consequences of the chosen settings are visible
# in `terraform output` rather than only in the module's source.
################################################################################

output "ingestion_is_capped" {
  description = "Whether a daily ingestion cap is set. When true, ingestion STOPS for the remainder of the UTC day once the cap is hit and the dropped data is unrecoverable."
  value       = local.ingestion_is_capped
}

output "daily_quota_gb" {
  description = "The configured daily cap in GB, or -1 when uncapped."
  value       = var.daily_quota_gb
}

output "retention_in_days" {
  description = "Configured interactive retention."
  value       = var.retention_in_days
}

output "retention_is_billable" {
  description = "Whether retention exceeds the 31 days included with PerGB2018. When true, the excess is billed per GB per month on top of ingestion."
  value       = local.retention_is_billable
}

################################################################################
# Deliberately not exported: primary_shared_key
#
# Nothing in this platform needs it. Azure Monitor Agent authenticates with a
# managed identity through Data Collection Rules, and local_authentication_disabled
# exists precisely to turn the key off. Exporting it would propagate a
# long-lived credential into every consuming module's state and plan output for
# no benefit.
#
# If a legacy component genuinely requires it, read it deliberately with
# `terraform state show`, rather than making it ambient.
################################################################################
