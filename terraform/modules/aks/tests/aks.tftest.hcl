################################################################################
# Unit tests for the aks module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing. What they prove is the module's LOGIC: that each precondition fires
# on the input it exists to catch. What they cannot prove is that Azure accepts
# the resulting API call, or that the cluster converges once created.
#
# That distinction is the whole reason this file exists. Every failure guarded
# here produces a cluster that Azure ACCEPTS — the apply succeeds, or runs for
# fifteen minutes and then fails somewhere that names none of the inputs
# responsible. A plan-time rejection is the only cheap place to catch them.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "aks-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-app"
  location            = "centralus"
  tags                = { environment = "test" }
  dns_prefix          = "cloudcart-test"
  vnet_subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"

  system_node_pool = {
    vm_size    = "Standard_D2s_v4"
    node_count = 1
  }

  entra_admin_group_object_ids = ["00000000-0000-0000-0000-00000000aaaa"]

  # The dev topology: public API server, operator allowlist, egress through a
  # user-assigned NAT Gateway.
  outbound_type                   = "userAssignedNATGateway"
  api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  node_egress_ip_ranges           = ["198.51.100.20/32"]
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_cluster" {
  command = plan

  assert {
    condition     = output.network_policy == "azure"
    error_message = "The platform requires a policy engine; the default should be azure."
  }

  assert {
    condition     = output.is_highly_available == false
    error_message = "A single node in no zones must not report itself highly available."
  }
}

################################################################################
# API server allowlist
#
# AKS appends the cluster's own egress address to the allowlist only when it
# owns the outbound path. With a user-assigned NAT Gateway or a UDR it does
# not, and nothing in the plan output says so.
################################################################################

run "merges_node_egress_into_the_allowlist" {
  command = plan

  assert {
    condition     = contains(output.api_server_authorized_ip_ranges, "203.0.113.10/32")
    error_message = "The operator address must remain in the allowlist."
  }

  assert {
    condition     = contains(output.api_server_authorized_ip_ranges, "198.51.100.20/32")
    error_message = "The cluster's own egress address must be merged into the allowlist, or its nodes cannot reach their own API server."
  }
}

