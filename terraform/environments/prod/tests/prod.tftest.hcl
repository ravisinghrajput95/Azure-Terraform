################################################################################
# Composition tests for the prod environment.
#
# NOTHING IN prod HAS EVER RUN. It needs 80 vCPU at its autoscale ceiling
# against a regional quota of 4, and its indicative cost is four figures a
# month against a $200 credit. Every other form of verification available to
# this repo — an apply, a plan against a real subscription, a deployed
# smoke test — is closed to it.
#
# So this file is the whole of prod's verification, and it is worth being
# explicit about what that does and does not cover. It proves the composition
# is internally coherent: that the modules agree on names, that the profile's
# decisions reach the resources they govern, and that the controls prod exists
# to carry are actually wired. It does not prove Azure accepts the plan.
#
# Uses mock_provider: NO Azure credentials, no backend, nothing created, plan
# only.
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
# terraform.tfvars like any other command.
#
# subscription_vcpu_quota is 80 rather than this subscription's 4, because
# prod's peak footprint is 80 vCPU and the profile refuses to plan a footprint
# it cannot run. The last run in this file pins that refusal.
################################################################################

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  workload        = "cloudcart"
  location        = "centralus"

  owner               = "platform-team@example.com"
  alert_email_address = null
  cost_center         = "CC-PROD-001"
  criticality         = "high"
  data_classification = "internal"

  subscription_vcpu_quota = 80
  profile_overrides       = {}

  firewall_private_ip = "10.40.0.4"

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
    condition     = output.name_prefix == "cloudcart-prod-cus"
    error_message = "The name prefix must carry this environment and this region."
  }
}

################################################################################
# The controls prod exists to carry
#
# These are the ones the profile module's production guardrails refuse to let
# an override strip. Asserting them here proves the guardrail protects
# something that is actually wired, rather than a flag nothing reads.
################################################################################

run "production_controls_are_wired" {
  command = plan

  assert {
    condition     = length(output.locked_scopes) > 0
    error_message = "prod must carry management locks. They are off in dev because a lock blocks terraform destroy, which is the point: prod is the environment where that protection is wanted."
  }

  assert {
    condition     = output.egress_is_inspected
    error_message = "Workload egress must pass through the firewall. False means any pod can reach any internet address."
  }

  assert {
    condition     = output.waf_posture == "Prevention: matching requests are BLOCKED."
    error_message = "prod's WAF must be enforcing, not observing. Detection mode logs what Prevention would have blocked and blocks nothing — the right starting point for an untuned rule set and the wrong place to stop."
  }

  assert {
    condition     = !output.log_ingestion_is_capped
    error_message = "prod's workspace must not carry a daily cap. A cap drops data once hit, including security signals, and blinds every alert rule at once."
  }
}

################################################################################
# Egress through the firewall
################################################################################

run "egress_is_forced_through_the_firewall" {
  command = plan

  assert {
    condition     = output.egress_strategy == "firewall"
    error_message = "prod must egress through an Azure Firewall."
  }

  assert {
    condition     = length(output.route_tables_with_default_route) == 1
    error_message = "The workload route table must carry a 0.0.0.0/0 route. Without it the firewall is a billed appliance that no traffic reaches, and nothing in either resource indicates the traffic is not arriving."
  }
}

run "the_subnets_that_forbid_a_default_route_have_none" {
  command = plan

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureFirewallSubnet")
    error_message = "AzureFirewallSubnet must never be associated with a route table — the firewall would route its own egress through itself."
  }

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must never be associated with a route table."
  }

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "snet-agw-prod-cus")
    error_message = "The Application Gateway subnet must never be associated with a route table. AppGW v2 reports permanently unhealthy behind a default route."
  }
}

################################################################################
# Ingress
################################################################################

