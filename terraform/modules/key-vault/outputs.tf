################################################################################
# Vault
################################################################################

output "id" {
  description = "ARM resource ID of the vault. Role assignment scopes and diagnostic settings target this."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Vault name."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Data-plane URI, e.g. https://kv-cloudcart-dev-a1b2.vault.azure.net/. Applications use this unchanged whether they reach it publicly or through the private endpoint — the private DNS zone makes the same hostname resolve privately from inside the VNet."
  value       = azurerm_key_vault.this.vault_uri
}

output "tenant_id" {
  description = "Tenant the vault belongs to."
  value       = azurerm_key_vault.this.tenant_id
}

################################################################################
# Private endpoint
################################################################################

output "private_endpoint_id" {
  description = "Private endpoint resource ID, or null when none was created."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].id : null
}

output "private_endpoint_ip" {
  description = "Private IP the vault resolves to from inside the VNet. Useful for confirming DNS is actually resolving to the endpoint rather than to the public address."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address : null
}

################################################################################
# Access posture
#
# Surfaced so the reachability model is visible in `terraform output` rather
# than requiring someone to reason about three interacting settings.
################################################################################

output "public_network_access_enabled" {
  description = "Whether a public endpoint exists at all."
  value       = var.public_network_access_enabled
}

output "public_access_is_firewalled" {
  description = "True when a public endpoint exists but denies by default, so only the configured IP and subnet rules reach it. False when there is no public endpoint, or when it is open."
  value       = var.public_network_access_enabled && var.network_acls_default_action == "Deny"
}

output "reachable_from" {
  description = "Human-readable summary of who can reach the data plane. The most common Key Vault support question, answered without reading the configuration."
  value = join(" ", compact([
    local.has_private_endpoint ? "Private endpoint from inside the VNet." : "",
    var.public_network_access_enabled ? (
      var.network_acls_default_action == "Deny" ?
      "Public endpoint restricted to ${length(var.allowed_ip_rules)} IP rule(s) and ${length(var.allowed_subnet_ids)} subnet(s)." :
      "Public endpoint OPEN to all sources."
    ) : "No public endpoint.",
    var.network_acls_bypass == "AzureServices" && var.public_network_access_enabled ? "Trusted Azure services bypass the rules." : "",
  ]))
}

output "public_endpoint_locked_shut" {
  description = "True when a public endpoint exists, denies by default, and has no rules at all — so nothing reaches it. Legitimate when a private endpoint carries all traffic, but usually means the allowlist was forgotten."
  value       = local.public_endpoint_with_no_rules
}

################################################################################
# Deletion protection
################################################################################

output "purge_protection_enabled" {
  description = "Whether purge protection is on. IRREVERSIBLE once enabled: Azure provides no way to switch it off, and the vault NAME stays reserved for the full retention period after deletion — so a deterministic-name environment cannot be rebuilt until it expires."
  value       = azurerm_key_vault.this.purge_protection_enabled
}

output "soft_delete_retention_days" {
  description = "Days a deleted vault stays recoverable, and its name reserved."
  value       = azurerm_key_vault.this.soft_delete_retention_days
}

################################################################################
# Grants
################################################################################

output "role_assignment_ids" {
  description = "Map of assignment key to role assignment ID, all scoped to this vault."
  value       = { for key, assignment in azurerm_role_assignment.this : key => assignment.id }
}

output "granted_principal_ids" {
  description = "Principal IDs holding a role on this vault, with the role granted. A single artefact for reviewing who can read the secrets."
  value = {
    for key, assignment in var.role_assignments :
    key => "${assignment.principal_id} → ${assignment.role_definition_name}"
  }
}
