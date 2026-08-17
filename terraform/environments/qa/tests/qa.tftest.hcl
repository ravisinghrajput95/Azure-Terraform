################################################################################
# Composition tests for the qa environment.
#
# qa CANNOT BE APPLIED on this subscription — its profile needs more vCPU than
# the regional quota allows, and its monthly cost is an order of magnitude over
# the remaining credit. That is exactly why this file matters: a mocked plan is
# the only verification this environment can be given, and without it qa is
# 1000 lines of configuration that has never been executed by anything.
#
# Uses mock_provider, so this runs with NO Azure credentials and creates
# nothing. It proves the composition is internally coherent, not that Azure
# accepts it — every provider-computed value here is a random mock string, so
# nothing below asserts on one.
#
# What qa adds over dev, and what is therefore worth asserting here: an
# Application Gateway in front instead of a public load balancer, a private
# AKS cluster, and a real (uncapped) workspace.
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
# Every variable is pinned, including the ones whose defaults would do:
# `terraform test` reads terraform.tfvars like any other command, and that file
# is gitignored. Leaving a variable to be filled in from it makes the run
# depend on what happens to be on the machine.
#
# subscription_vcpu_quota is the exception worth reading twice. It is 8 here,
# not the 4 this subscription actually has and not the 4 the variable defaults
# to, because qa's peak footprint is 8 vCPU and the profile refuses to plan a
# footprint it cannot run. The last test in this file pins that refusal at the
# real quota, so the number below is a test fixture rather than a claim about
# the subscription.
################################################################################

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  workload        = "cloudcart"
  location        = "centralus"

  owner               = "platform-team@example.com"
  alert_email_address = null
  cost_center         = "CC-QA-001"
  criticality         = "medium"
  data_classification = "internal"

  subscription_vcpu_quota = 8
  profile_overrides       = {}

  # qa egresses through a NAT Gateway. The firewall topology is stage's job.
  firewall_private_ip = null

  # Empty, unlike dev: qa's data planes are private, reached from inside the
  # VNet rather than from an operator's laptop.
  deployer_ip_addresses = []

  aks_admin_group_object_ids      = []
  aks_cluster_admin_principal_ids = ["22222222-2222-2222-2222-222222222222"]

  sql_entra_admin_login     = null
  sql_entra_admin_object_id = null
  sql_entra_admin_is_group  = false

  aks_excluded_log_categories = []

  # Null exercises the documented degraded mode: HTTP listener only, no HTTPS
  # listener and no redirect. A separate run below covers the certificate.
  application_gateway_certificate_secret_id = null
}

################################################################################
# The composition resolves
################################################################################

run "plans_with_the_documented_inputs" {
  command = plan

  assert {
    condition     = output.name_prefix == "cloudcart-qa-cus"
    error_message = "The name prefix must carry this environment and this region."
  }

  assert {
    condition     = output.location == "centralus"
    error_message = "The region must normalise to centralus."
  }
}

################################################################################
# The profile's decisions reach the modules that consume them
################################################################################

run "the_profile_decides_the_topology" {
  command = plan

  assert {
    condition     = output.egress_strategy == "nat_gateway"
    error_message = "qa must egress through a NAT Gateway. An Azure Firewall at ~$912/month is the single largest line item, and qa's job is to answer whether the application works — which egress inspection does not change."
  }

  assert {
    condition     = output.ingress_strategy == "application_gateway"
    error_message = "qa must ingress through an Application Gateway. It is the environment where WAF rules are tuned, so that tuning happens here rather than against production traffic."
  }

  assert {
    condition     = output.peak_vcpus == 8
    error_message = "qa's peak footprint must be 8 vCPU: four Standard_D2s_v5 at the autoscale ceiling. This is the number that does not fit this subscription."
  }

  assert {
    condition     = output.quota_checked
    error_message = "The vCPU quota assertion must actually run. False means it was skipped, not that it passed."
  }

  assert {
    condition     = !output.log_ingestion_is_capped
    error_message = "qa's workspace must NOT carry a daily cap. A cap drops data once hit — including security signals — and blinds every alert rule at the same time."
  }
}

################################################################################
# Ingress: what the Application Gateway changes
#
# The gateway is the reason qa exists as a separate environment, and it brings
# two constraints dev never exercises: its subnet must not carry a default
# route, and its TLS posture is reported rather than assumed.
################################################################################

run "the_application_gateway_subnet_is_never_default_routed" {
  command = plan

  # AppGW v2 requires direct control-plane access. A default route on its
  # subnet makes the gateway report permanently unhealthy, with no error at
  # plan time and nothing in the resource to suggest the cause.
  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "snet-agw-qa-cus")
    error_message = "The Application Gateway subnet must never be associated with a route table."
  }

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-agw-qa-cus")
    error_message = "The Application Gateway subnet must exist under the derived name."
  }
}