run "ingress_is_the_application_gateway" {
  command = plan

  assert {
    condition     = output.ingress_strategy == "application_gateway"
    error_message = "prod must ingress through an Application Gateway."
  }

  # prod is the environment where HTTP-only ingress would matter most, and the
  # configuration still permits it — the certificate is supplied out of band
  # and defaults to null. The degraded mode is reported rather than refused,
  # which is a deliberate choice recorded here so it is visible rather than
  # assumed.
  assert {
    condition     = startswith(output.ingress_is_encrypted, "HTTP ONLY")
    error_message = "With no certificate secret ID, ingress must report itself as HTTP-only rather than appearing complete."
  }
}

run "a_certificate_turns_on_the_https_listener" {
  command = plan

  variables {
    application_gateway_certificate_secret_id = "https://kv-cloudcart-prod-cus.vault.azure.net/secrets/tls/00000000000000000000000000000000"
  }

  assert {
    condition     = startswith(output.ingress_is_encrypted, "HTTPS")
    error_message = "Supplying a certificate secret ID must add the HTTPS listener and its redirect."
  }
}

################################################################################
# Names agree across the modules that share them
################################################################################

run "the_derived_names_reach_every_consumer" {
  command = plan

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-aks-prod-cus")
    error_message = "The AKS subnet must be created under the derived name."
  }

  assert {
    condition     = contains(flatten(values(output.route_table_subnets)), "snet-aks-prod-cus")
    error_message = "The AKS subnet must be associated with the workload route table under the same derived name. A mismatch associates nothing, reports success, and lets that subnet's egress bypass the firewall."
  }

  assert {
    condition     = contains(keys(output.nsg_ids), "nsg-aks-prod-cus")
    error_message = "The AKS NSG must be created under the derived name."
  }

  assert {
    condition     = length(output.nsgs_without_explicit_deny) == 0
    error_message = "Every NSG must end in an explicit inbound deny."
  }
}

run "every_workload_subnet_is_routed" {
  command = plan

  assert {
    condition     = length(output.subnet_ids) == 9
    error_message = "The address plan defines nine subnets."
  }

  assert {
    condition     = length(flatten(values(output.route_table_subnets))) == 6
    error_message = "Six workload subnets must be associated with the route table. An unassociated subnet keeps system routing and its egress leaves without passing the firewall."
  }
}

################################################################################
# Private DNS
################################################################################

run "every_private_endpoint_service_has_a_zone" {
  command = plan

  assert {
    condition     = length(output.private_dns_zone_ids_by_service) == 4
    error_message = "Key Vault, blob storage, SQL and Redis each need a privatelink zone. In prod there is no public fallback that happens to work — a missing zone means the service resolves publicly from inside the VNet."
  }
}

################################################################################
# Governance
################################################################################

run "governance_tags_are_applied" {
  command = plan

  assert {
    condition     = output.tags["environment"] == "prod"
    error_message = "The environment tag must match the environment. It is a local rather than a variable precisely so no -var can point this configuration at another environment's state."
  }

  assert {
    condition     = output.tags["costCenter"] == "CC-PROD-001" && output.tags["criticality"] == "high"
    error_message = "Chargeback and criticality tags must carry the supplied values."
  }
}

################################################################################
# The quota refusal, at the real number
################################################################################

run "prod_does_not_fit_this_subscriptions_quota" {
  command = plan

  assert {
    condition     = output.peak_vcpus == 80
    error_message = "prod's peak footprint must be 80 vCPU: twenty Standard_D4s_v5 at the autoscale ceiling. This subscription's regional limit is 4."
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-agw-prod-cus"]
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-app-prod-cus"]
        if r.name == "Allow-App-Tier"
      ]
    ]))
    error_message = "The business tier must admit the application subnet only. Naming the gateway subnet here makes the three-tier boundary diagrammatic rather than real."
  }

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        !contains(r.source_address_prefixes, output.subnet_cidrs["snet-agw-prod-cus"])
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-aks-prod-cus"]
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
