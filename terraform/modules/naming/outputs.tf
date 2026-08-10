################################################################################
# Name segments
#
# Exposed so that callers needing a name this module does not yet precompute
# can compose one from the same parts, rather than inventing a parallel
# convention.
################################################################################

output "base" {
  description = "Hyphenated name base shared by most resources, e.g. \"cloudcart-prod-eus\"."
  value       = local.base
}

output "base_compact" {
  description = "Separator-free name base for resources that reject hyphens, e.g. \"cloudcartprdeus\"."
  value       = local.base_compact
}

output "abbreviations" {
  description = "Azure CAF resource type abbreviation table. Reference this instead of typing prefixes inline."
  value       = local.abbreviations
}

output "location_normalized" {
  description = "Region normalised to Azure's internal form, e.g. \"eastus\". Pass this to resources rather than the raw input so that \"East US\" and \"eastus\" cannot produce two different values in state."
  value       = local.location_normalized
}

output "location_short" {
  description = "Region abbreviation used in names, e.g. \"eus\"."
  value       = local.location_short
}

output "environment_short" {
  description = "Three-character environment abbreviation, e.g. \"prd\"."
  value       = local.environment_short
}

output "unique_suffix" {
  description = "Deterministic 4-character hash suffix applied to globally-unique names."
  value       = local.unique_suffix
}

################################################################################
# Resource group names
################################################################################

output "resource_group_names" {
  description = "Map of lifecycle scope to resource group name, e.g. { net = \"rg-cloudcart-prod-eus-net\", ... }."
  value       = local.resource_group_names
}

################################################################################
# Per-tier names
################################################################################

output "subnet_names" {
  description = "Map of tier to subnet name. Reserved Azure subnet names (AzureFirewallSubnet, AzureBastionSubnet, GatewaySubnet) are NOT produced here — they are fixed by the platform and are emitted as literals by the networking module."
  value       = local.subnet_names
}

output "network_security_group_names" {
  description = "Map of tier to network security group name."
  value       = local.network_security_group_names
}

output "scale_set_names" {
  description = "Map of tier to virtual machine scale set name."
  value       = local.scale_set_names
}

output "managed_identity_names" {
  description = "Map of tier to user-assigned managed identity name."
  value       = local.managed_identity_names
}

################################################################################
# Globally-unique names
#
# These carry the hash suffix because their namespace is global to Azure, not
# scoped to a resource group.
################################################################################

output "storage_account_name" {
  description = "Storage account name, 3-24 lowercase alphanumerics."
  value       = local.storage_account_name
}

output "key_vault_name" {
  description = "Key Vault name, 3-24 characters."
  value       = local.key_vault_name
}

output "sql_server_name" {
  description = "Azure SQL logical server name."
  value       = local.sql_server_name
}

output "redis_name" {
  description = "Azure Cache for Redis name."
  value       = local.redis_name
}

################################################################################
# Remaining resource names
################################################################################

output "names" {
  description = "Map of resource key to name for all remaining platform resources (virtual_network, firewall, bastion, application_gateway, log_analytics_workspace, and so on)."
  value       = local.names
}

################################################################################
# Validation handle
#
# Downstream modules may depend on this to guarantee that name validation has
# been evaluated before any resource is created. Consuming it is optional; the
# preconditions fail the plan regardless.
################################################################################

output "validation_id" {
  description = "Identifier of the internal validation resource. Depend on this to order name checking ahead of resource creation."
  value       = terraform_data.validation.id
}
