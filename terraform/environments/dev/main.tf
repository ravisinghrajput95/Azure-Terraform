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
