################################################################################
# Composition tests for the stage environment.
#
# stage is the environment whose egress goes through an Azure Firewall rather
# than a NAT Gateway. That topology — the firewall, the UDRs that force traffic
# into it, and the egress rules it enforces — is the reason stage exists, and
# it is exercised by no other environment.
#
# It is also doubly unverified: stage cannot be applied on this subscription,
# and neither can the firewall module it depends on, at roughly $912/month for
# the cheapest tier. So this file is the only thing that executes stage's
# firewall path anywhere.
#
# Uses mock_provider: NO Azure credentials, no backend, nothing created, plan
# only. It proves the composition is internally coherent, not that Azure
# accepts it.
################################################################################

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
# Every variable is pinned: `terraform test` reads the gitignored
# terraform.tfvars like any other command, and a test that depends on it passes
# on one machine and fails on another.
#
# subscription_vcpu_quota is 16 rather than this subscription's 4, because
# stage's peak footprint is 16 vCPU and the profile refuses to plan a footprint
# it cannot run. The last run in this file pins that refusal.
################################################################################

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  workload        = "cloudcart"
  location        = "centralus"

  owner               = "platform-team@example.com"
  alert_email_address = null
  cost_center         = "CC-STAGE-001"
  criticality         = "medium"
  data_classification = "internal"

  subscription_vcpu_quota = 16
  profile_overrides       = {}

  # The address the workload route table points its default route at. In a real
  # deployment this is the firewall's private IP, taken as a variable rather
  # than read from the firewall module so route tables can be applied before,
  # or independently of, the firewall itself. A separate run below covers
  # leaving it null and letting the module supply it.
  firewall_private_ip = "10.30.0.4"

  deployer_ip_addresses = []

  aks_admin_group_object_ids      = []
  aks_cluster_admin_principal_ids = ["22222222-2222-2222-2222-222222222222"]

  sql_entra_admin_login     = null
  sql_entra_admin_object_id = null
  sql_entra_admin_is_group  = false

  aks_excluded_log_categories = []

  application_gateway_certificate_secret_id = null
}

################################################################################
# The composition resolves
################################################################################

run "plans_with_the_documented_inputs" {
  command = plan

  assert {
    condition     = output.name_prefix == "cloudcart-stage-cus"
    error_message = "The name prefix must carry this environment and this region."
  }
}

################################################################################
# Egress through the firewall — the thing stage exists to validate
#
# Every assertion here is on a value no other environment produces.
################################################################################

run "egress_is_forced_through_the_firewall" {
  command = plan

  assert {
    condition     = output.egress_strategy == "firewall"
    error_message = "stage must egress through an Azure Firewall. Its NAT Gateway alternative is what dev and qa already validate; the firewall path is validated nowhere else."
  }

  assert {
    condition     = output.egress_is_inspected
    error_message = "Workload egress must be inspected. False means any pod can reach any internet address."
  }

  # The UDR is what actually forces traffic into the firewall. A firewall
  # deployed without it is billed in full and inspects nothing, and there is
  # nothing in either resource to indicate the traffic is not arriving.
  assert {
    condition     = length(output.route_tables_with_default_route) == 1
    error_message = "The workload route table must carry a 0.0.0.0/0 route. Without it the firewall is a billed appliance that no traffic reaches."
  }
}

run "the_firewall_subnets_are_never_default_routed" {
  command = plan

  # A default route on AzureFirewallSubnet sends the firewall's own egress back
  # into itself. The route-table module refuses the association outright; this
  # asserts stage never asks for it.
  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureFirewallSubnet")
    error_message = "AzureFirewallSubnet must never be associated with a route table — the firewall would route its own egress through itself."
  }

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must never be associated with a route table."
  }

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "snet-agw-stage-cus")
    error_message = "The Application Gateway subnet must never be associated with a route table. AppGW v2 needs direct control-plane access and reports permanently unhealthy behind a default route."
  }

  assert {
    condition     = contains(keys(output.subnet_ids), "AzureFirewallSubnet")
    error_message = "AzureFirewallSubnet must exist under exactly that name — Azure requires it verbatim and rejects any other."
  }
}

# The next hop has two sources: this variable, or the firewall module's own
# private IP when the variable is null. The fallback exists so the environment
# can be applied in one pass; the variable exists so route tables can be
# applied without the firewall. Both must plan.
run "the_next_hop_falls_back_to_the_firewall_module" {
  command = plan

  variables {
    firewall_private_ip = null
  }

  assert {
    condition     = length(output.route_tables_with_default_route) == 1
    error_message = "With no explicit next hop, the route table must still take the firewall module's private IP and keep its default route."
  }
}

################################################################################
# Ingress
################################################################################

run "ingress_is_the_application_gateway" {
  command = plan

  assert {
    condition     = output.ingress_strategy == "application_gateway"
    error_message = "stage must ingress through an Application Gateway, matching prod's shape."
  }

  assert {
    condition     = startswith(output.ingress_is_encrypted, "HTTP ONLY")
    error_message = "With no certificate secret ID, ingress must report itself as HTTP-only rather than appearing complete."
  }
}

################################################################################
# Names agree across the modules that share them
################################################################################

run "the_derived_names_reach_every_consumer" {
  command = plan

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-aks-stage-cus")
    error_message = "The AKS subnet must be created under the derived name."
  }

  assert {
    condition     = contains(flatten(values(output.route_table_subnets)), "snet-aks-stage-cus")
    error_message = "The AKS subnet must be associated with the workload route table under the same derived name. A mismatch associates nothing and reports success — and in this environment it also means that subnet's egress silently bypasses the firewall."
  }

  assert {
    condition     = contains(keys(output.nsg_ids), "nsg-aks-stage-cus")
    error_message = "The AKS NSG must be created under the derived name."
  }

  assert {
    condition     = length(output.nsgs_without_explicit_deny) == 0
    error_message = "Every NSG must end in an explicit inbound deny."
  }
}

