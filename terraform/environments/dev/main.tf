################################################################################
# dev environment
#
# This root module is a composition layer only. It contains no resource blocks
# of its own — every resource comes from a module in ../../modules. That
# separation is what lets the same modules build test and prod from different
# variable values rather than different code.
#
# The environment name is a local, not a variable. A root module IS its
# environment; making it configurable would allow `terraform apply -var
# environment=prod` against the dev state file.
################################################################################

locals {
  environment = "dev"
}

################################################################################
# Foundation — naming, tags and profile
#
# All three are provider-free pure computation. They resolve before any Azure
# call is made, so a naming violation or an incoherent profile fails the plan
# in under a second rather than partway through an apply.
################################################################################

module "naming" {
  source = "../../modules/naming"

  workload    = var.workload
  environment = local.environment
  location    = var.location

  # Mixing the subscription ID into the hash means the globally-unique names
  # (storage, Key Vault, SQL, Redis) differ between subscriptions, so two
  # people deploying this repo do not collide.
  unique_seed = var.subscription_id
}

module "tags" {
  source = "../../modules/tags"

  workload            = var.workload
  environment         = local.environment
  owner               = var.owner
  cost_center         = var.cost_center
  criticality         = var.criticality
  data_classification = var.data_classification
}

module "profile" {
  source = "../../modules/profile"

  environment             = local.environment
  overrides               = var.profile_overrides
  subscription_vcpu_quota = var.subscription_vcpu_quota

  # One, not two. The VM Scale Set design had an app tier and a biz tier, each
  # its own scale set. AKS replaces both with a single cluster whose node pools
  # share the quota, so counting two tiers would double both the vCPU footprint
  # and the cost estimate.
  compute_tier_count = 1
}

################################################################################
# Phase 1 — resource groups
#
# One group per lifecycle scope: net, sec, data, app, mon. See
# docs/ARCHITECTURE.md section 1.2 for why these are separated.
#
# Locks are driven by the profile and are off in dev, so `terraform destroy`
# works — the primary cost control on a credit-limited subscription.
################################################################################

module "resource_group" {
  source = "../../modules/resource-group"

  resource_group_names  = module.naming.resource_group_names
  location              = module.naming.location_normalized
  tags                  = module.tags.tags
  enable_resource_locks = module.profile.enable_resource_locks
}

################################################################################
# Phase 1 — Log Analytics
#
# Created before anything that emits telemetry, because a diagnostic setting
# cannot be created before its destination exists.
#
# Lives in the monitoring resource group, not the application group, so that
# destroying the app stack does not destroy its own audit trail.
#
# The workspace itself is free. Cost comes from ingestion volume, which is
# capped at 0.5 GB/day by the dev profile to stay inside the free 5 GB/month
# allowance.
################################################################################

module "log_analytics" {
  source = "../../modules/log-analytics"

  name                = module.naming.names.log_analytics_workspace
  resource_group_name = module.resource_group.names["mon"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  retention_in_days = module.profile.profile.log_retention_days
  daily_quota_gb    = module.profile.profile.log_daily_quota_gb
}

################################################################################
# Phase 1 — diagnostics on the workspace itself
#
# The workspace audits its own access and query activity. Collecting that is
# what makes "who read the logs" answerable, which matters precisely when
# someone is investigating whether logs were tampered with.
#
# This is also the first exercise of the shared diagnostics module. Every
# resource from Phase 2 onward routes through the same module rather than
# declaring its own diagnostic setting.
################################################################################

module "diagnostics_log_analytics" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.log_analytics.id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 2 — network
#
# Address plan per docs/NETWORKING.md. dev occupies 10.10.0.0/16; test and prod
# take 10.20.0.0/16 and 10.30.0.0/16, spaced so a future peering cannot
# collide.
#
# Deployed here are only the subnets dev actually uses. The reserved ranges —
# AzureFirewallSubnet 10.10.0.0/26, AzureFirewallManagementSubnet 10.10.0.64/26,
# GatewaySubnet 10.10.0.192/26 and snet-agw 10.10.1.0/24 — are held by the
# address plan and simply not allocated, so adding a firewall or Application
# Gateway later needs no renumbering.
#
# Egress is the NAT Gateway: roughly $33/month, against roughly $912 for Azure
# Firewall. This is the first resource in the platform that carries a real
# recurring charge.
################################################################################

locals {
  subnet_names = module.naming.subnet_names

  vnet_address_space = ["10.10.0.0/16"]
}

module "networking" {
  source = "../../modules/networking"

