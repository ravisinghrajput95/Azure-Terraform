################################################################################
# Server
################################################################################

output "server_id" {
  description = "ARM resource ID of the logical server."
  value       = azurerm_mssql_server.this.id
}

output "server_name" {
  description = "Logical server name."
  value       = azurerm_mssql_server.this.name
}

output "server_fqdn" {
  description = "Fully qualified domain name. Resolves to the private endpoint from inside the VNet and to the public endpoint elsewhere — the same hostname either way, so connection strings do not change."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "server_principal_id" {
  description = "System-assigned managed identity of the server. Grant this access when the server must authenticate outbound — to a Key Vault holding a customer-managed TDE key, or to a storage account receiving audit logs."
  value       = azurerm_mssql_server.this.identity[0].principal_id
}

################################################################################
# Database
################################################################################

output "database_id" {
  description = "ARM resource ID of the database. Diagnostic settings target this."
  value       = azurerm_mssql_database.this.id
}

output "database_name" {
  description = "Database name."
  value       = azurerm_mssql_database.this.name
}

output "sku_name" {
  description = "Service objective actually deployed."
  value       = azurerm_mssql_database.this.sku_name
}

output "is_serverless" {
  description = "Whether the database uses the serverless compute model, which bills per second and pauses when idle."
  value       = local.is_serverless
}

output "auto_pause_delay_in_minutes" {
  description = "Minutes of inactivity before pausing, -1 for never, or null on a provisioned SKU. A paused database bills for storage only — the reason serverless is near-free in an environment used a few hours a day. The cost is a cold-start delay of several seconds on the first connection after a pause."
  value       = local.is_serverless ? var.auto_pause_delay_in_minutes : null
}

################################################################################
# Connection
#
# No connection string is exported, and none contains a password: with
# azuread_authentication_only there is no SQL login to put in one.
#
# Applications connect with their managed identity, for example:
#   Server=<fqdn>;Database=<db>;Authentication=Active Directory Managed Identity;
#   User Id=<client_id_of_user_assigned_identity>;
#
# The client ID comes from the managed-identity module, not from here.
################################################################################

output "connection_guidance" {
  description = "How to connect. There is no password because there is no SQL login — applications present a managed identity."
  value = format(
    "Server=%s;Database=%s;Authentication=Active Directory Managed Identity;User Id=<managed_identity_client_id>;Encrypt=true;",
    azurerm_mssql_server.this.fully_qualified_domain_name,
    azurerm_mssql_database.this.name
  )
}

################################################################################
# Private endpoint
################################################################################

output "private_endpoint_id" {
  description = "Private endpoint resource ID, or null when none was created."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].id : null
}

output "private_endpoint_ip" {
  description = "Private IP the server FQDN resolves to inside the VNet."
  value       = local.has_private_endpoint ? azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address : null
}

################################################################################
# Security posture
################################################################################

output "azuread_authentication_only" {
  description = "Whether SQL authentication is disabled entirely. True means no password was ever set and none can be used. Note that Azure still records a placeholder administratorLogin value on the server — it is an artefact, not a usable credential, because SQL auth is off."
  value       = var.azuread_authentication_only
}

output "administrator_is_individual" {
  description = "True when the Entra administrator is a named user rather than a group. A governance weakness rather than a technical fault: it ties database administration to one person's account, which breaks when they leave and cannot be reviewed as a role. Prefer a group."
  value       = local.administrator_is_individual
}

output "reachable_from" {
  description = "Who can reach the server, in plain language."
  value = join(" ", compact([
    local.has_private_endpoint ? "Private endpoint from inside the VNet." : "",
    var.public_network_access_enabled ?
    "Public endpoint with ${length(var.allowed_ip_rules)} firewall rule(s)." :
    "No public endpoint.",
    var.azuread_authentication_only ? "Entra ID authentication only — SQL authentication is disabled and no password was ever set." : "WARNING: SQL authentication is ENABLED.",
  ]))
}

output "backup_summary" {
  description = "Effective backup posture: the point-in-time window, whether long-term retention is on, and where backups are stored."
  value = format(
    "Point-in-time restore: %d days. Long-term retention: %s. Backup storage: %s.",
    var.short_term_retention_days,
    var.long_term_retention_enabled ? "enabled" : "disabled",
    var.storage_account_type
  )
}
