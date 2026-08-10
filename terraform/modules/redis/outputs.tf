################################################################################
# Cache
################################################################################

output "id" {
  description = "ARM resource ID of the cache. Access policy assignments and diagnostic settings target this."
  value       = azurerm_managed_redis.this.id
}

output "name" {
  description = "Cache name."
  value       = azurerm_managed_redis.this.name
}

output "hostname" {
  description = "Cache hostname. Resolves to the private endpoint from inside the VNet."
  value       = azurerm_managed_redis.this.hostname
}

output "sku_name" {
  description = "SKU actually deployed."
  value       = azurerm_managed_redis.this.sku_name
}

################################################################################
# Deliberately not exported: primary_access_key, secondary_access_key
#
# Access key authentication is disabled by default, so they are inert. Even
# where enabled, exporting them would propagate a static, non-expiring,
# unscopable credential into every consuming module's state and plan output.
################################################################################

output "connection_guidance" {
  description = "How to connect. No password — access keys are disabled and clients present a managed identity bound to an access policy."
  value = format(
    "%s, %s protocol, Entra ID authentication via access policy assignment. Managed Redis defaults to port 10000, NOT the classic 6380.",
    azurerm_managed_redis.this.hostname,
    var.client_protocol
  )
}

################################################################################
# Availability
################################################################################

output "high_availability_enabled" {
  description = "Whether the cache replicates across nodes. This is what carries the SLA."
  value       = azurerm_managed_redis.this.high_availability_enabled
}

output "availability_summary" {
  description = "Plain-language availability posture, so the limits of the deployed configuration are visible without knowing Managed Redis semantics."
  value = var.high_availability_enabled ? (
    "${var.sku_name} with high availability: replicated across nodes, SLA applies."
    ) : (
    "${var.sku_name} with high availability DISABLED: single node, NO SLA. A host fault or restart loses the entire cache with nothing to fail over to. Suitable only where the cache is a pure accelerator and a cold start is survivable."
  )
}

################################################################################
# Security posture
################################################################################

output "access_keys_enabled" {
  description = "Whether the static access keys work. False is the intended state — clients authenticate with a managed identity through an access policy assignment."
  value       = var.access_keys_authentication_enabled
}

output "access_policy_assignment_ids" {
  description = "Map of assignment key to resource ID. With access keys disabled, this is the complete list of principals that can reach the data plane."
  value       = { for key, assignment in azurerm_managed_redis_access_policy_assignment.this : key => assignment.id }
}

output "reachable_from" {
  description = "Who can reach the cache, in plain language."
  value = join(" ", compact([
    local.has_private_endpoint ? "Private endpoint from inside the VNet." : "",
    var.public_network_access_enabled ? "PUBLIC endpoint enabled — Managed Redis has no IP allowlist, so this is open to the internet." : "No public endpoint.",
    var.access_keys_authentication_enabled ? "WARNING: access keys are ENABLED." : "Entra ID authentication only, via ${length(var.access_policy_assignments)} access policy assignment(s).",
    var.client_protocol == "Encrypted" ? "TLS required." : "WARNING: plaintext protocol permitted.",
  ]))
}

################################################################################
# Private endpoint
################################################################################

output "private_endpoint_id" {
  description = "Private endpoint resource ID, or null when none was created."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].id : null
}

output "private_endpoint_ip" {
  description = "Private IP the cache hostname resolves to inside the VNet."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address : null
}