  vnet_name           = module.naming.names.virtual_network
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  address_space = local.vnet_address_space

  subnets = {
    # Operator access. The name is fixed by Azure and the /26 is its minimum.
    # No NAT Gateway association: Bastion manages its own outbound path, and
    # associating one breaks the service.
    AzureBastionSubnet = {
      cidr = "10.10.0.128/26"
    }

    # Application tier. /22 rather than /24 because a scale set doing a rolling
    # upgrade at scale transiently needs more addresses than instances, and a
    # subnet holding resources cannot be resized.
    (local.subnet_names["app"]) = {
      cidr                  = "10.10.4.0/22"
      associate_nat_gateway = true
    }

    (local.subnet_names["biz"]) = {
      cidr                  = "10.10.8.0/22"
      associate_nat_gateway = true
    }

    # Reserved for a future IaaS database. PaaS SQL reaches the VNet through a
    # private endpoint, so nothing lands here today.
    (local.subnet_names["db"]) = {
      cidr                  = "10.10.12.0/24"
      associate_nat_gateway = true
    }

    # Private endpoint NICs. "NetworkSecurityGroupEnabled" is required for NSG
    # rules to apply — historically NSGs were ignored on private endpoint
    # subnets, and leaving this Disabled means the rules written for it are
    # silently never enforced.
    (local.subnet_names["pep"]) = {
      cidr                              = "10.10.13.0/24"
      private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
      associate_nat_gateway             = true
    }

    # Kubernetes node subnet, from the range docs/NETWORKING.md reserved for a
    # container platform. Under Azure CNI Overlay this holds NODE addresses
    # only — pods draw from pod_cidr, routed inside the cluster. Classic CNI
    # would consume one subnet address per pod and cap the cluster at the
    # subnet size.
    "snet-aks-dev-cus" = {
      cidr                  = "10.10.16.0/20"
      associate_nat_gateway = true
    }

    (local.subnet_names["mgmt"]) = {
      cidr                  = "10.10.14.0/24"
      associate_nat_gateway = true
    }
  }

  enable_nat_gateway         = module.profile.enable_nat_gateway
  nat_gateway_name           = module.naming.names.nat_gateway
  nat_gateway_public_ip_name = "pip-ng-${module.naming.base}-001"
}

module "diagnostics_vnet" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.networking.vnet_id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 2 — network security groups
#
# The rule matrix lives in nsg-rules.tf so the environment's security policy is
# reviewable as one artefact rather than spread through module wiring.
################################################################################

module "nsg" {
  source = "../../modules/nsg"

  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  network_security_groups = local.nsg_definitions
}

module "diagnostics_nsg" {
  source   = "../../modules/diagnostics"
  for_each = module.nsg.ids

  target_resource_id         = each.value
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 2 — route tables
#
# The routing set depends entirely on how egress is provided, which is why
# module.profile.egress_strategy exists as a string rather than a boolean.
#
#   "firewall"     0.0.0.0/0 -> VirtualAppliance at the firewall's private IP.
#                  Every workload subnet is forced through inspection.
#
#   "nat_gateway"  NO routes at all. A NAT Gateway attaches directly to the
#                  subnet and is NOT a UDR next hop — adding a 0.0.0.0/0 route
#                  pointing anywhere would override it and break egress.
#
# dev uses NAT Gateway, so this table is deliberately empty. It is still
# created and attached, because disabling BGP route propagation is itself a
# control: without it, an ExpressRoute or VPN gateway attached later could
# advertise a more specific route that diverts egress, defeating the intended
# path with no change to this configuration.
#
# AzureBastionSubnet is deliberately NOT associated. A default route there
# breaks Bastion, and the module rejects the combination outright.
################################################################################

module "route_table" {
  source = "../../modules/route-table"

  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  # The Application Gateway subnet name is added to the reserved list because
  # AppGW v2 requires direct control-plane access; a default route there makes
  # the gateway report permanently unhealthy.
  subnets_forbidding_default_route = [
    "AzureBastionSubnet",
    "AzureFirewallSubnet",
    "AzureFirewallManagementSubnet",
    "GatewaySubnet",
    "RouteServerSubnet",
    "snet-agw-${local.environment}-${module.naming.location_short}",
  ]

