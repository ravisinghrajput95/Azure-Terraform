################################################################################
# The profile
#
# Callers pass individual attributes to downstream modules as explicit
# capability inputs. They do NOT pass var.environment onward — that is what
# keeps the other 19 modules environment-agnostic and therefore reusable.
#
#   module "firewall" {
#     count  = module.profile.profile.enable_firewall ? 1 : 0
#     sku_tier = module.profile.profile.firewall_sku_tier
#   }
################################################################################

output "profile" {
  description = "The complete resolved profile: environment defaults with overrides applied. 41 attributes covering egress, ingress, operator access, compute, data, security and observability."
  value       = local.profile
}

################################################################################
# Frequently-read flags
#
# Surfaced individually so a root module reads module.profile.enable_firewall
# rather than module.profile.profile.enable_firewall.
################################################################################

output "enable_firewall" {
  description = "Whether Azure Firewall is deployed. When false, egress is via NAT Gateway."
  value       = local.profile.enable_firewall
}

output "enable_nat_gateway" {
  description = "Whether a NAT Gateway provides egress. Mutually exclusive with enable_firewall."
  value       = local.profile.enable_nat_gateway
}

output "enable_application_gateway" {
  description = "Whether Application Gateway provides ingress. When false, a public load balancer does."
  value       = local.profile.enable_application_gateway
}

output "enable_public_load_balancer" {
  description = "Whether a public Standard load balancer provides ingress. Mutually exclusive with enable_application_gateway."
  value       = local.profile.enable_public_load_balancer
}

output "enable_bastion" {
  description = "Whether Azure Bastion is deployed."
  value       = local.profile.enable_bastion
}

output "enable_redis" {
  description = "Whether Azure Cache for Redis is deployed."
  value       = local.profile.enable_redis
}

output "enable_autoscale" {
  description = "Whether autoscale rules are attached to the scale sets."
  value       = local.profile.enable_autoscale
}

output "enable_backup" {
  description = "Whether a Recovery Services vault and backup policies are deployed."
  value       = local.profile.enable_backup
}

output "enable_alerts" {
  description = "Whether metric alert rules and action groups are deployed."
  value       = local.profile.enable_alerts
}

output "data_plane_public_access_enabled" {
  description = "Whether Key Vault and Storage keep a public endpoint, firewalled to an explicit IP allowlist. True only in dev, where secrets must be manageable from an operator laptop outside the VNet. Production forbids it."
  value       = local.profile.data_plane_public_access_enabled
}

output "aks_is_highly_available" {
  description = "Whether the cluster is genuinely HA: three or more nodes spread across at least three availability zones. False means a node or zone fault takes the cluster with it — reported explicitly so a degraded dev cluster never reads as production-shaped."
  value       = length(local.profile.compute_zones) >= 3 && local.profile.autoscale_min_instances >= 3
}

output "aks_private_cluster" {
  description = "Whether the Kubernetes API server is private. When true, kubectl works only from inside the VNet or through Bastion."
  value       = local.profile.aks_private_cluster
}

output "enable_user_node_pool" {
  description = "Whether a separate user node pool is deployed. When false, workloads share the system pool with the cluster's own components — acceptable in dev, poor practice anywhere else."
  value       = local.profile.enable_user_node_pool
}

output "enable_resource_locks" {
  description = "Whether CanNotDelete management locks are applied to stateful resources. This is the conditional substitute for `prevent_destroy`, which cannot accept a variable. See README.md."
  value       = local.profile.enable_resource_locks
}

output "enable_defender" {
  description = "Whether Microsoft Defender for Cloud plans should be enabled for this environment."
  value       = local.profile.enable_defender
}

################################################################################
# Egress and ingress strategy
#
# Single strings rather than paired booleans, for modules that need to branch
# on the strategy rather than on an individual flag — the route table module
# in particular, which must emit no default route at all when egress is via
# NAT Gateway, because a NAT Gateway attaches to the subnet directly and is
# not a UDR next hop.
################################################################################

output "egress_strategy" {
  description = "Either \"firewall\" or \"nat_gateway\". Determines whether route tables carry a 0.0.0.0/0 route."
  value       = local.profile.enable_firewall ? "firewall" : "nat_gateway"
}

output "ingress_strategy" {
  description = "Either \"application_gateway\" or \"public_load_balancer\"."
  value       = local.profile.enable_application_gateway ? "application_gateway" : "public_load_balancer"
}

################################################################################
# Capacity planning
################################################################################

output "vcpus_per_instance" {
  description = "vCPU count for the selected VM size, or null when the size is not in the module's lookup table."
  value       = local.vcpus_per_instance
}

output "peak_vcpus" {
  description = "Peak vCPU footprint across all compute tiers at maximum scale. Null when the VM size is unknown to the module. Compare against `az vm list-usage` before deploying."
  value       = local.peak_vcpus
}

output "quota_checked" {
  description = "Whether the vCPU quota assertion actually ran. False means either no quota was supplied or the VM size is not in the lookup table — the plan passed without checking."
  value       = local.quota_check_possible
}

################################################################################
# Cost
################################################################################

output "indicative_monthly_cost_usd" {
  description = "ORDER-OF-MAGNITUDE monthly estimate in USD at approximate US list price. Excludes data processing, egress, storage capacity, transactions and any discount. A planning aid to answer 'tens, hundreds or thousands', not a budget figure — use infracost for anything financial."
  value       = local.indicative_monthly_cost_usd
}

output "cost_breakdown" {
  description = "Indicative cost split by component, same caveats as indicative_monthly_cost_usd. Useful for seeing which single component dominates an environment's bill."
  value = {
    firewall             = local.cost_firewall
    nat_gateway          = local.cost_nat
    application_gateway  = local.cost_appgw
    public_load_balancer = local.cost_public_lb
    bastion              = local.cost_bastion
    compute              = local.cost_compute
    sql                  = local.cost_sql
    redis                = local.cost_redis
    ddos_protection      = local.cost_ddos
    fixed                = local.cost_fixed
  }
}

################################################################################
# Ordering handle
################################################################################

output "validation_id" {
  description = "Identifier of the internal validation resource. Depend on this to order profile validation ahead of resource creation."
  value       = terraform_data.validation.id
}
