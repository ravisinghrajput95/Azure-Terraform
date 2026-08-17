################################################################################
# Composition tests for the dev environment.
#
# The module tests verify each module against its own contract. Nothing until
# now verified the wiring between them — that the value one module emits is the
# value the next one needs, and that the profile's decisions actually reach the
# resources they are supposed to govern. A root module is where that goes
# wrong, and this one is 988 lines of it.
#
# Uses mock_provider, so this runs with NO Azure credentials, creates nothing,
# and needs no backend.
#
# WHAT THESE DO NOT TEST: that Azure accepts the plan. A mocked plan proves the
# configuration is internally coherent, not that the API agrees. Every value
# the provider computes — IDs, URIs, IPs, FQDNs — is a random mock string here,
# so nothing below asserts on one. What is asserted is what this repo decides:
# names, keys, counts, and the profile's choices reaching the modules that
# consume them.
################################################################################

# The client config is mocked with real-shaped GUIDs rather than left to the
# generator. Terraform's mock values are random 8-character strings, and this
# root feeds the data source straight into the SQL administrator object ID and
# the Key Vault tenant ID — both validated as GUIDs, one by this repo and one
# by the provider. Left generated, every run fails on the shape of the mock
# rather than on anything about the configuration.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

################################################################################
# Every variable is pinned here, including the ones whose defaults would do.
#
# `terraform test` loads terraform.tfvars from the configuration directory like
# any other command, and terraform.tfvars is gitignored. A test that leaves a
# variable to be filled in from that file passes on the machine that has one
# and fails in CI, which has none — and the first draft of this file did
# exactly that: it asserted the "cus" name prefix while var.location defaults
# to "eastus", and passed only because the local tfvars said centralus.
#
# Pinning everything makes the run independent of what happens to be on disk.
# The values mirror terraform.tfvars.example.
################################################################################

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  workload        = "cloudcart"
  location        = "centralus"

  owner               = "platform-team@example.com"
  cost_center         = "CC-DEV-001"
  criticality         = "low"
  data_classification = "internal"

  subscription_vcpu_quota = 4
  profile_overrides       = {}

  # dev egresses through a NAT Gateway, so there is no virtual appliance to
  # point a route at.
  firewall_private_ip = null

  deployer_ip_addresses = ["198.51.100.10"]

  aks_admin_group_object_ids      = []
  aks_cluster_admin_principal_ids = ["22222222-2222-2222-2222-222222222222"]

  sql_entra_admin_login     = null
  sql_entra_admin_object_id = null
  sql_entra_admin_is_group  = false

  log_analytics_daily_cap_reset_hour_utc = 11
  aks_excluded_log_categories            = ["kube-audit", "kube-audit-admin"]
}

################################################################################
# The composition resolves
#
# One coherent case first, so that a later failure is attributable to the thing
# a test changed rather than to the baseline being wrong.
################################################################################

run "plans_with_the_documented_inputs" {
  command = plan

  assert {
    condition     = output.name_prefix == "cloudcart-dev-cus"
    error_message = "The name prefix must carry this environment and this region. It read eus for months while the platform ran in Central US, and nothing caught it because a resource name is a string and Azure accepts any string."
  }

  assert {
    condition     = output.location == "centralus"
    error_message = "The region must normalise to centralus."
  }
}

################################################################################
# The profile's decisions reach the modules that consume them
#
# The profile module's own tests prove it decides correctly. These prove the
# decision is wired to something — a profile output nothing reads is a profile
# that governs nothing.
################################################################################

run "the_profile_decides_the_topology" {
  command = plan

  assert {
    condition     = output.egress_strategy == "nat_gateway"
    error_message = "dev must egress through a NAT Gateway. An Azure Firewall is roughly ten times the monthly cost, and validating firewall topology is what stage exists for."
  }

  assert {
    condition     = output.ingress_strategy == "public_load_balancer"
    error_message = "dev must ingress through a public load balancer. Application Gateway has no inexpensive tier — Standard_v2 is ~$180/month before capacity units."
  }

  assert {
    condition     = output.peak_vcpus == 2
    error_message = "dev's peak footprint must be 2 vCPU: one Standard_D2s_v4 node, autoscale off. Anything larger does not fit the 4 vCPU trial quota alongside the upgrade surge node."
  }

  assert {
    condition     = output.quota_checked
    error_message = "The vCPU quota assertion must actually run. False means it was skipped, not that it passed — the distinction the quota_checked output exists to make."
  }

  assert {
    condition     = length(output.locked_scopes) == 0
    error_message = "dev must carry no resource locks. A lock blocks terraform destroy, which is the primary cost control on a credit-limited subscription."
  }

  assert {
    condition     = output.log_ingestion_is_capped
    error_message = "dev's workspace must keep its daily cap, which protects the free 5 GB/month allowance."
  }
}

################################################################################
# Egress: the routing consequence of the strategy
#
# This is the wiring most worth testing, because getting it wrong produces a
# plan Azure accepts and a network that does not work. A NAT Gateway attaches
# to the subnet directly and is NOT a UDR next hop — a 0.0.0.0/0 route pointing
# anywhere would take precedence over it and break egress entirely.
#
# The route table is still created and attached, because disabling BGP route
# propagation is itself a control.
################################################################################

