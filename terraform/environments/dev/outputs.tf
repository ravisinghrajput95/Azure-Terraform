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
