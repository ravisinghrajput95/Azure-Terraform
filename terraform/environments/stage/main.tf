################################################################################
# stage environment
#
# This root module is a composition layer only. It contains no resource blocks
# of its own — every resource comes from a module in ../../modules. That
# separation is what lets the same modules build dev and prod from different
# variable values rather than different code.
#
# The environment name is a local, not a variable. A root module IS its
# environment; making it configurable would allow `terraform apply -var
# environment=prod` against the stage state file.
#
# ---------------------------------------------------------------------------
# THIS ENVIRONMENT CANNOT BE APPLIED ON THE CURRENT SUBSCRIPTION, AND ITS
# EGRESS PATH HAS NEVER RUN ANYWHERE.
#
# stage is the first environment whose egress goes through an Azure Firewall
# rather than a NAT Gateway. That is the reason it exists -- the topology, the
# UDRs and the egress rules are what it validates, and none of them are
# exercised by dev or qa.
#
# It is also why stage is doubly unverified: the `firewall` module it depends
# on has never been applied either, because an Azure Firewall is roughly
# $913/month against a $200 credit. Compute alone needs 10 vCPU at steady state
# against a regional quota of 4.
#
# The configuration is complete and plans; nothing here has run. See README.md.
# ---------------------------------------------------------------------------
################################################################################

locals {
  environment = "stage"
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
# Naming derived once
#
# dev writes several of these as literals ("snet-aks-dev-cus", "nsg-aks-dev-cus",
# and a bastion NSG that says "eus" while the environment runs in Central US).
# They are derived here instead: an environment name embedded in a string is
# exactly the kind of thing that survives a copy between environments and then
# points at the wrong resource.
################################################################################

locals {
  loc = module.naming.location_short

  aks_subnet_name  = "snet-aks-${local.environment}-${local.loc}"
  aks_nsg_name     = "nsg-aks-${local.environment}-${local.loc}"
  agw_subnet_name  = "snet-agw-${local.environment}-${local.loc}"
  agw_nsg_name     = "nsg-agw-${local.environment}-${local.loc}"
  bastion_nsg_name = "nsg-bastion-${local.environment}-${local.loc}"
}

################################################################################
# Phase 1 — resource groups
#
# One group per lifecycle scope: net, sec, data, app, mon. See
# docs/ARCHITECTURE.md section 1.2 for why these are separated.
#
# Locks follow the profile and are off in stage, so `terraform destroy` works —
# the primary cost control on a credit-limited subscription. prod is the only
# environment that turns them on.
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
# UNCAPPED, unlike dev. qa's profile sets log_daily_quota_gb = -1: a cap stops
# ingestion once hit and drops everything after it, which in a test environment
# means losing the evidence for whatever was being tested. The cost of that is
# a bill that scales with ingestion instead of a hard stop, which is the right
# trade above dev and the wrong one inside a $200 credit.
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

module "diagnostics_log_analytics" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.log_analytics.id
  log_analytics_workspace_id = module.log_analytics.id
}

################################################################################
# Phase 2 — network
#
# Address plan per docs/NETWORKING.md. stage occupies 10.40.0.0/16, spaced from
# dev's 10.10.0.0/16, qa's 10.20.0.0/16 and prod's 10.30.0.0/16 so a future
# peering cannot collide.
#
# Unlike dev, stage ALLOCATES snet-agw — the Application Gateway is deployed
# here — and allocates AzureBastionSubnet, because stage runs Bastion Standard,
# which takes a subnet and a public IP where dev's Developer SKU attaches by
# VNet ID.
#
# Still reserved and not allocated: AzureFirewallManagementSubnet
# 10.40.0.64/26 -- needed only for the Basic tier or forced tunnelling, and
# stage runs Standard -- and GatewaySubnet 10.40.0.192/26.
################################################################################

locals {
  subnet_names = module.naming.subnet_names

  vnet_address_space = ["10.40.0.0/16"]
}

module "networking" {
  source = "../../modules/networking"

  vnet_name           = module.naming.names.virtual_network
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  address_space = local.vnet_address_space