run "every_workload_subnet_is_routed" {
  command = plan

  # Nine subnets: firewall, bastion, agw, app, biz, db, pep, mgmt, aks. Six are
  # associated — every one except the three that forbid a default route.
  assert {
    condition     = length(output.subnet_ids) == 9
    error_message = "The address plan defines nine subnets."
  }

  assert {
    condition     = length(flatten(values(output.route_table_subnets))) == 6
    error_message = "Six workload subnets must be associated with the route table. An unassociated subnet keeps system routing, which means its egress leaves without passing the firewall."
  }
}

################################################################################
# Private DNS
################################################################################

run "every_private_endpoint_service_has_a_zone" {
  command = plan

  assert {
    condition     = length(output.private_dns_zone_ids_by_service) == 4
    error_message = "Key Vault, blob storage, SQL and Redis each need a privatelink zone."
  }
}

################################################################################
# Governance
################################################################################

run "governance_tags_are_applied" {
  command = plan

  assert {
    condition     = output.tags["environment"] == "stage"
    error_message = "The environment tag must match the environment."
  }

  assert {
    condition     = output.tags["costCenter"] == "CC-STAGE-001"
    error_message = "The chargeback tag must carry the supplied value."
  }
}

################################################################################
# The quota refusal, at the real number
################################################################################

run "stage_does_not_fit_this_subscriptions_quota" {
  command = plan

  assert {
    condition     = output.peak_vcpus == 16
    error_message = "stage's peak footprint must be 16 vCPU: eight Standard_D2s_v5 at the autoscale ceiling. This subscription's regional limit is 4, which is why stage is documented as not deployable here."
  }
}

################################################################################
# The NSG rule matrix — the environment's security policy
#
# nsg-rules.tf is 379 lines and until now nothing tested a single rule in it.
# The nsg module tests cover the mechanism — priority collisions, a missing
# catch-all deny, two NSGs claiming one subnet — but not the policy, and the
# policy is what decides which source reaches which port.
#
# These matter more here than in dev. This environment has never been applied,
# so no traffic has ever confirmed that a rule admits what it claims to; and
# these three matrices were copied from one another, which is how four stray
# references to "qa" came to sit in stage's and prod's files, one of them in a
# rule description that deploys to Azure.
################################################################################

# The tighter of the two ingress postures, and the reason this environment can
# validate an ingress path dev cannot: traffic reaches the application tier
# from the Application Gateway subnet and from nowhere else. dev must name
# "Internet" instead, because a public load balancer DNATs without replacing
# the source address.
run "the_application_tier_admits_only_the_gateway_subnet" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-agw-stage-cus"]
        if r.name == "Allow-HTTPS-Ingress"
      ]
    ]))
    error_message = "Application tier ingress must be sourced from the Application Gateway subnet. If this reads \"Internet\", the WAF is no longer the only way in and every request can bypass it."
  }
}

# Skipping a tier is a lateral movement path. The business tier accepts the
# application subnet and nothing else — in particular not the gateway subnet,
# which is what would let ingress reach it directly.
run "the_business_tier_cannot_be_reached_from_ingress" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-app-stage-cus"]
        if r.name == "Allow-App-Tier"
      ]
    ]))
    error_message = "The business tier must admit the application subnet only. Naming the gateway subnet here makes the three-tier boundary diagrammatic rather than real."
  }

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        !contains(r.source_address_prefixes, output.subnet_cidrs["snet-agw-stage-cus"])
        if r.name == "Allow-App-Tier"
      ]
    ]))
    error_message = "The gateway subnet must never appear as a source on the business tier."
  }
}

# The rule this repository got wrong for months in dev: it named port 6380 —
# Azure Cache for Redis — while the platform runs Azure MANAGED Redis, which
# listens on 10000. Every call from a pod to Redis fell through to the deny.
# Nothing surfaced it, and in an environment that has never run, nothing could.
run "the_private_endpoint_subnet_admits_exactly_the_data_ports" {
  command = plan

  assert {
    condition = length(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules : r if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ])) == 1
    error_message = "Exactly one rule must admit the workload to the data planes."
  }

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.destination_port_ranges) == "443,1433,10000"
        if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ]))
    error_message = "The data-plane rule must admit exactly 443 (Key Vault, Storage), 1433 (SQL) and 10000 (Managed Redis). NOT 6380 — that is Azure Cache for Redis, which this platform does not use."
  }

  # Under Azure CNI Overlay a pod's traffic leaving the cluster is SNATed to
  # its NODE address, so the source must be the AKS subnet. Naming the app or
  # biz subnets matches nothing and every data-plane call is silently refused.
  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-aks-stage-cus"]
        if r.name == "Allow-Data-Plane-From-Workload"
      ]
    ]))
    error_message = "The data-plane rule must be sourced from the AKS NODE subnet."
  }
}

run "ssh_is_admitted_only_from_the_bastion_subnet" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        join(",", r.source_address_prefixes) == output.subnet_cidrs["AzureBastionSubnet"]
        if r.direction == "Inbound" && r.access == "Allow" && contains(r.destination_port_ranges, "22")
      ]
    ]))
    error_message = "Every inbound rule admitting SSH must be sourced from the Bastion subnet and nothing else. No instance carries a public IP, so a second source here is a way in that bypasses Bastion."
  }
}