run "rejects_self_managed_egress_with_no_declared_egress_address" {
  command = plan

  # The exact defect that crash-looped dev: nodes egress from the NAT Gateway,
  # the allowlist admits only the operator, kubelet never registers, vmssCSE
  # times out with exit code 51, and AKS recreates the node every ~14 minutes
  # forever. Azure reports no error on the cluster resource itself.
  variables {
    node_egress_ip_ranges = []
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_user_defined_routing_with_no_declared_egress_address" {
  command = plan

  variables {
    outbound_type         = "userDefinedRouting"
    node_egress_ip_ranges = []
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "allows_managed_egress_without_a_declared_egress_address" {
  command = plan

  # With managedNATGateway, AKS owns the outbound address and appends it to the
  # allowlist itself, so requiring the caller to supply it would be wrong.
  variables {
    outbound_type         = "managedNATGateway"
    node_egress_ip_ranges = []
  }

  assert {
    condition     = output.api_server_authorized_ip_ranges == tolist(["203.0.113.10/32"])
    error_message = "With AKS-managed egress the allowlist should carry the operator address alone."
  }
}

run "allows_private_cluster_without_a_declared_egress_address" {
  command = plan

  # A private API server has no public endpoint to be allowlisted against.
  variables {
    private_cluster_enabled         = true
    api_server_authorized_ip_ranges = []
    node_egress_ip_ranges           = []
  }

  assert {
    condition     = length(output.api_server_authorized_ip_ranges) == 0
    error_message = "A private cluster should report no public allowlist."
  }
}

run "rejects_a_public_cluster_with_no_allowlist_at_all" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = []
    node_egress_ip_ranges           = []
    outbound_type                   = "managedNATGateway"
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

################################################################################
# Access
#
# Both of these build a cluster successfully and then cannot be logged in to.
################################################################################

run "rejects_disabled_local_account_with_no_entra_group" {
  command = plan

  variables {
    local_account_disabled       = true
    entra_admin_group_object_ids = []
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

################################################################################
# Network coherence
################################################################################

run "rejects_null_network_policy" {
  command = plan

  # Without a policy engine every pod reaches every other pod regardless of
  # namespace, and the tier separation the architecture claims does not exist.
  variables {
    network_policy = null
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_dns_service_ip_outside_service_cidr" {
  command = plan

  # Azure rejects this with a message naming neither value.
  variables {
    service_cidr   = "172.16.0.0/16"
    dns_service_ip = "10.99.0.10"
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_identical_pod_and_service_cidrs" {
  command = plan

  # dns_service_ip is moved INTO the shared range on purpose. Left at its
  # default it sits outside service_cidr, so this run also tripped the DNS
  # precondition and passed whether or not the overlap check was doing
  # anything. Mutation testing found it: weakening cidrs_overlap left the test
  # still failing, on the other check.
  variables {
    pod_cidr       = "192.168.0.0/16"
    service_cidr   = "192.168.0.0/16"
    dns_service_ip = "192.168.0.10"
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_network_policy_without_azure_cni" {
  command = plan

  # A policy engine needs Azure CNI. Without it the policy is accepted and
  # enforces nothing, so every pod reaches every other pod while the
  # configuration reads as though namespaces are separated.
  variables {
    network_plugin = "kubenet"
    network_policy = "azure"
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_workload_identity_without_the_oidc_issuer" {
  command = plan

  # The federated token a workload presents is issued by that endpoint. With
  # the issuer off, workload identity is enabled, displays as enabled, and no
  # pod can obtain a token.
  variables {
    workload_identity_enabled = true
    oidc_issuer_enabled       = false
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "rejects_cost_analysis_on_the_free_tier" {
  command = plan

  # Accepted on Free and simply never produces data, so the cost view stays
  # empty and looks like a workload with no spend.
  variables {
    cost_analysis_enabled = true
    sku_tier              = "Free"
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

################################################################################
# Add-on coherence
################################################################################

run "rejects_system_pool_taint_with_no_user_pool" {
  command = plan

  # Tainting the only pool leaves nothing schedulable.
  variables {
    system_node_pool = {
      vm_size                    = "Standard_D2s_v4"
      node_count                 = 1
      only_critical_addons_taint = true
    }
    user_node_pools = {}
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

################################################################################
# Admin access paths
#
# The failure these guard is total and silent: a cluster that builds, reports
# healthy, and that nobody can authenticate to.
################################################################################

run "rejects_disabled_local_account_with_neither_admin_path" {
  command = plan

  variables {
    local_account_disabled       = true
    entra_admin_group_object_ids = []
    cluster_admin_principal_ids  = []
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}

run "accepts_azure_rbac_admins_without_any_entra_group" {
  command = plan

  # The real dev topology. This tenant has no Entra group, so cluster-admin is
  # granted by Azure RBAC role assignment — which, unlike the AAD group
  # binding, accepts a user object ID.
  variables {
    local_account_disabled       = true
    entra_admin_group_object_ids = []
    cluster_admin_principal_ids  = ["00000000-0000-0000-0000-00000000eeee"]
  }

  assert {
    condition     = length(output.cluster_admin_principal_ids) == 1
    error_message = "An Azure RBAC role assignment is a sufficient admin path on its own."
  }

  assert {
    condition     = strcontains(output.admin_access_summary, "1 principal(s) hold Azure RBAC cluster-admin")
    error_message = "The admin path actually in use must be stated in plain language."
  }
}

run "warns_when_azure_rbac_has_no_role_assignment" {
  command = plan

  # Groups supplied but no data-plane role assigned, so access rests entirely
  # on those IDs being real GROUPS. Correct if they are; a locked-out cluster
  # if any is a user object ID. Terraform cannot tell, so it reports.
  variables {
    azure_rbac_enabled           = true
    entra_admin_group_object_ids = ["00000000-0000-0000-0000-00000000aaaa"]
    cluster_admin_principal_ids  = []
  }

  assert {
    condition     = strcontains(output.admin_access_summary, "must be GROUPS")
    error_message = "The group-versus-user trap must be stated, since it cannot be validated."
  }

  assert {
    condition     = strcontains(output.admin_access_summary, "Owner does NOT grant kubectl access")
    error_message = "Owner carries no dataActions; assuming it rescues access is the natural wrong guess."
  }
}

run "assigns_no_data_plane_role_when_azure_rbac_is_disabled" {
  command = plan

  # Without Azure RBAC the role assignment would grant nothing, so it is not
  # created rather than created and inert.
  variables {
    azure_rbac_enabled           = false
    entra_admin_group_object_ids = ["00000000-0000-0000-0000-00000000aaaa"]
    cluster_admin_principal_ids  = ["00000000-0000-0000-0000-00000000eeee"]
  }

  assert {
    condition     = length(output.cluster_admin_principal_ids) == 0
    error_message = "Azure RBAC role assignments are meaningless when Azure RBAC is off."
  }
}