run "ingress_reports_its_own_tls_posture" {
  command = plan

  # With no certificate the gateway is deliberately HTTP-only. The value of
  # the output is that this is stated rather than discovered.
  #
  # The output is a sentence, not a boolean, despite being named
  # ingress_is_encrypted and described in terms of true and false. Asserting on
  # the prefix rather than the whole sentence keeps this test from failing on a
  # reworded message.
  assert {
    condition     = startswith(output.ingress_is_encrypted, "HTTP ONLY")
    error_message = "With no certificate secret ID, ingress must report itself as HTTP-only rather than appearing complete."
  }
}

run "a_certificate_turns_on_the_https_listener" {
  command = plan

  variables {
    application_gateway_certificate_secret_id = "https://kv-cloudcart-qa-cus.vault.azure.net/secrets/tls/00000000000000000000000000000000"
  }

  assert {
    condition     = startswith(output.ingress_is_encrypted, "HTTPS")
    error_message = "Supplying a certificate secret ID must add the HTTPS listener and its redirect. This is the transition the degraded mode exists to make explicit."
  }
}

################################################################################
# Egress: the routing consequence of the strategy
################################################################################

run "nat_gateway_egress_adds_no_default_route" {
  command = plan

  assert {
    condition     = length(output.route_tables_with_default_route) == 0
    error_message = "No route table may carry a default route while egress is by NAT Gateway. A 0.0.0.0/0 route overrides the NAT Gateway and removes outbound access."
  }
}

run "bastion_subnet_is_excluded_from_routing" {
  command = plan

  assert {
    condition     = !contains(flatten(values(output.route_table_subnets)), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must never be associated with a route table. A UDR there breaks Bastion sessions."
  }
}

################################################################################
# Names agree across the modules that share them
################################################################################

run "the_derived_names_reach_every_consumer" {
  command = plan

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-aks-qa-cus")
    error_message = "The AKS subnet must be created under the derived name."
  }

  assert {
    condition     = contains(flatten(values(output.route_table_subnets)), "snet-aks-qa-cus")
    error_message = "The AKS subnet must be associated with the workload route table under the same derived name. A mismatch associates nothing and reports success."
  }

  assert {
    condition     = contains(keys(output.nsg_ids), "nsg-aks-qa-cus")
    error_message = "The AKS NSG must be created under the derived name."
  }

  assert {
    condition     = length(output.nsgs_without_explicit_deny) == 0
    error_message = "Every NSG must end in an explicit inbound deny."
  }
}

################################################################################
# Private DNS covers every service that has a private endpoint
#
# qa matters more than dev here: with data_plane_public_access_enabled false
# there is no public fallback path that happens to work. A missing zone means
# the service is unreachable rather than reachable by the wrong route.
################################################################################

run "every_private_endpoint_service_has_a_zone" {
  command = plan

  assert {
    condition     = length(output.private_dns_zone_ids_by_service) == 4
    error_message = "Key Vault, blob storage, SQL and Redis each need a privatelink zone."
  }

  assert {
    condition     = contains(keys(output.private_dns_zone_ids_by_service), "managed_redis")
    error_message = "Redis must use the managed_redis zone: Azure Managed Redis uses privatelink.redis.azure.net, not the retiring cache zone."
  }
}

################################################################################
# Governance
################################################################################

run "governance_tags_are_applied" {
  command = plan

  assert {
    condition     = output.tags["environment"] == "qa"
    error_message = "The environment tag must match the environment."
  }

  assert {
    condition     = output.tags["costCenter"] == "CC-QA-001"
    error_message = "The chargeback tag must carry the supplied value."
  }
}

################################################################################
# The quota refusal, at the real number
#
# This is the assertion that turns README's "qa cannot be applied here" from a
# claim into something a test run will contradict if it ever stops being true.
# It is written as an assertion on peak_vcpus rather than as an expected
# failure because `expect_failures` cannot name a precondition inside a child
# module — see the note in dev's test file.
################################################################################

run "qa_does_not_fit_this_subscriptions_quota" {
  command = plan

  assert {
    condition     = output.peak_vcpus > 4
    error_message = "qa is documented as not deployable on this subscription, whose regional limit is 4 vCPU and cannot be raised without upgrading to Pay-As-You-Go. If the footprint now fits, the documentation in README.md and variables.tf is stale."
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-agw-qa-cus"]
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-app-qa-cus"]
        if r.name == "Allow-App-Tier"
      ]
    ]))
    error_message = "The business tier must admit the application subnet only. Naming the gateway subnet here makes the three-tier boundary diagrammatic rather than real."
  }

  assert {
    condition = alltrue(flatten([
      for nsg, rules in output.nsg_rules : [
        for r in rules :
        !contains(r.source_address_prefixes, output.subnet_cidrs["snet-agw-qa-cus"])
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
        join(",", r.source_address_prefixes) == output.subnet_cidrs["snet-aks-qa-cus"]
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