  route_tables = {
    (module.naming.names.route_table_workload) = {
      bgp_route_propagation_enabled = false

      routes = module.profile.egress_strategy == "firewall" ? {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = var.firewall_private_ip
        }
      } : {}

      # Keyed by subnet NAME so the for_each key set is known at plan time and
      # the forbidden-default-route check compares names rather than parsing
      # them out of IDs that are unknown until apply.
      subnets = {
        (local.app_subnet)  = module.networking.subnet_ids[local.app_subnet]
        (local.biz_subnet)  = module.networking.subnet_ids[local.biz_subnet]
        (local.db_subnet)   = module.networking.subnet_ids[local.db_subnet]
        (local.pep_subnet)  = module.networking.subnet_ids[local.pep_subnet]
        (local.mgmt_subnet) = module.networking.subnet_ids[local.mgmt_subnet]
        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]
      }
    }
  }
}

################################################################################
# Phase 2 — private DNS zones
#
# Created before any private endpoint exists, because ordering here is a
# security control rather than a convenience.
#
# A private endpoint whose DNS zone group finds no matching zone registers no A
# record. The client then falls back to public DNS and resolves the service to
# its PUBLIC address from inside the VNet. The endpoint exists, the NSG permits
# it, the diagram is correct — and traffic leaves the network.
#
# Zones are selected by service key rather than by name, so a mistyped zone
# name — which has no error path in Azure — is impossible.
#
# They live in the networking resource group, not data: zones outlive the
# individual services that register into them, and destroying the data tier
# must not orphan them.
################################################################################

module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = module.resource_group.names["net"]
  tags                = module.tags.tags

  # Phase 3 and 4 consumers: Key Vault, Storage (blob), SQL and Redis.
  # managed_redis, not redis: Azure Cache for Redis is retiring and Azure
  # Managed Redis uses a different privatelink zone
  # (privatelink.redis.azure.net vs privatelink.redis.cache.windows.net).
  services = ["keyvault", "blob", "sql", "managed_redis"]

  virtual_network_ids = {
    (module.networking.vnet_name) = module.networking.vnet_id
  }

  # VMSS instances must not self-register into a zone Azure manages on behalf
  # of private endpoints, and the single registration-enabled link a VNet is
  # allowed should not be spent here.
  registration_enabled = false
}

################################################################################
# Phase 2 — Azure Bastion
#
# Operator access to instances that carry no public IP and accept SSH from
# nowhere except the Bastion subnet. This is what makes the "no public compute"
# position workable rather than merely stated.
#
# dev uses the Developer SKU: no charge, but a shared regional instance that
# attaches by VNet ID rather than consuming AzureBastionSubnet, and offers
# browser sessions only — no native client tunneling, no file copy, no peered
# VNet access.
#
# AzureBastionSubnet and its mandated NSG rules were created in modules 7 and 8
# and stay empty, held in reserve so a later move to Standard needs no network
# change.
################################################################################

module "bastion" {
  source = "../../modules/bastion"
  count  = module.profile.enable_bastion ? 1 : 0

  name                = module.naming.names.bastion
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku = module.profile.profile.bastion_sku

  # Developer attaches by VNet; Basic and above take the subnet and a public IP.
  # The module rejects a mismatched pairing at plan time.
  virtual_network_id = module.profile.profile.bastion_sku == "Developer" ? module.networking.vnet_id : null
  subnet_id          = module.profile.profile.bastion_sku == "Developer" ? null : module.networking.subnet_ids[local.bastion_subnet]
  public_ip_name     = module.profile.profile.bastion_sku == "Developer" ? null : "pip-bas-${module.naming.base}-001"
}

################################################################################
# Phase 3 — managed identities
#
# One user-assigned identity per compute tier, created before Key Vault and
# Storage because those modules' role assignments reference these principal IDs.
#
# User-assigned rather than system-assigned: a system-assigned identity is
# destroyed with its resource, so every scale set replacement would produce a
# new principal ID and silently invalidate every grant pointing at the old one.
# A routine instance refresh would remove the application's access to its own
# secrets.
#
# One identity per tier rather than one shared: network isolation without
# identity isolation makes the NSG boundary decorative, because anything
# reaching a tier inherits that tier's entire access footprint.
#
# No role assignments here. The key-vault and storage modules grant access
# scoped to themselves, so a grant dies with the resource it protects rather
# than outliving it as an orphan.
################################################################################

module "managed_identity" {
  source = "../../modules/managed-identity"

