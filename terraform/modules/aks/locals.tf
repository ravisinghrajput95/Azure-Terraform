################################################################################
# Availability
#
# "Highly available" is reported rather than assumed. A single-node cluster in
# a single zone is a perfectly reasonable dev environment and a catastrophic
# production one, and the difference should be visible in an output rather than
# inferred from the node count by whoever reads the code next.
################################################################################

locals {
  system_effective_min = var.system_node_pool.auto_scaling_enabled ? coalesce(var.system_node_pool.min_count, 1) : var.system_node_pool.node_count

  system_zone_count = length(var.system_node_pool.zones)

  # Genuine HA needs both: enough nodes to lose one, and enough zones for the
  # loss to be a zone rather than a rack.
  is_highly_available = local.system_effective_min >= 3 && local.system_zone_count >= 3

  has_user_pools = length(var.user_node_pools) > 0
}

################################################################################
# Access coherence
#
# With the local admin account disabled, an Entra group is the ONLY way to
# authenticate. An empty group list produces a cluster that builds successfully
# and that nobody can log in to — recoverable only by re-enabling the local
# account through the control plane.
################################################################################

locals {
  no_admin_access = var.local_account_disabled && length(var.entra_admin_group_object_ids) == 0

  # A public API server with no IP restriction exposes the Kubernetes control
  # plane to the entire internet. Authentication still applies, but so does
  # every authentication bypass ever found in an API server.
  api_server_open_to_internet = !var.private_cluster_enabled && length(var.api_server_authorized_ip_ranges) == 0

  # Azure RBAC requires Entra integration to be configured at all.
  rbac_without_entra = var.azure_rbac_enabled && length(var.entra_admin_group_object_ids) == 0
}

################################################################################
# Network coherence
################################################################################

locals {
  # Moving from VM Scale Sets to AKS moves the tier boundary from subnets and
  # NSGs into the cluster. Without a policy engine every pod can reach every
  # other pod regardless of namespace, and the three-tier separation the
  # architecture claims simply does not exist.
  no_network_policy = var.network_policy == null

  # Network policy requires Azure CNI.
  policy_without_cni = var.network_policy != null && var.network_plugin != "azure"

  # userDefinedRouting requires egress to already exist on the subnet's route
  # table. Selecting it without one leaves nodes unable to reach the control
  # plane, and the cluster fails to provision with an error about node
  # registration rather than routing.
  requires_existing_egress = var.outbound_type == "userDefinedRouting"

  # dns_service_ip must sit inside service_cidr. Azure rejects the mismatch
  # with a message naming neither value.
  dns_ip_octets            = split(".", var.dns_service_ip)
  service_prefix           = join(".", slice(split(".", cidrhost(var.service_cidr, 0)), 0, 2))
  dns_ip_prefix            = join(".", slice(local.dns_ip_octets, 0, 2))
  dns_outside_service_cidr = local.dns_ip_prefix != local.service_prefix

  # Overlay pod addresses are routed inside the cluster only, so pod_cidr must
  # not overlap anything routable.
  cidrs_overlap = var.pod_cidr == var.service_cidr
}

################################################################################
# Add-on coherence
################################################################################

locals {
  # Cost analysis needs a paid SKU tier.
  cost_analysis_on_free_tier = var.cost_analysis_enabled && var.sku_tier == "Free"

  # The system pool cannot be tainted away from workloads unless something else
  # can run them.
  taint_without_user_pool = var.system_node_pool.only_critical_addons_taint && !local.has_user_pools

  # Workload identity is meaningless without the OIDC issuer that backs it.
  workload_identity_without_issuer = var.workload_identity_enabled && !var.oidc_issuer_enabled
}
