################################################################################
# AKS cluster
#
# Replaces the VM Scale Set tiers. The consequence worth stating up front: the
# three-tier boundary moves from subnets and NSGs into the cluster. Where the
# app and biz tiers were separated by an NSG that Azure enforced at the network
# layer, they are now namespaces separated by a network policy that the cluster
# enforces. That is a real change in where trust lives, and it is why
# network_policy is not optional in this module.
################################################################################

resource "azurerm_kubernetes_cluster" "this" {
  name                       = var.name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  dns_prefix                 = var.private_cluster_enabled ? null : var.dns_prefix
  dns_prefix_private_cluster = var.private_cluster_enabled ? var.dns_prefix : null

  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = var.automatic_upgrade_channel
  sku_tier                  = var.sku_tier
  node_resource_group       = var.node_resource_group

  ##############################################################################
  # Identity
  #
  # SystemAssigned for the control plane: the identity is created and destroyed
  # with the cluster, which is correct for a principal nothing outside the
  # cluster should reference.
  #
  # Workloads do NOT use this identity. They use Entra Workload Identity —
  # a federated service account token — which is what replaces a VM's managed
  # identity once workloads live in pods.
  ##############################################################################

  identity {
    type = "SystemAssigned"
  }

  oidc_issuer_enabled       = var.oidc_issuer_enabled
  workload_identity_enabled = var.workload_identity_enabled

  ##############################################################################
  # Authentication
  #
  # The local admin account authenticates with a client certificate that cannot
  # be rotated, cannot be attributed to a person, and bypasses Entra ID
  # entirely. Disabling it makes Entra group membership the only way in.
  ##############################################################################

  local_account_disabled = var.local_account_disabled

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = length(var.entra_admin_group_object_ids) > 0 ? [1] : []

    content {
      admin_group_object_ids = var.entra_admin_group_object_ids
      azure_rbac_enabled     = var.azure_rbac_enabled
    }
  }

  api_server_access_profile {
    authorized_ip_ranges = var.private_cluster_enabled ? null : var.api_server_authorized_ip_ranges
  }

  private_cluster_enabled = var.private_cluster_enabled
  run_command_enabled     = var.run_command_enabled

  ##############################################################################
  # System node pool
  ##############################################################################

  default_node_pool {
    name    = var.system_node_pool.name
    vm_size = var.system_node_pool.vm_size

    node_count           = var.system_node_pool.auto_scaling_enabled ? null : var.system_node_pool.node_count
    auto_scaling_enabled = var.system_node_pool.auto_scaling_enabled
    min_count            = var.system_node_pool.auto_scaling_enabled ? var.system_node_pool.min_count : null
    max_count            = var.system_node_pool.auto_scaling_enabled ? var.system_node_pool.max_count : null

    zones = var.system_node_pool.zones

    os_disk_size_gb = var.system_node_pool.os_disk_size_gb
    os_disk_type    = var.system_node_pool.os_disk_type
    max_pods        = var.system_node_pool.max_pods

    vnet_subnet_id = var.vnet_subnet_id

    # Keeps application workloads off the system pool, so a runaway pod cannot
    # starve CoreDNS. Only viable when a user pool exists to run them.
    only_critical_addons_enabled = var.system_node_pool.only_critical_addons_taint

    upgrade_settings {
      max_surge = "1"
    }

    tags = var.tags
  }

  ##############################################################################
  # Networking
  ##############################################################################

  network_profile {
    network_plugin      = var.network_plugin
    network_plugin_mode = var.network_plugin_mode
    network_policy      = var.network_policy
    load_balancer_sku   = "standard"
    outbound_type       = var.outbound_type

    pod_cidr       = var.network_plugin_mode == "overlay" ? var.pod_cidr : null
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  ##############################################################################
  # Add-ons
  ##############################################################################

  dynamic "oms_agent" {
    for_each = var.log_analytics_workspace_id != null ? [1] : []

    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  azure_policy_enabled = var.azure_policy_enabled

  dynamic "key_vault_secrets_provider" {
    for_each = var.key_vault_secrets_provider_enabled ? [1] : []

    content {
      secret_rotation_enabled  = true
      secret_rotation_interval = "2m"
    }
  }

  image_cleaner_enabled        = var.image_cleaner_enabled
  image_cleaner_interval_hours = 24
  cost_analysis_enabled        = var.cost_analysis_enabled

  auto_scaler_profile {
    balance_similar_node_groups   = var.auto_scaler_profile.balance_similar_node_groups
    expander                      = var.auto_scaler_profile.expander
    scale_down_unneeded           = var.auto_scaler_profile.scale_down_unneeded
    scale_down_delay_after_add    = var.auto_scaler_profile.scale_down_delay_after_add
    skip_nodes_with_local_storage = var.auto_scaler_profile.skip_nodes_with_local_storage
    skip_nodes_with_system_pods   = var.auto_scaler_profile.skip_nodes_with_system_pods
  }

  dynamic "maintenance_window" {
    for_each = length(var.maintenance_window_hours) > 0 ? [1] : []

    content {
      allowed {
        day   = "Sunday"
        hours = var.maintenance_window_hours
      }
    }
  }

  tags = var.tags

  lifecycle {
    ############################################################################
    # Access. Both of these produce a cluster that builds successfully and
    # cannot be used, or can be used by anyone.
    ############################################################################
    precondition {
      condition = !local.no_admin_access
      error_message = join(" ", [
        "local_account_disabled is true but entra_admin_group_object_ids is empty.",
        "The local account is the only other way in, so the cluster would build successfully and NOBODY could authenticate —",
        "recoverable only by re-enabling the local account through the Azure control plane.",
        "Supply at least one Entra group."
      ])
    }

    precondition {
      condition = !local.api_server_open_to_internet
      error_message = join(" ", [
        "The cluster is public and api_server_authorized_ip_ranges is empty.",
        "The Kubernetes API server would be reachable from the entire internet.",
        "Authentication still applies, but so does every authentication bypass ever found in an API server.",
        "Either set private_cluster_enabled, or supply an IP allowlist."
      ])
    }

    ############################################################################
    # Network. Without a policy engine the tier separation this architecture
    # claims does not exist.
    ############################################################################
    precondition {
      condition = !local.no_network_policy
      error_message = join(" ", [
        "network_policy is null.",
        "Moving from VM Scale Sets to AKS moves the three-tier boundary from subnets and NSGs into the cluster.",
        "Without a policy engine every pod can reach every other pod regardless of namespace,",
        "and the tier separation the architecture claims simply does not exist."
      ])
    }

    precondition {
      condition     = !local.policy_without_cni
      error_message = "network_policy requires network_plugin = \"azure\". Azure CNI is a prerequisite for any policy engine."
    }

    precondition {
      condition     = !local.dns_outside_service_cidr
      error_message = "dns_service_ip (${var.dns_service_ip}) is outside service_cidr (${var.service_cidr}). Azure rejects this with a message naming neither value."
    }

    precondition {
      condition     = !local.cidrs_overlap
      error_message = "pod_cidr and service_cidr are identical. They must be distinct, and neither may overlap the VNet or any peered network."
    }

    ############################################################################
    # Add-on coherence
    ############################################################################
    precondition {
      condition     = !local.taint_without_user_pool
      error_message = "only_critical_addons_taint is set but no user node pools exist. The taint would keep every workload off the only pool available, so nothing could be scheduled."
    }

    precondition {
      condition     = !local.workload_identity_without_issuer
      error_message = "workload_identity_enabled requires oidc_issuer_enabled. The federated token workloads present is issued by that endpoint."
    }

    precondition {
      condition     = !local.cost_analysis_on_free_tier
      error_message = "cost_analysis_enabled requires the Standard or Premium SKU tier."
    }
  }
}

################################################################################
# User node pools
#
# Separating application workloads from the system pool means a runaway pod
# cannot starve CoreDNS or metrics-server.
################################################################################

resource "azurerm_kubernetes_cluster_node_pool" "this" {
  for_each = var.user_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size

  node_count           = each.value.auto_scaling_enabled ? null : each.value.node_count
  auto_scaling_enabled = each.value.auto_scaling_enabled
  min_count            = each.value.auto_scaling_enabled ? each.value.min_count : null
  max_count            = each.value.auto_scaling_enabled ? each.value.max_count : null

  zones           = each.value.zones
  os_disk_size_gb = each.value.os_disk_size_gb
  os_disk_type    = each.value.os_disk_type
  max_pods        = each.value.max_pods
  vnet_subnet_id  = var.vnet_subnet_id

  node_labels = each.value.node_labels
  node_taints = each.value.node_taints

  # Spot nodes are evicted with 30 seconds notice. Viable for batch work that
  # can be rescheduled; never for a tier serving requests.
  priority        = each.value.spot_enabled ? "Spot" : "Regular"
  eviction_policy = each.value.spot_enabled ? "Delete" : null
  spot_max_price  = each.value.spot_enabled ? -1 : null

  upgrade_settings {
    max_surge = "1"
  }

  tags = var.tags
}