run "nat_gateway_egress_adds_no_default_route" {
  command = plan

  assert {
    condition     = length(output.route_tables_with_default_route) == 0
    error_message = "No route table may carry a default route while egress is by NAT Gateway. A 0.0.0.0/0 route overrides the NAT Gateway and removes outbound access."
  }

  assert {
    condition     = length(output.route_table_ids) == 1
    error_message = "The workload route table must exist even with no routes in it — it is what holds BGP propagation off, so a VPN or ExpressRoute gateway attached later cannot advertise a route that diverts egress."
  }
}

run "bastion_subnet_is_excluded_from_routing_and_egress" {
  command = plan

  # A default route on AzureBastionSubnet breaks the service, and the module
  # rejects the combination outright. Association is the thing to keep away
  # from it, and it is asserted here rather than trusted to the module test
  # because it is this root that chooses which subnets to associate.
  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must never be associated with a route table. Bastion manages its own outbound path and a UDR there breaks sessions."
  }

  assert {
    condition     = length(output.subnets_without_egress) == 1 && contains(tolist(output.subnets_without_egress), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet is the only subnet allowed to have no outbound internet path. Anything else here has lost egress, and default outbound access was retired on 30 September 2025 — package installs, agent enrolment and certificate revocation checks all fail on a subnet with no egress."
  }
}

################################################################################
# Names agree across the modules that share them
#
# The subnet names were literals in three separate places until 2026-08-15, and
# one of them named a region this environment does not run in. They are derived
# from one local now; this asserts the derivation actually reaches every
# consumer, which is the property that made the literals survivable in the
# first place and the one a copy to another environment would break.
################################################################################

run "the_derived_subnet_name_reaches_every_consumer" {
  command = plan

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-aks-dev-cus")
    error_message = "The AKS subnet must be created under the derived name."
  }

  assert {
    condition     = contains(flatten(values(output.route_table_subnets)), "snet-aks-dev-cus")
    error_message = "The AKS subnet must be associated with the workload route table under the same derived name. A mismatch here associates nothing and reports success."
  }

  assert {
    condition     = contains(keys(output.nsg_ids), "nsg-aks-dev-cus")
    error_message = "The AKS NSG must be created under the derived name."
  }
}

run "every_workload_subnet_is_routed_and_secured" {
  command = plan

  # Seven subnets: bastion, app, biz, db, pep, aks, mgmt. Six of them are
  # associated — every one except AzureBastionSubnet.
  assert {
    condition     = length(output.subnet_ids) == 7
    error_message = "The address plan defines seven subnets. A subnet holding resources cannot be resized, so a change here is not reversible in place."
  }

  assert {
    condition     = length(flatten(values(output.route_table_subnets))) == 6
    error_message = "Every subnet except AzureBastionSubnet must be associated with the workload route table. An unassociated subnet silently keeps system routing."
  }

  assert {
    condition     = length(output.nsgs_without_explicit_deny) == 0
    error_message = "Every NSG must end in an explicit inbound deny. Relying on Azure's built-in AllowVnetInBound permits all intra-VNet traffic, which is the opposite of the intent."
  }
}

################################################################################
# Private DNS covers every service that has a private endpoint
#
# A private endpoint whose DNS zone group finds no matching zone registers no A
# record. The client then falls back to public DNS and resolves the service to
# its PUBLIC address from inside the VNet: the endpoint exists, the NSG permits
# it, the diagram is correct, and traffic leaves the network. Nothing in Azure
# reports this as an error, which is why it is asserted here.
################################################################################

run "every_private_endpoint_service_has_a_zone" {
  command = plan

  assert {
    condition     = length(output.private_dns_zone_ids_by_service) == 4
    error_message = "Key Vault, blob storage, SQL and Redis each need a privatelink zone."
  }

  assert {
    condition     = contains(keys(output.private_dns_zone_ids_by_service), "managed_redis")
    error_message = "Redis must use the managed_redis zone. Azure Cache for Redis is retiring and Azure Managed Redis uses privatelink.redis.azure.net, not privatelink.redis.cache.windows.net — the wrong zone resolves the cache publicly from inside the VNet."
  }
}

################################################################################
# Governance tags reach the resources
################################################################################

run "governance_tags_are_applied" {
  command = plan

  assert {
    condition     = output.tags["environment"] == "dev"
    error_message = "The environment tag must match the environment. It is a local rather than a variable precisely so it cannot disagree."
  }

  assert {
    condition     = output.tags["owner"] == "platform-team@example.com" && output.tags["costCenter"] == "CC-DEV-001"
    error_message = "Ownership and chargeback tags must carry the supplied values. These are what cost reporting and incident response query on, which is why neither variable has a default."
  }
}