  subnets = {
    # Azure Firewall. The name is fixed by Azure and /26 is its minimum; the
    # firewall module rejects a subnet named anything else at plan time,
    # because the API error names the FIREWALL rather than the subnet.
    #
    # It is never associated with a route table: a default route here would
    # send the firewall's own egress back into itself.
    AzureFirewallSubnet = {
      cidr = "10.40.0.0/26"
    }

    # Operator access. The name is fixed by Azure and the /26 is its minimum.
    AzureBastionSubnet = {
      cidr = "10.40.0.128/26"
    }

    # Application Gateway. Allocated here, unlike dev.
    #
    # No NAT Gateway association, and no default route (see the route table
    # below): AppGW v2 requires direct outbound access to its own control
    # plane. Forcing it through anything makes the gateway report permanently
    # unhealthy, with health probes failing for reasons that point at the
    # backend rather than at the routing.
    (local.agw_subnet_name) = {
      cidr = "10.40.1.0/24"
    }

    # Application tier. /22 rather than /24 because a scale set doing a rolling
    # upgrade at scale transiently needs more addresses than instances, and a
    # subnet holding resources cannot be resized.
    (local.subnet_names["app"]) = {
      cidr = "10.40.4.0/22"
    }

    (local.subnet_names["biz"]) = {
      cidr = "10.40.8.0/22"
    }

    # Reserved for a future IaaS database. PaaS SQL reaches the VNet through a
    # private endpoint, so nothing lands here today.
    (local.subnet_names["db"]) = {
      cidr = "10.40.12.0/24"
    }

    # Private endpoint NICs. "NetworkSecurityGroupEnabled" is required for NSG
    # rules to apply — historically NSGs were ignored on private endpoint
    # subnets, and leaving this Disabled means the rules written for it are
    # silently never enforced.
    (local.subnet_names["pep"]) = {
      cidr                              = "10.40.13.0/24"
      private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
    }

    (local.subnet_names["mgmt"]) = {
      cidr = "10.40.14.0/24"
    }

    # Kubernetes node subnet. Under Azure CNI Overlay this holds NODE addresses
    # only — pods draw from pod_cidr, routed inside the cluster.
    (local.aks_subnet_name) = {
      cidr = "10.40.16.0/20"
    }
  }

  # FALSE here, from the profile. Egress is the firewall below, and a NAT
  # Gateway attached to a subnet would take precedence over the UDR -- the two
  # are alternatives, not layers.
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
# Phase 2 — Azure Firewall
#
# THE REASON THIS ENVIRONMENT EXISTS. dev and qa egress through a NAT Gateway,
# which provides a stable outbound address and inspects nothing. stage is where
# the firewall topology, its UDRs and its egress rules are validated before
# prod depends on them.
#
# Deployed BEFORE the route table, because the route table's next hop is this
# firewall's private address, and before AKS, whose nodes cannot bootstrap
# until their egress path both exists and permits the traffic they need.
#
# Standard rather than Premium: prod uses Premium for IDPS and TLS inspection,
# but the topology, the routing and the rule model — the things stage exists to
# prove — are identical across the two tiers. The deviation is capability, not
# shape. Roughly $913/month against Premium's $1,278.
################################################################################

module "firewall" {
  source = "../../modules/firewall"
  count  = module.profile.enable_firewall ? 1 : 0

  name                = module.naming.names.firewall
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_tier = module.profile.profile.firewall_sku_tier
  zones    = module.profile.profile.compute_zones

  subnet_id      = module.networking.subnet_ids["AzureFirewallSubnet"]
  public_ip_name = "pip-afw-${module.naming.base}-001"

  # REQUIRED, because the network rules below use FQDNs. An FQDN in a network
  # rule is resolved by the firewall itself; without the proxy there is nothing
  # to resolve it and the rule silently matches no traffic. The module rejects
  # the combination rather than letting it deploy.
  dns_proxy_enabled = true

