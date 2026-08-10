################################################################################
# Log Analytics workspace
#
# The telemetry sink every other module reports into. Built early, in Phase 1,
# because a diagnostic setting cannot be created before its destination exists.
#
# The workspace itself carries no charge. Cost is driven entirely by ingestion
# volume and by retention beyond the included 31 days, so an empty workspace in
# a not-yet-populated environment is free.
#
# NOT created here, deliberately:
#
#   azurerm_log_analytics_solution — the "solutions" model (VMInsights,
#   Security, Updates) belongs to the retired Log Analytics agent era. VM
#   Insights on Azure Monitor Agent is delivered through Data Collection Rules
#   instead, which the monitor module owns. Adding a solution here would
#   satisfy a portal blade while contributing nothing to the data path.
################################################################################

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku               = var.sku
  retention_in_days = var.retention_in_days
  daily_quota_gb    = var.daily_quota_gb

  internet_ingestion_enabled = var.internet_ingestion_enabled
  internet_query_enabled     = var.internet_query_enabled

  # Positive form. Setting this false forces Entra ID authentication for
  # ingestion; Azure Monitor Agent authenticates via managed identity through a
  # DCR and never needs the workspace shared key.
  #
  # The inverse argument `local_authentication_disabled` is deprecated and is
  # removed in azurerm v5.
  local_authentication_enabled = var.local_authentication_enabled

  # Lets a principal with read access to a resource read that resource's logs
  # without workspace-wide permissions.
  allow_resource_only_permissions = var.allow_resource_only_permissions

  dynamic "identity" {
    for_each = var.enable_system_assigned_identity ? [1] : []

    content {
      type = "SystemAssigned"
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.public_access_partially_disabled || var.private_link_scope_configured
      error_message = join(" ", [
        "internet_ingestion_enabled or internet_query_enabled is false, but private_link_scope_configured is not set.",
        "Disabling a public endpoint requires an Azure Monitor Private Link Scope (AMPLS) covering this workspace.",
        "Without one, ingestion or query access is severed silently — agents keep running, report healthy, and no data arrives.",
        "Deploy an AMPLS and set private_link_scope_configured = true, or leave both endpoints enabled."
      ])
    }
  }
}
