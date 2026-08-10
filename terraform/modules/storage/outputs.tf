################################################################################
# Account
################################################################################

output "id" {
  description = "ARM resource ID of the storage account. Role assignment scopes and diagnostic settings target this."
  value       = azurerm_storage_account.this.id
}

output "name" {
  description = "Storage account name."
  value       = azurerm_storage_account.this.name
}

output "primary_blob_endpoint" {
  description = "Blob service endpoint. Resolves to the private endpoint from inside the VNet and to the firewalled public endpoint elsewhere — the same hostname either way."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "primary_dfs_endpoint" {
  description = "Data Lake Gen2 endpoint, present whether or not hierarchical namespace is enabled."
  value       = azurerm_storage_account.this.primary_dfs_endpoint
}

################################################################################
# Deliberately not exported: primary_access_key, secondary_access_key,
# primary_connection_string, secondary_connection_string
#
# This module disables shared access keys by default, so they are inert. Even
# where enabled, exporting them would propagate a static, non-expiring,
# unscopable credential into every consuming module's state and plan output.
#
# Consumers authenticate with a managed identity and a data-plane role. If a
# key is genuinely required by a legacy component, read it deliberately with
# `terraform state show` rather than making it ambient.
################################################################################

################################################################################
# Containers
################################################################################

output "container_names" {
  description = "Containers created in this account."
  value       = sort(keys(azurerm_storage_container.this))
}

output "container_ids" {
  description = "Map of container name to resource ID."
  value       = { for name, container in azurerm_storage_container.this : name => container.id }
}

################################################################################
# Private endpoints
################################################################################

output "private_endpoint_ids" {
  description = "Map of sub-resource to private endpoint resource ID."
  value       = { for sub, endpoint in azurerm_private_endpoint.this : sub => endpoint.id }
}

output "private_endpoint_ips" {
  description = "Map of sub-resource to the private IP it resolves to inside the VNet. Useful for confirming DNS resolves to the endpoint rather than to the public address."
  value       = { for sub, endpoint in azurerm_private_endpoint.this : sub => endpoint.private_service_connection[0].private_ip_address }
}

output "private_endpoint_subresources" {
  description = "Sub-resources reachable privately. Anything absent still resolves publicly — a blob endpoint does not make file resolve."
  value       = sort(keys(azurerm_private_endpoint.this))
}

################################################################################
# Security posture
################################################################################

output "shared_access_key_enabled" {
  description = "Whether the static account keys work. False is the intended state: keys are the most frequently leaked Azure credential, and disabling them forces every consumer onto Entra ID."
  value       = azurerm_storage_account.this.shared_access_key_enabled
}

output "allows_public_blob_access" {
  description = "Whether any container in this account could be made anonymously readable. False forecloses the most common storage data-exposure incident account-wide, regardless of per-container settings."
  value       = azurerm_storage_account.this.allow_nested_items_to_be_public
}

output "reachable_from" {
  description = "Who can reach the data plane, in plain language."
  value = join(" ", compact([
    length(local.private_endpoints) > 0 ? "Private endpoint from inside the VNet for: ${join(", ", sort(keys(local.private_endpoints)))}." : "",
    var.public_network_access_enabled ? (
      var.network_rules_default_action == "Deny" ?
      "Public endpoint restricted to ${length(var.allowed_ip_rules)} IP rule(s) and ${length(var.allowed_subnet_ids)} subnet(s)." :
      "Public endpoint OPEN to all sources."
    ) : "No public endpoint.",
    var.shared_access_key_enabled ? "WARNING: shared access keys are ENABLED." : "Entra ID authentication only.",
  ]))
}

output "granted_principal_ids" {
  description = "Principals holding a role on this account, with the role. With shared keys disabled this is the complete list of who can reach the data — control-plane roles such as Owner do not confer data access."
  value = {
    for key, assignment in var.role_assignments :
    key => "${assignment.principal_id} → ${assignment.role_definition_name}"
  }
}