  # Note what is NOT here: a broad Allow on 443. Azure evaluates every network
  # rule before any application rule, so one would make the FQDN allow-lists
  # below unreachable while leaving them visible and correct-looking. The
  # module rejects that too.
  network_rule_collections = {
    "platform-egress" = {
      priority = 200
      action   = "Allow"
      rules = {
        "azure-dns" = {
          description           = "Azure-provided DNS. Without this nothing resolves and every rule below is unreachable."
          protocols             = ["UDP", "TCP"]
          source_addresses      = ["10.40.0.0/16"]
          destination_addresses = ["168.63.129.16"]
          destination_ports     = ["53"]
        }
        "ntp" = {
          description       = "Time sync. Certificate validation fails on a skewed clock, which presents as TLS errors rather than as a time problem."
          protocols         = ["UDP"]
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["ntp.ubuntu.com"]
          destination_ports = ["123"]
        }
        "aks-api-server" = {
          description           = "Nodes to their own control plane. A private cluster still reaches the API server over the network, and without this the node pool crash-loops."
          protocols             = ["TCP"]
          source_addresses      = ["10.40.16.0/20"]
          destination_addresses = ["AzureCloud.centralus"]
          destination_ports     = ["443", "9000"]
        }
      }
    }
  }

  # The FQDN allow-list AKS actually needs. Incomplete here is not a cosmetic
  # problem: a missing entry means nodes fail to bootstrap, the cluster never
  # converges, and AKS deletes and recreates the node every ~14 minutes
  # indefinitely — the failure shape ARCHITECTURE.md §6b describes from a
  # different cause.
  application_rule_collections = {
    "aks-required" = {
      priority = 300
      action   = "Allow"
      rules = {
        "aks-control-plane" = {
          description       = "Cluster control plane and node bootstrap."
          protocols         = { https = { type = "Https", port = 443 } }
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["*.hcp.centralus.azmk8s.io", "management.azure.com", "login.microsoftonline.com", "packages.microsoft.com", "acs-mirror.azureedge.net"]
        }
        "container-registry" = {
          description       = "Image pulls. Without this every pod stays in ImagePullBackOff."
          protocols         = { https = { type = "Https", port = 443 } }
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["mcr.microsoft.com", "*.data.mcr.microsoft.com"]
        }
        "monitoring" = {
          description       = "Azure Monitor ingestion. Without this the cluster runs and reports nothing, which looks like a healthy cluster with no telemetry."
          protocols         = { https = { type = "Https", port = 443 } }
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["dc.services.visualstudio.com", "*.ods.opinsights.azure.com", "*.oms.opinsights.azure.com", "*.monitoring.azure.com"]
        }
        "os-updates" = {
          description       = "Ubuntu package repositories for node OS patching."
          protocols         = { https = { type = "Https", port = 443 }, http = { type = "Http", port = 80 } }
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["security.ubuntu.com", "azure.archive.ubuntu.com", "changelogs.ubuntu.com"]
        }
      }
    }
  }
}

################################################################################
# Phase 2 — route tables
#
# stage carries a REAL default route, unlike dev and qa: 0.0.0.0/0 to the
# firewall's private address as a VirtualAppliance next hop. This is what
# forces every workload subnet through inspection, and it is the single most
# important line in the environment.
#
# The next hop is taken from a variable first and the local firewall second, so
# pointing stage at a shared hub firewall is a variable change rather than a
# rewrite — see ARCHITECTURE.md §1.1.
#
# BGP route propagation stays disabled. Without it, an ExpressRoute or VPN
# gateway attached later could advertise a more specific route that diverts
# egress around the firewall, defeating inspection with no change to this
# configuration and no error anywhere.
#
# AzureBastionSubnet, AzureFirewallSubnet and the Application Gateway subnet
# are deliberately NOT associated. A default route on Bastion or AppGW breaks
# the service; one on the firewall's own subnet sends its egress back into
# itself. The module rejects all three outright.
################################################################################

module "route_table" {
  source = "../../modules/route-table"

  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  # Armed rather than merely available: the module can only check that a
  # VirtualAppliance next hop exists in this network if it is told what this
  # network is, and a skipped check reads exactly like a passed one. Azure
  # accepts an out-of-VNet next hop, so nothing else would report it.
  vnet_address_space = local.vnet_address_space

