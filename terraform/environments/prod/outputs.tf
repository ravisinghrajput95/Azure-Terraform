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
  description = "Scopes carrying a management lock. A lock blocks terraform destroy, so the profile turns them off where an environment is meant to be torn down and on where it is not."
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
  description = "Shared name base, e.g. \"cloudcart-prod-cus\"."
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
  description = "Whether a daily ingestion cap is active. FALSE in prod: a cap stops ingestion once hit and drops everything after, which in a test environment means losing the evidence for whatever was being tested. Ingestion is billed here rather than capped."
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
  description = "Route tables forcing egress through a virtual appliance. Empty where egress is by NAT Gateway — one attaches to the subnet directly and is not a UDR next hop — and populated where an Azure Firewall is the next hop."
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

################################################################################
# Redis
################################################################################

output "redis_hostname" {
  description = "Cache hostname. Resolves to the private endpoint inside the VNet."
  value       = try(module.redis[0].hostname, null)
}

output "redis_connection_guidance" {
  description = "How to connect. No password — access keys are disabled and clients present a managed identity."
  value       = try(module.redis[0].connection_guidance, null)
}

output "redis_availability_summary" {
  description = "Plain-language availability posture of the deployed tier."
  value       = try(module.redis[0].availability_summary, null)
}

output "redis_reachable_from" {
  description = "Who can reach the cache, in plain language."
  value       = try(module.redis[0].reachable_from, null)
}

################################################################################
# Kubernetes
################################################################################

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.name
}

output "aks_fqdn" {
  description = "API server FQDN."
  value       = module.aks.fqdn
}

output "aks_availability_summary" {
  description = "Plain-language availability posture of the deployed cluster."
  value       = module.aks.availability_summary
}

output "aks_security_summary" {
  description = "Consolidated security posture of the cluster."
  value       = module.aks.security_summary
}

output "aks_api_server_reachable_from" {
  description = "Who can reach the Kubernetes API server."
  value       = module.aks.api_server_reachable_from
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL. A federated identity credential on a user-assigned identity references this plus a service account subject, which is what lets a pod authenticate as that identity with no secret."
  value       = module.aks.oidc_issuer_url
}

output "aks_kubelet_identity_object_id" {
  description = "Kubelet identity — the one that pulls images. An ACR pull role assignment goes here, not on the control plane identity."
  value       = module.aks.kubelet_identity_object_id
}

output "aks_get_credentials_command" {
  description = "Command to configure kubectl against this cluster. NOTE: this cluster is PRIVATE, so this only works from inside the VNet — via Bastion, or from a runner on a workload subnet. From outside, the command succeeds and every subsequent call times out resolving the API server, which reads like a network fault rather than a topology decision."
  value       = "az aks get-credentials --resource-group ${module.resource_group.names["app"]} --name ${module.aks.name}"
}

################################################################################
# Egress
#
# The reason this environment exists. dev and qa report an egress address;
# prod reports an inspection point.
################################################################################

output "firewall_private_ip" {
  description = "The firewall's private address — the VirtualAppliance next hop every workload subnet default-routes to."
  value       = module.profile.enable_firewall ? module.firewall[0].private_ip_address : null
}

output "firewall_public_ip" {
  description = "The public address the internet sees for every workload routed through the firewall. This is what an external allowlist needs, and what the AKS API server allowlist is populated with."
  value       = module.profile.enable_firewall ? module.firewall[0].public_ip_address : null
}

output "firewall_security_summary" {
  description = "Firewall posture in plain language, including the states that read as protection and are not: threat intelligence in Alert mode, IDPS absent or alerting, and network rules that shadow the application rules beneath them."
  value       = module.profile.enable_firewall ? module.firewall[0].security_summary : "no firewall — egress is unfiltered"
}

output "egress_is_inspected" {
  # conformance:cross-env-ok
  description = "Whether workload egress passes through a firewall rather than a NAT Gateway. False means any pod can reach any internet address, which is dev's and qa's posture."
  value       = module.profile.egress_strategy == "firewall"
}

################################################################################
# Ingress
################################################################################

output "application_gateway_public_ip" {
  description = "Public IP of the Application Gateway, the only ingress path into this environment."
  value       = module.profile.enable_application_gateway ? module.application_gateway[0].public_ip_address : null
}

output "ingress_is_encrypted" {
  description = "TLS posture of the ingress path, in plain language — a sentence, not a boolean, despite the name. \"HTTP ONLY\" means no TLS certificate was supplied and the gateway was deployed with an HTTP listener alone: a deliberate degraded mode, reported rather than left to be discovered."
  value = !module.profile.enable_application_gateway ? "no Application Gateway deployed" : (
    local.agw_has_certificate
    ? "HTTPS with a Key Vault certificate; HTTP redirects to it"
    : "HTTP ONLY — no certificate supplied. Set application_gateway_certificate_secret_id."
  )
}

output "waf_posture" {
  description = "WAF mode in plain language. Detection LOGS what Prevention would have blocked and blocks nothing, which is the right starting point for an untuned rule set and the wrong place to stop."
  value = !module.profile.enable_application_gateway ? "no WAF" : (
    module.profile.profile.waf_mode == "Prevention"
    ? "Prevention: matching requests are BLOCKED."
    : "Detection: matching requests are LOGGED and ALLOWED THROUGH. The WAF is observing, not enforcing."
  )
}

################################################################################
# Alerting
################################################################################

output "alerting_coverage" {
  description = "Alerting posture in plain language, including the degraded states. Null when alerts are disabled for this environment."
  value       = one(module.monitor[*].coverage_summary)
}

output "alert_metrics_monitored" {
  description = "Map of alert key to the AKS metric it watches, for confirming coverage without opening the portal."
  value       = one(module.monitor[*].metrics_monitored)
}

output "alert_action_group_id" {
  description = "Action group any additional alert rule should attach to."
  value       = one(module.monitor[*].action_group_id)
}

################################################################################
# Backup
################################################################################

output "backup_posture" {
  description = "Backup posture in plain language. This environment deploys a vault and policies and protects nothing — see the recovery-services module README for why."
  value       = module.recovery_services.backup_posture_summary
}

output "backup_vault_name" {
  description = "Recovery Services vault name. A protected VM or file share references the vault by name plus resource group."
  value       = module.recovery_services.name
}