  resource_group_name = module.resource_group.names["sec"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  identities = module.naming.managed_identity_names
}

################################################################################
# Phase 3 — Key Vault
#
# RBAC authorization only. The legacy access policy model is not used anywhere
# in this platform: policies do not compose with Azure RBAC, are invisible to
# `az role assignment list` and to standard access reviews, and must be
# repeated per vault rather than assigned once at a higher scope.
#
# Reachability in dev is deliberately hybrid, and the reasoning is worth
# stating because it looks like a weaker posture than it is:
#
#   - A private endpoint carries in-VNet traffic. Applications use the standard
#     vault URI and the private DNS zone makes it resolve privately.
#   - The public endpoint stays enabled but denies by default, permitting only
#     the operator's IP.
#
# Key Vault secrets are managed over the DATA plane. With public access fully
# disabled, a laptop outside the VNet — and Terraform running on it — cannot
# read or write a secret at all. In dev that would mean no way to verify a
# deployment without a jump host for every check. test and prod set
# data_plane_public_access_enabled = false, because their pipelines run inside
# the network.
#
# Purge protection is OFF in dev. It is irreversible, and since naming produces
# a deterministic vault name, enabling it would block rebuilding the
# environment for the full retention period.
################################################################################

data "azurerm_client_config" "current" {}

module "key_vault" {
  source = "../../modules/key-vault"

  name                = module.naming.key_vault_name
  resource_group_name = module.resource_group.names["sec"]
  location            = module.resource_group.location
  tags                = module.tags.tags
  tenant_id           = data.azurerm_client_config.current.tenant_id

  purge_protection_enabled   = module.profile.profile.key_vault_purge_protection
  soft_delete_retention_days = module.profile.profile.key_vault_soft_delete_retention_days

  public_network_access_enabled = module.profile.data_plane_public_access_enabled
  network_acls_default_action   = "Deny"
  allowed_ip_rules              = var.deployer_ip_addresses

  private_endpoint_subnet_id = module.networking.subnet_ids[local.pep_subnet]
  private_endpoint_name      = "pep-kv-${module.naming.base}-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["keyvault"]]

  role_assignments = merge(
    # Each tier reads its own secrets. Secrets User is read-only: the
    # application can fetch a secret and cannot create, update or delete one.
    {
      for tier, principal_id in module.managed_identity.principal_ids :
      "tier-${tier}" => {
        principal_id         = principal_id
        role_definition_name = "Key Vault Secrets User"
        principal_type       = "ServicePrincipal"
        description          = "Read-only secret access for the ${tier} tier."
      }
    },
    # The deploying operator needs to manage secrets. Administrator rather than
    # Secrets Officer because certificates and keys are managed here too.
    {
      deployer = {
        principal_id         = data.azurerm_client_config.current.object_id
        role_definition_name = "Key Vault Administrator"
        principal_type       = "User"
        description          = "Operator managing secrets, keys and certificates."
      }
    },
  )

  # Ordering, not decoration: the identities' principals must have propagated
  # through Entra ID before role assignments referencing them are created.
  depends_on = [module.managed_identity]
}

module "diagnostics_key_vault" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.key_vault.id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 3 — Storage
#
# Same reachability model as Key Vault: private endpoint for in-VNet traffic,
# plus a public endpoint that denies by default and permits only the operator
# IP, driven by the profile.
#
# The account-specific control is shared_access_key_enabled = false. Storage
# account keys are the most frequently leaked Azure credential — static, never
# expiring, impossible to scope to a container or an operation, and granting
# total control of the account to anyone holding one. They end up in connection
# strings, CI variables, appsettings files and support tickets.
#
# Disabling them has a consequence worth stating: every data-plane caller,
# including Terraform, must hold a DATA-plane RBAC role. Subscription Owner is
# not sufficient — Owner is a control-plane role and receives 403 on a
# container list.
#
# allow_nested_items_to_be_public = false forecloses anonymous blob access
# account-wide regardless of any per-container setting.
################################################################################

module "storage" {
  source = "../../modules/storage"

  name                = module.naming.storage_account_name
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  account_replication_type = module.profile.profile.storage_replication_type
  blob_versioning_enabled  = module.profile.profile.storage_enable_versioning

  shared_access_key_enabled = false

  public_network_access_enabled = module.profile.data_plane_public_access_enabled
  network_rules_default_action  = "Deny"
  allowed_ip_rules              = var.deployer_ip_addresses

