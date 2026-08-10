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
  compute_tier_count      = 2
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

      subnet_ids = [
        module.networking.subnet_ids[local.app_subnet],
        module.networking.subnet_ids[local.biz_subnet],
        module.networking.subnet_ids[local.db_subnet],
        module.networking.subnet_ids[local.pep_subnet],
        module.networking.subnet_ids[local.mgmt_subnet],
      ]
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
  services = ["keyvault", "blob", "sql", "redis"]

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