################################################################################
# Failure modes
#
# `expect_failures` only accepts checkable objects in the ROOT module under
# test. A composition root declares no resources of its own, so the failures
# that matter most here — a route to a null next hop, a footprint over quota, a
# cluster nobody can authenticate to — are raised by preconditions inside child
# modules and cannot be named from this file at all. Terraform reports
# "Invalid `expect_failures` reference" for module.profile.terraform_data.validation
# and "Missing expected failure" for anything else.
#
# Those three are covered where they can be named: route-table, profile and aks
# each test their own precondition in isolation, and the mutation run confirmed
# each one detects a weakened condition. What is left for this file is the root
# module's own validations, below, and the positive wiring asserted above —
# which is the part the module tests genuinely cannot see.
################################################################################

run "a_non_guid_subscription_is_refused" {
  command = plan

  variables {
    subscription_id = "my-subscription"
  }

  # azurerm 4.x requires the subscription explicitly and no longer falls back
  # to whichever subscription the CLI had selected. A malformed value must fail
  # at plan rather than reaching the provider.
  expect_failures = [
    var.subscription_id,
  ]
}

run "an_impossible_cap_reset_hour_is_refused" {
  command = plan

  variables {
    log_analytics_daily_cap_reset_hour_utc = 24
  }

  # The hour defines the window the cap-warning query sums over. A wrong one
  # produces a query Azure accepts and reports healthy while summing the wrong
  # period, so the bound is worth holding.
  expect_failures = [
    var.log_analytics_daily_cap_reset_hour_utc,
  ]
}

################################################################################
# The NSG rule matrix — the environment's security policy
#
# nsg-rules.tf is 335 lines and until now nothing tested a single rule in it.
# The module tests cover the mechanism — priority collisions, a missing
# catch-all deny, two NSGs claiming one subnet — but not the policy, and the
# policy is the part that decides what can reach what.
#
# These assert reach: which source is admitted to which port. A rule's access
# and port read the same whether the source is one subnet or the whole
# internet, which is why the assertions below name the source every time.
################################################################################

# The rule this repository got wrong for months, and the reason these tests
# exist at all. It named port 6380 — Azure Cache for Redis — while the platform
# runs Azure MANAGED Redis, which listens on 10000. Every call from a pod to
# Redis fell through to the deny below it.
#
# Nothing surfaced it: the private endpoint existed, the DNS zone resolved, the
# NSG read as configured, and the connection was simply refused.
run "the_private_endpoint_subnet_admits_exactly_the_data_ports" {
  command = plan

  assert {
    condition = length(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules : r if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ])) == 1
    error_message = "Exactly one rule must admit the workload to the data planes. If it is gone, every call from a pod to SQL, Redis, Key Vault and Storage hits the fallthrough deny and is simply refused."
  }

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.destination_port_ranges) == "443,1433,10000"
        if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ]))
    error_message = "The data-plane rule must admit exactly 443 (Key Vault, Storage), 1433 (SQL) and 10000 (Managed Redis). NOT 6380 — that is Azure Cache for Redis, which this platform does not use, and naming it silently breaks every cache call."
  }

  # Under Azure CNI Overlay a pod's traffic leaving the cluster is SNATed to
  # its NODE address, so the source must be the AKS subnet. Naming the app or
  # biz subnets here matches nothing and produces the same silent refusal.
  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-aks-dev-cus"]
        if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ]))
    error_message = "The data-plane rule must be sourced from the AKS NODE subnet. Pod traffic is SNATed to the node address under CNI Overlay, so any other source matches nothing."
  }
}

run "ssh_is_admitted_only_from_the_bastion_subnet" {
  command = plan

  # No instance carries a public IP, so Bastion is the only operator path in.
  # A second source here would be a way in that bypasses it.
  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["AzureBastionSubnet"]
        if r.direction == "Inbound" && r.access == "Allow" && contains(r.destination_port_ranges, "22")
      ]
    ]))
    error_message = "Every inbound rule admitting SSH must be sourced from the Bastion subnet and nothing else."
  }
}

# NOT TESTED, because it cannot fail: that every Allow sits below the
# fallthrough deny at 4096 and is therefore actually reached.
#
# The nsg module bounds every priority to [100, 4096] and rejects two rules at
# the same priority in the same NSG and direction. The fallthrough deny already
# occupies 4096 inbound, so an inbound Allow can never reach it — setting one
# to 4096 trips the collision check three rules earlier, which is what a
# mutation run confirmed. An OUTBOUND Allow can sit at 4096, but there is no
# outbound deny for it to hide behind, so the property is vacuous there.
#
# The structural guarantee is stronger than the test would have been. What is
# left worth asserting is that the deny exists at all, which
# `every_workload_subnet_is_routed_and_secured` above already covers.

# dev is the only environment whose application tier accepts traffic straight
# from the internet, and it is not a choice: a public load balancer DNATs
# without replacing the source address, so there is no gateway subnet to name.
# Every other environment tightens this to the Application Gateway subnet, and
# the contrast is the thing worth pinning.
run "the_application_tier_ingress_source_is_the_internet_in_dev" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == "Internet"
        if r.name == "Allow-HTTPS-Ingress"
      ]
    ]))
    error_message = "dev's application tier ingress must be sourced from Internet, because a public load balancer preserves the original source address. If this reads as a subnet CIDR, the profile has switched ingress and the rule no longer matches anything."
  }
}