  private_endpoint_subnet_id    = module.networking.subnet_ids[local.pep_subnet]
  private_endpoint_name_prefix  = "pep-st-${module.naming.base}"
  private_endpoint_subresources = ["blob"]

  private_dns_zone_ids_by_subresource = {
    blob = [module.private_dns.zone_ids_by_service["blob"]]
  }

  role_assignments = merge(
    # Tiers read and write application data.
    {
      for tier, principal_id in module.managed_identity.principal_ids :
      "tier-${tier}" => {
        principal_id         = principal_id
        role_definition_name = "Storage Blob Data Contributor"
        principal_type       = "ServicePrincipal"
        description          = "Blob read/write for the ${tier} tier."
      }
    },
    # The deploying operator needs data-plane access to create containers,
    # because with shared keys disabled that is an Entra-authenticated call.
    {
      deployer = {
        principal_id         = data.azurerm_client_config.current.object_id
        role_definition_name = "Storage Blob Data Owner"
        principal_type       = "User"
        description          = "Operator managing containers and blob data."
      }
    },
  )

  containers = {
    "app-data" = {}
  }

  depends_on = [module.managed_identity]
}

module "diagnostics_storage" {
  source = "../../modules/diagnostics"

  # Diagnostics for storage attach to the SERVICE, not the account: the account
  # resource itself exposes only metrics. Blob logs live at
  # <account-id>/blobServices/default.
  target_resource_id         = "${module.storage.id}/blobServices/default"
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 4 — Azure SQL
#
# The strongest security position in this platform: azuread_authentication_only
# means there is NO SQL login. No password is generated, so none is written to
# Terraform state in plaintext, none is stored in Key Vault, none is rotated,
# and none can leak. That is stronger than "no hardcoded secrets" — the secret
# does not exist.
#
# The trade-off is real: database access is then governed by Entra ID group
# membership, which lives outside this repository. Granting access becomes a
# directory operation rather than a Terraform change.
#
# dev uses GP_S_Gen5_1 — serverless, verified available in eastus on this
# subscription. It bills per second of compute and pauses after 60 minutes
# idle, so a database used a few hours a day costs close to storage alone. The
# cost is a cold start of several seconds on the first connection after a
# pause.
################################################################################

module "sql" {
  source = "../../modules/sql"

  server_name         = module.naming.sql_server_name
  database_name       = module.naming.names.sql_database
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  # Defaults to the deploying user when no group is supplied. In a shared
  # subscription this should be a group — see the administrator_is_individual
  # output, which flags the weakness rather than silently accepting it.
  entra_administrator_login     = coalesce(var.sql_entra_admin_login, data.azurerm_client_config.current.object_id)
  entra_administrator_object_id = coalesce(var.sql_entra_admin_object_id, data.azurerm_client_config.current.object_id)
  entra_administrator_is_group  = var.sql_entra_admin_is_group
  azuread_authentication_only   = true

  sku_name                    = module.profile.profile.sql_sku_name
  zone_redundant              = module.profile.profile.sql_zone_redundant
  short_term_retention_days   = module.profile.profile.sql_backup_retention_days
  long_term_retention_enabled = module.profile.profile.sql_enable_long_term_retention

  max_size_gb          = 32
  storage_account_type = "Local"
  geo_backup_enabled   = false

  public_network_access_enabled = module.profile.data_plane_public_access_enabled

  allowed_ip_rules = {
    for index, ip in var.deployer_ip_addresses :
    "operator-${index}" => { start_ip = ip, end_ip = ip }
  }

  private_endpoint_subnet_id = module.networking.subnet_ids[local.pep_subnet]
  private_endpoint_name      = "pep-sql-${module.naming.base}-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["sql"]]
}

module "diagnostics_sql" {
  source = "../../modules/diagnostics"

