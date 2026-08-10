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