  subnets_forbidding_default_route = [
    "AzureBastionSubnet",
    "AzureFirewallSubnet",
    "AzureFirewallManagementSubnet",
    "GatewaySubnet",
    "RouteServerSubnet",
    local.agw_subnet_name,
  ]

  route_tables = {
    (module.naming.names.route_table_workload) = {
      bgp_route_propagation_enabled = false

      routes = module.profile.egress_strategy == "firewall" ? {
        "Default-To-Firewall" = {
          address_prefix = "0.0.0.0/0"
          next_hop_type  = "VirtualAppliance"
          next_hop_in_ip_address = coalesce(
            var.firewall_private_ip,
            try(module.firewall[0].private_ip_address, null),
          )
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
# The AKS API server zone is NOT declared here, and that is deliberate. A
# private cluster publishes its API server into privatelink.<region>.azmk8s.io,
# but the aks module leaves private_dns_zone_id unset, so the value defaults to
# "System" and AKS creates and links that zone itself in the node resource
# group. Declaring it here as well would be a second owner for one zone.
#
# This environment's cluster is PRIVATE, so the zone exists — just not as
# something this module manages. The four services below are the DATA planes.
################################################################################

module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = module.resource_group.names["net"]
  tags                = module.tags.tags

  services = ["keyvault", "blob", "sql", "managed_redis"]

  virtual_network_ids = {
    (module.networking.vnet_name) = module.networking.vnet_id
  }

  registration_enabled = false
}

################################################################################
# Phase 2 — Azure Bastion
#
# stage runs Bastion STANDARD, where qa runs Basic and dev runs Developer. A
# dedicated instance in AzureBastionSubnet with its own public IP, supporting
# native client tunneling and file copy — which is what makes it usable as the
# entry point to a PRIVATE AKS cluster, where kubectl has to run from inside
# the VNet.
#
# It is a paid tier, and dearer than qa's Basic, where dev's Developer SKU is
# free. That is a real line item and part of why this environment is not
# deployed.
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
# destroyed with its resource, so every replacement would produce a new
# principal ID and silently invalidate every grant pointing at the old one.
#
# One identity per tier rather than one shared: network isolation without
# identity isolation makes the NSG boundary decorative, because anything
# reaching a tier inherits that tier's entire access footprint.
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
# in this platform.
#
# stage differs from dev in one important way: data_plane_public_access_enabled
# is FALSE. The vault is reachable only through its private endpoint.
#
# That is the correct posture and it has an operational consequence worth
# stating plainly rather than discovering: Terraform running on a laptop
# outside the VNet cannot read or write a secret, and any apply that touches
# vault DATA — a certificate, a secret — must run from inside the network, via
# Bastion or a self-hosted runner. Control-plane operations, including creating
# the vault itself and its role assignments, still work from anywhere.
#
# Purge protection is OFF, as in dev: the naming module produces a
# deterministic vault name, so protection would block rebuilding stage for the
# full retention period after a teardown. prod is the environment that accepts
# that trade and turns protection on.
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
# Private endpoint only in stage, per the profile.
#
# shared_access_key_enabled = false. Storage account keys are the most
# frequently leaked Azure credential — static, never expiring, impossible to
# scope, and granting total control to anyone holding one.
#
# The same consequence as Key Vault applies and is sharper here: creating a
# CONTAINER is a data-plane operation. With public access disabled, the apply
# that creates `app-data` must run from inside the VNet. Control-plane Owner is
# not sufficient either — a data-plane RBAC role is required, which is why the
# deployer grant below exists.
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
    {
      for tier, principal_id in module.managed_identity.principal_ids :
      "tier-${tier}" => {
        principal_id         = principal_id
        role_definition_name = "Storage Blob Data Contributor"
        principal_type       = "ServicePrincipal"
        description          = "Blob read/write for the ${tier} tier."
      }
    },
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
# azuread_authentication_only means there is NO SQL login. No password is
# generated, so none is written to Terraform state in plaintext, none is stored
# in Key Vault, none is rotated, and none can leak.
#
# stage uses BC_Gen5_2 — Business Critical, where qa runs the provisioned
# General Purpose GP_Gen5_2 and dev the serverless GP_S_Gen5_1.
# Serverless pauses after idle and pays a cold start of several seconds on the
# next connection, which is fine for development and actively misleading in a
# test environment: it turns a performance test into a measurement of whether
# the database happened to be awake.
################################################################################

module "sql" {
  source = "../../modules/sql"

  server_name         = module.naming.sql_server_name
  database_name       = module.naming.names.sql_database
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

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
# Phase 4 — Azure Managed Redis
#
# Azure Cache for Redis is RETIRING — its API rejects creation outright — so
# this uses Azure Managed Redis (Microsoft.Cache/redisEnterprise).
#
# stage enables high availability, as qa does and dev cannot afford. That is
# the difference that makes either able to answer a question dev cannot: what
# the application does when the cache fails over. A single-node cache never
# fails over; it simply disappears, so dev can only prove the wiring.
#
# Access keys are disabled. Redis keys have the same weaknesses as storage
# account keys — static, non-expiring, unscopable, total control.
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

  access_keys_authentication_enabled = false
  client_protocol                    = "Encrypted"

  # With access keys disabled, an access policy assignment is the ONLY path to
  # the data plane. Each tier's identity gets one; without it nothing could
  # connect at all.
  access_policy_assignments = {
    for tier, principal_id in module.managed_identity.principal_ids :
    "tier-${tier}" => { principal_id = principal_id }
  }

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
# stage's cluster is PRIVATE, as qa's is, and additionally egresses through the
# firewall rather than a NAT Gateway.
#
# The consequence is not subtle: there is no public API server endpoint, so
# kubectl works only from inside the VNet — through Bastion, or from a runner
# on a workload subnet. The api_server_authorized_ip_ranges input below is
# ignored by the module when private_cluster_enabled is true (Azure rejects the
# combination), and is left in place so that flipping the profile to a public
# cluster does not silently leave the API server open to the internet.
#
# It is HA in the shape prod uses: a three-node system pool across three zones,
# plus an autoscaling user node pool that keeps application workload off the
# nodes running CoreDNS and the API server proxies. The zone spread is the
# property stage exists to validate; the core count is not. That is 10 vCPU at
# steady state against a regional quota of 4.
#
# Egress is the firewall, which changes the cluster's outbound configuration in
# a way that is easy to get wrong — see outbound_type below.
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

    # Safe to taint here, unlike dev: qa has a user node pool, so tainting the
    # system pool still leaves somewhere for application pods to land. Without
    # a second pool this would make the cluster unschedulable, and the module
    # rejects that combination.
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

  vnet_subnet_id = module.networking.subnet_ids[local.aks_subnet_name]

  # Azure CNI Overlay. pod_cidr and service_cidr are routed inside the cluster
  # only. They must not overlap the VNet or anything peered to it — and they
  # deliberately differ from dev's, so that peering the two environments later
  # is a routing decision rather than a renumbering exercise.
  network_plugin      = "azure"
  network_plugin_mode = "overlay"
  network_policy      = module.profile.profile.aks_network_policy
  pod_cidr            = "10.244.0.0/16"
  service_cidr        = "172.17.0.0/16"
  dns_service_ip      = "172.17.0.10"

  # userDefinedRouting, NOT userAssignedNATGateway. There is no NAT Gateway in
  # this environment; egress leaves via the 0.0.0.0/0 route to the firewall.
  #
  # This value must match reality or the cluster fails at create time with
  # ExistingRouteTableNotAssociatedWithSubnet — an error that names the route
  # table rather than this setting. It also requires the route table to already
  # carry the default route AND be associated with the node subnet, which is
  # what the depends_on below guarantees.
  outbound_type = "userDefinedRouting"

  private_cluster_enabled = module.profile.aks_private_cluster

  # Both ignored while the cluster is private — the module nulls them — and
  # both correct the moment it is not. The egress address here is the
  # FIREWALL's public IP, because that is what the internet sees for every node
  # once traffic default-routes through it. AKS appends its own egress address
  # to the allowlist only when it owns the outbound path, which under
  # userDefinedRouting it does not.
  api_server_authorized_ip_ranges = [for ip in var.deployer_ip_addresses : "${ip}/32"]
  node_egress_ip_ranges           = module.profile.enable_firewall ? ["${module.firewall[0].public_ip_address}/32"] : []

  # Entra ID only. The local admin account authenticates with a certificate
  # that cannot be rotated or attributed to a person.
  local_account_disabled = true

  # Groups bind as Kubernetes Group subjects; individual users do not — a user
  # object ID here is accepted by Azure and matches nobody. Individuals go
  # through the Azure RBAC path below, where a user object ID does work.
  entra_admin_group_object_ids = var.aks_admin_group_object_ids
  cluster_admin_principal_ids  = toset(var.aks_cluster_admin_principal_ids)
  azure_rbac_enabled           = true

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  log_analytics_workspace_id = module.log_analytics.id

  # Ordering, not decoration. Under userDefinedRouting the node subnet must
  # already carry the default route to the firewall, and the firewall must
  # already permit the bootstrap traffic, before the first node starts. Without
  # this the apply races: nodes come up, cannot reach the control plane or the
  # registry, and AKS deletes and recreates them every ~14 minutes forever
  # while the cluster reports Updating.
  depends_on = [module.route_table, module.firewall]
}

module "diagnostics_aks" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.aks.id
  log_analytics_workspace_id = module.log_analytics.id

  # Empty, as in qa. stage is uncapped, so the API server audit trail is kept.
  # In an environment whose purpose is validating a security topology, dropping
  # the log that records who did what would defeat the exercise.
  log_selection           = length(var.aks_excluded_log_categories) > 0 ? "explicit" : "all"
  excluded_log_categories = var.aks_excluded_log_categories
}

################################################################################
# Phase 5 — Application Gateway
#
# The ingress dev does not have. WAF v2 in DETECTION mode, per the profile:
# Prevention here would block legitimate test traffic on a managed rule the
# team has not tuned yet, and the first thing a blocked team does is stop
# trusting the WAF. Detection logs what Prevention would have blocked, which is
# the input to tuning it.
#
# stage's compute spans zones 1, 2 and 3, as prod's does — an availability
# claim this environment exists to exercise before prod relies on it.
#
# TLS: the certificate is an input, not a resource, because a root module
# declares none. With no certificate supplied the gateway comes up HTTP-only
# and the `ingress_is_encrypted` output says so.
################################################################################

locals {
  agw_has_certificate = var.application_gateway_certificate_secret_id != null

  agw_listeners = merge(
    {
      "http" = { port = 80, protocol = "Http" }
    },
    local.agw_has_certificate ? {
      "https" = { port = 443, protocol = "Https" }
    } : {}
  )

  # With a certificate, HTTP exists only to redirect to HTTPS. Without one,
  # HTTP is the actual path to the backend.
  agw_routing_rules = local.agw_has_certificate ? {
    "https-to-app" = {
      priority                   = 100
      listener_name              = "https"
      backend_pool_name          = "app"
      backend_http_settings_name = "app-https"
    }
    "http-redirect" = {
      priority                    = 110
      listener_name               = "http"
      redirect_configuration_name = "to-https"
    }
    } : {
    "http-to-app" = {
      priority                   = 100
      listener_name              = "http"
      backend_pool_name          = "app"
      backend_http_settings_name = "app-https"
    }
  }
}

module "application_gateway" {
  source = "../../modules/application-gateway"
  count  = module.profile.enable_application_gateway ? 1 : 0

  name                = module.naming.names.application_gateway
  resource_group_name = module.resource_group.names["app"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  subnet_id      = module.networking.subnet_ids[local.agw_subnet_name]
  public_ip_name = "pip-agw-${module.naming.base}-001"

  sku_name     = module.profile.profile.application_gateway_sku
  waf_mode     = module.profile.profile.waf_mode
  zones        = module.profile.profile.application_gateway_zones
  min_capacity = module.profile.profile.application_gateway_min_capacity
  max_capacity = module.profile.profile.application_gateway_max_capacity

  # Reading the certificate from Key Vault rather than embedding a PFX keeps it
  # out of Terraform state and makes rotation a vault operation. The identity
  # is how the gateway authenticates to the vault; without it the gateway
  # cannot fetch the certificate and provisioning fails.
  ssl_certificate_key_vault_secret_id = var.application_gateway_certificate_secret_id
  user_assigned_identity_id           = local.agw_has_certificate ? module.managed_identity.ids["app"] : null

  # The backend is the AKS ingress controller's internal load balancer, which
  # does not exist until something is deployed INTO the cluster. Left empty
  # here deliberately: an address pool populated with a guess would send
  # traffic somewhere wrong, and an empty pool is a visible gap rather than a
  # silent misroute.
  backend_pools = { app = {} }

  probes = {
    "app-health" = { path = "/healthz" }
  }

  backend_http_settings = {
    "app-https" = { port = 443, probe_name = "app-health" }
  }

  listeners               = local.agw_listeners
  routing_rules           = local.agw_routing_rules
  redirect_configurations = local.agw_has_certificate ? { "to-https" = { target_listener_name = "https" } } : {}

  depends_on = [module.managed_identity]
}

module "diagnostics_application_gateway" {
  source   = "../../modules/diagnostics"
  for_each = module.profile.enable_application_gateway ? { this = module.application_gateway[0].id } : {}

  target_resource_id         = each.value
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
################################################################################

module "monitor" {
  source = "../../modules/monitor"

  count = module.profile.enable_alerts ? 1 : 0

  action_group_name       = module.naming.names.action_group
  action_group_short_name = "ccrt-${local.environment}"
  resource_group_name     = module.resource_group.names["mon"]
  location                = var.location
  tags                    = module.tags.tags

  email_receivers = {
    owner = coalesce(var.alert_email_address, var.owner)
  }

  cluster_id        = module.aks.id
  alert_name_prefix = "alrt-${module.naming.base}"

  # qa DOES autoscale, so the cluster_autoscaler_* metrics are actually
  # published here and rules on them can fire. In dev they are gated off,
  # because a metric that exists and is never published produces a rule that
  # looks healthy and never fires.
  cluster_autoscaler_enabled = module.profile.enable_autoscale

  # No pods-pending override. dev needs one because a single node leaves two
  # DaemonSet replicas permanently Pending; with a user node pool that standing
  # backlog does not exist, so the default threshold is meaningful again.
  # Re-measure against the running cluster before assuming that holds.

  # Both cap alerts are OFF here, and correctly so: they are derived from the
  # cap itself, and qa's profile sets log_daily_quota_gb = -1. An uncapped
  # workspace never emits the OverQuota record the first rule matches, and has
  # no cap for the second to measure a percentage against — the monitor
  # module's preconditions reject both rather than deploying something that
  # could never fire.
  enable_daily_cap_alert       = module.profile.profile.log_daily_quota_gb > 0
  log_analytics_daily_quota_gb = module.profile.profile.log_daily_quota_gb
  log_analytics_workspace_id   = module.log_analytics.id

  enable_daily_cap_warning_alert = module.profile.profile.log_daily_quota_gb > 0
}

################################################################################
# Backup
#
# The vault and its policies. Unlike dev, this is where they might actually
# protect something: qa is the first environment with enough compute to run a
# workload worth backing up.
#
# It still protects NOTHING as configured — AKS backup is a different resource
# family (Microsoft.DataProtection, a Backup vault plus an in-cluster
# extension), SQL carries its own retention, and storage is blob-only with
# versioning. The vault and policies are free; Azure bills per protected
# instance.
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