  # Diagnostics attach to the DATABASE, not the logical server. The server
  # resource exposes almost nothing; the query, wait and deadlock telemetry
  # worth having lives on the database.
  target_resource_id         = module.sql.database_id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 4 — Azure Cache for Redis
#
# Azure Cache for Redis is RETIRING — its API rejects creation outright — so
# this uses Azure Managed Redis (Microsoft.Cache/redisEnterprise) instead.
# Zone redundancy, clustering and data persistence are all Premium-only, and
# Premium is roughly $412/month against $16 for Basic C0 — so dev proves the
# wiring, the authentication model and the private path, but not the
# availability behaviour.
#
# Basic is a SINGLE NODE with NO SLA: a host fault or a routine restart loses
# the entire cache with no replica to fail over to. That is acceptable here
# only because the cache is an accelerator and a cold start is survivable. The
# availability_summary output states this plainly rather than leaving it
# implicit in the SKU name.
#
# Access keys are disabled. Redis keys have the same weaknesses as storage
# account keys — static, non-expiring, unscopable, total control — and Redis 6+
# supports Entra ID authentication instead.
################################################################################

module "redis" {
  source = "../../modules/redis"
  count  = module.profile.enable_redis ? 1 : 0

  name                = module.naming.redis_name
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_name                  = module.profile.profile.redis_sku_name
  high_availability_enabled = module.profile.profile.redis_high_availability

  # Entra ID only, TLS only.
  access_keys_authentication_enabled = false
  client_protocol                    = "Encrypted"

  # With access keys disabled, an access policy assignment is the ONLY path to
  # the data plane. Each tier's identity gets one; without it nothing could
  # connect at all.
  access_policy_assignments = {
    for tier, principal_id in module.managed_identity.principal_ids :
    "tier-${tier}" => { principal_id = principal_id }
  }

  # No public endpoint at all. Unlike Key Vault and Storage, nothing in this
  # platform needs to reach Redis from an operator machine — there are no
  # secrets to manage and no containers to create, so the private endpoint is
  # the only path required.
  public_network_access_enabled = false

  create_private_endpoint    = true
  private_endpoint_subnet_id = module.networking.subnet_ids[local.pep_subnet]
  private_endpoint_name      = "pep-redis-${module.naming.base}-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["managed_redis"]]
}

module "diagnostics_redis" {
  source   = "../../modules/diagnostics"
  for_each = module.profile.enable_redis ? { this = module.redis[0].id } : {}

  target_resource_id         = each.value
  log_analytics_workspace_id = module.log_analytics.id
}





################################################################################
# Phase 5 — Azure Kubernetes Service
#
# Replaces the VM Scale Set tiers. The consequence worth naming rather than
# glossing: the three-tier boundary MOVES. Where the app and biz tiers were
# separate subnets with an NSG between them that Azure enforced at the network
# layer, they are now namespaces separated by a Kubernetes network policy that
# the cluster enforces. Trust moves from the platform into the cluster, which
# is why network_policy is not optional in the module.
#
# dev's cluster is deliberately NOT highly available, and the reason is
# arithmetic:
#
#   3 nodes across 3 zones = 6 vCPU   quota is 4        OVER
#   2 nodes                = 4 vCPU   6 during upgrade  OVER
#   1 node                 = 2 vCPU   4 during upgrade  fits
#
# AKS adds a surge node during upgrades, so even two nodes would leave the
# cluster unpatchable. A single-node system pool is what fits. The
# availability_summary output states this plainly so it never reads as
# production-shaped.
#
# The API server is public with the operator IP allowlisted. Private is the
# correct posture and is what test and prod use — but it means kubectl only
# works from inside the VNet or through Bastion, the same trade-off already
# made for the Key Vault data plane.
################################################################################

module "aks" {
  source = "../../modules/aks"

