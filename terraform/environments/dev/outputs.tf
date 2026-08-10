################################################################################
# Resource groups
################################################################################

output "resource_group_names" {
  description = "Map of lifecycle scope to resource group name."
  value       = module.resource_group.names
}

output "resource_group_ids" {
  description = "Map of lifecycle scope to resource group ID."
  value       = module.resource_group.ids
}

output "locked_scopes" {
  description = "Scopes carrying a management lock. Empty in dev by design — a lock would block terraform destroy."
  value       = module.resource_group.locked_scopes
}

################################################################################
# Resolved configuration
#
# Surfaced so that what the profile actually decided is visible in
# `terraform output` rather than buried in module internals. Useful when
# reviewing what a given environment is about to become.
################################################################################

output "location" {
  description = "Normalised region these resources are deployed to."
  value       = module.naming.location_normalized
}

output "name_prefix" {
  description = "Shared name base, e.g. \"cloudcart-dev-eus\"."
  value       = module.naming.base
}

output "egress_strategy" {
  description = "Either \"firewall\" or \"nat_gateway\"."
  value       = module.profile.egress_strategy
}

output "ingress_strategy" {
  description = "Either \"application_gateway\" or \"public_load_balancer\"."
  value       = module.profile.ingress_strategy
}

output "peak_vcpus" {
  description = "Peak compute footprint across all tiers at maximum scale. Compare against the subscription quota, which is 4 on this FreeTrial subscription."
  value       = module.profile.peak_vcpus
}

output "quota_checked" {
  description = "Whether the vCPU quota assertion actually ran. False means it was skipped, not that it passed."
  value       = module.profile.quota_checked
}

output "indicative_monthly_cost_usd" {
  description = "ORDER-OF-MAGNITUDE monthly estimate at US list price. Excludes data processing, egress, storage capacity and transactions. A planning aid, not a budget figure."
  value       = module.profile.indicative_monthly_cost_usd
}

output "tags" {
  description = "Governance tags applied to every resource in this environment."
  value       = module.tags.tags
}

################################################################################
# Log Analytics
################################################################################

output "log_analytics_workspace_id" {
  description = "ARM resource ID of the workspace. Diagnostic settings, Data Collection Rules and alert rules target this."
  value       = module.log_analytics.id
}

output "log_analytics_workspace_name" {
  description = "Workspace name."
  value       = module.log_analytics.name
}

output "log_ingestion_is_capped" {
  description = "Whether a daily ingestion cap is active. True in dev to protect the free 5 GB/month allowance; ingestion stops for the rest of the UTC day once hit."
  value       = module.log_analytics.ingestion_is_capped
}

################################################################################
# Network
################################################################################

output "vnet_id" {
  description = "Virtual network resource ID."
  value       = module.networking.vnet_id
}

output "subnet_ids" {
  description = "Map of subnet name to resource ID."
  value       = module.networking.subnet_ids
}

output "subnet_cidrs" {
  description = "Map of subnet name to address prefix. NSG rules derive tier-to-tier sources from these rather than restating the address plan."
  value       = module.networking.subnet_cidrs
}

output "nat_gateway_public_ip" {
  description = "Public IP all outbound traffic is SNATed to. Allowlist this on any external service the workload calls."
  value       = module.networking.nat_gateway_public_ip
}

output "subnets_without_egress" {
  description = "Subnets with no outbound internet path. AzureBastionSubnet is expected here; anything else is worth investigating."
  value       = module.networking.subnets_without_egress
}

################################################################################
# Network security
################################################################################

output "nsg_ids" {
  description = "Map of NSG name to resource ID."
  value       = module.nsg.ids
}

output "nsg_rules" {
  description = "Effective rule matrix per NSG, in Azure's evaluation order. Diff this between environments to review policy drift."
  value       = module.nsg.rules_by_nsg
}

output "nsgs_without_explicit_deny" {
  description = "NSGs relying on Azure's built-in AllowVnetInBound, which permits all intra-VNet traffic. Should always be empty."
  value       = setsubtract(toset(keys(module.nsg.ids)), toset(module.nsg.nsgs_with_explicit_inbound_deny))
}

################################################################################
# Routing
################################################################################

output "route_table_ids" {
  description = "Map of route table name to resource ID."
  value       = module.route_table.ids
}

output "route_tables_with_default_route" {
  description = "Route tables forcing egress through a virtual appliance. Empty in dev: a NAT Gateway attaches to the subnet directly and is not a UDR next hop."
  value       = module.route_table.tables_with_default_route
}

output "route_table_subnets" {
  description = "Map of route table name to the subnet names it is applied to."
  value       = module.route_table.associated_subnet_names
}

################################################################################
# Private DNS
################################################################################

output "private_dns_zone_ids_by_service" {
  description = "Map of service key to privatelink zone ID. Private endpoints consume these in their private_dns_zone_group."
  value       = module.private_dns.zone_ids_by_service
}

output "private_dns_zone_names" {
  description = "Privatelink zones created for this environment."
  value       = module.private_dns.zone_names
}

################################################################################
# Bastion
################################################################################

output "bastion_dns_name" {
  description = "FQDN of the Bastion host, used by the portal and by `az network bastion` to establish sessions."
  value       = try(module.bastion[0].dns_name, null)
}

output "bastion_capability_notes" {
  description = "What the deployed Bastion SKU can and cannot do."
  value       = try(module.bastion[0].capability_notes, null)
}

################################################################################
# Managed identities
################################################################################

output "managed_identity_ids" {
  description = "Map of tier to user-assigned identity resource ID, referenced by a scale set's identity block."
  value       = module.managed_identity.ids
}

output "managed_identity_principal_ids" {
  description = "Map of tier to principal (object) ID. Role assignments and Key Vault RBAC grants reference this, not the client ID."
  value       = module.managed_identity.principal_ids
}

output "managed_identity_client_ids" {
  description = "Map of tier to client (application) ID. Application code presents this when requesting a token for a specific user-assigned identity."
  value       = module.managed_identity.client_ids
}

################################################################################
# Key Vault
################################################################################

output "key_vault_uri" {
  description = "Data-plane URI. The same hostname resolves to the private endpoint from inside the VNet and to the firewalled public endpoint from the operator allowlist."
  value       = module.key_vault.vault_uri
}

output "key_vault_reachable_from" {
  description = "Who can reach the vault's data plane, in plain language."
  value       = module.key_vault.reachable_from
}

output "key_vault_private_endpoint_ip" {
  description = "Private IP the vault resolves to from inside the VNet."
  value       = module.key_vault.private_endpoint_ip
}

output "key_vault_granted_principals" {
  description = "Who holds which role on the vault — a single artefact for reviewing secret access."
  value       = module.key_vault.granted_principal_ids
}

################################################################################
# Storage
################################################################################

output "storage_account_name" {
  description = "Storage account name."
  value       = module.storage.name
}

output "storage_blob_endpoint" {
  description = "Blob endpoint. Resolves privately from inside the VNet, and to the firewalled public endpoint from the operator allowlist."
  value       = module.storage.primary_blob_endpoint
}

output "storage_reachable_from" {
  description = "Who can reach the storage data plane, in plain language."
  value       = module.storage.reachable_from
}

output "storage_private_endpoint_ips" {
  description = "Map of sub-resource to private IP inside the VNet."
  value       = module.storage.private_endpoint_ips
}

################################################################################
# SQL
################################################################################

output "sql_server_fqdn" {
  description = "SQL server FQDN. Resolves to the private endpoint inside the VNet and to the firewalled public endpoint from the operator allowlist."
  value       = module.sql.server_fqdn
}

output "sql_connection_guidance" {
  description = "How to connect. No password, because no SQL login exists — applications present a managed identity."
  value       = module.sql.connection_guidance
}

output "sql_reachable_from" {
  description = "Who can reach the SQL server, in plain language."
  value       = module.sql.reachable_from
}

output "sql_backup_summary" {
  description = "Effective backup posture."
  value       = module.sql.backup_summary
}

output "sql_admin_is_individual" {
  description = "True when the Entra SQL administrator is a named user rather than a group — a governance weakness worth resolving in any shared subscription."
  value       = module.sql.administrator_is_individual
}