  name                = "aks-${module.naming.base}-001"
  dns_prefix          = "${var.workload}-${local.environment}"
  resource_group_name = module.resource_group.names["app"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_tier = module.profile.profile.aks_sku_tier

  system_node_pool = {
    vm_size    = module.profile.profile.vm_size
    node_count = module.profile.profile.instance_count
    zones      = module.profile.profile.compute_zones

    # Cannot taint the system pool when it is the only pool — nothing would be
    # schedulable. The module rejects that combination.
    only_critical_addons_taint = module.profile.enable_user_node_pool
  }

  user_node_pools = module.profile.enable_user_node_pool ? {
    app = {
      vm_size              = module.profile.profile.vm_size
      auto_scaling_enabled = true
      min_count            = module.profile.profile.user_node_pool_min_count
      max_count            = module.profile.profile.user_node_pool_max_count
      zones                = module.profile.profile.compute_zones
    }
  } : {}

  vnet_subnet_id = module.networking.subnet_ids["snet-aks-dev-cus"]

  # Azure CNI Overlay. pod_cidr and service_cidr are routed inside the cluster
  # only and must not overlap 10.10.0.0/16 or anything peered to it.
  network_plugin      = "azure"
  network_plugin_mode = "overlay"
  network_policy      = module.profile.profile.aks_network_policy
  pod_cidr            = "192.168.0.0/16"
  service_cidr        = "172.16.0.0/16"
  dns_service_ip      = "172.16.0.10"

  # The networking module already attached a NAT Gateway to this subnet, so
  # the cluster uses it rather than provisioning its own egress.
  #
  # NOT "userDefinedRouting" — that is the Azure Firewall topology and requires
  # a route table carrying an egress route. Choosing it here fails at create
  # time with ExistingRouteTableNotAssociatedWithSubnet, an error that names
  # the route table rather than the setting.
  outbound_type = "userAssignedNATGateway"

  private_cluster_enabled         = module.profile.aks_private_cluster
  api_server_authorized_ip_ranges = [for ip in var.deployer_ip_addresses : "${ip}/32"]

  # The nodes egress through the NAT Gateway, so the API server allowlist has to
  # admit the gateway's public IP as well as the operator's. AKS only appends
  # its own egress address when it owns the outbound path, which with
  # userAssignedNATGateway it does not — see the module precondition.
  node_egress_ip_ranges = ["${module.networking.nat_gateway_public_ip}/32"]

  # Entra ID only. The local admin account authenticates with a certificate
  # that cannot be rotated or attributed to a person.
  local_account_disabled       = true
  entra_admin_group_object_ids = var.aks_admin_group_object_ids
  azure_rbac_enabled           = true

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  log_analytics_workspace_id = module.log_analytics.id
}

module "diagnostics_aks" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.aks.id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Alerting
#
# Deployed last, after everything it observes exists, so bringing the
# environment up does not fire alerts about resources that are still coming up.
#
# Lands in the monitoring resource group rather than the app group, so
# destroying the app stack leaves the alerting — and its history — intact.
#
# count comes from profile, which is pure computation over variables, so it
# stays statically known and survives a cold apply.
################################################################################

module "monitor" {
  source = "../../modules/monitor"

  count = module.profile.enable_alerts ? 1 : 0

  action_group_name       = module.naming.names.action_group
  action_group_short_name = "ccrt-${local.environment}"
  resource_group_name     = module.resource_group.names["mon"]
  location                = var.location
  tags                    = module.tags.tags

  # owner is already an accountable address, so alerting works without a second
  # place to keep an email in sync.
  email_receivers = {
    owner = coalesce(var.alert_email_address, var.owner)
  }

  cluster_id        = module.aks.id
  alert_name_prefix = "alrt-${module.naming.base}"

  # dev's system pool has autoscaling off, so the cluster autoscaler component
  # is not running and publishes none of its metrics. A rule on one of them
  # would be created, look healthy, and never fire.
  cluster_autoscaler_enabled = module.profile.enable_autoscale

  # Measured, not guessed. A healthy single-node dev cluster runs a standing 2
  # pods in Pending — DaemonSet replicas with no second node to land on — while
  # 25 run normally. A threshold of 0 would therefore fire permanently from the
  # moment it deployed, which disables an alert as effectively as never firing.
  # 3 is the first value that means something changed.
  threshold_overrides = {
    pods-pending = 3
  }
}

################################################################################
# Backup
#
# The vault and its policies, protecting NOTHING — see the module README.
# Compute is AKS, so the VM Scale Sets this was designed to back up never
# existed; SQL carries its own retention, and storage is blob-only with
# versioning and soft delete already on.
#
# Deliberately NOT gated on profile.enable_backup. That flag governs whether
# workloads are protected, and this module never protects anything. The vault
# and policies are free, so they are deployed and verifiable here, ready for
# whatever qa, stage or production later put in front of them.
#
# LocallyRedundant is explicit: Azure defaults to GeoRedundant, which costs
# materially more, and the setting cannot be changed once anything is
# protected.
################################################################################

module "recovery_services" {
  source = "../../modules/recovery-services"

  name                = module.naming.names.recovery_services_vault
  resource_group_name = module.resource_group.names["mon"]
  location            = var.location
  tags                = module.tags.tags

  storage_mode_type = "LocallyRedundant"

  vm_backup_policies = {
    "bp-vm-daily" = {
      frequency       = "Daily"
      time            = "23:00"
      timezone        = "UTC"
      retention_daily = module.profile.profile.backup_retention_days
    }
  }
}
