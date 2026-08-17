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

  ##############################################################################
  # Resource IDs, shaped like real ones.
  #
  # Needed only by the apply-mode run at the end of this file. Terraform's
  # generator produces random 8-character strings for computed attributes, and
  # the azurerm provider PARSES the IDs it is handed — client-side, before any
  # API call — so a subnet association given "1p97mteh" fails with "the number
  # of segments didn't match" rather than anything about this configuration.
  #
  # Every ID below is therefore syntactically valid and semantically fake. They
  # are scaffolding for the mocks, not fixtures anything asserts on: a mock ID
  # tells you nothing about the deployment, so nothing here is asserted against
  # one. What the apply run checks is that the OUTPUTS resolve — see the note
  # above that run.
  ##############################################################################

  # A resource group ID is a scope, not just an identifier: role assignments
  # and alert rules are scoped to one, and the provider rejects a scope it
  # cannot classify with "Root scope (/) is invalid" rather than naming the ID.
  # The diagnostics module DISCOVERS what a resource can emit, by reading
  # azurerm_monitor_diagnostic_categories, and refuses to create a setting that
  # would enable nothing. At plan the data source is unknown, so that
  # precondition is never evaluated; at apply the generator returns empty lists
  # and every diagnostic setting in the environment trips it.
  #
  # That is the precondition doing its job on an empty answer rather than a bug
  # — but it means apply mode needs the discovery to return something. These
  # are the shapes the module branches on: an "allLogs" group, so
  # use_category_group takes its true path, and a metric to include.
  mock_data "azurerm_monitor_diagnostic_categories" {
    defaults = {
      log_category_types  = ["Administrative", "Audit", "kube-audit", "kube-audit-admin"]
      log_category_groups = ["allLogs", "audit"]
      metrics             = ["AllMetrics"]
    }
  }

  mock_resource "azurerm_mssql_database" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Sql/servers/sql-mock/databases/db-mock" }
  }

  # Policy objects are attached by ID and parsed like any other.
  mock_resource "azurerm_web_application_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/waf-mock" }
  }
  mock_resource "azurerm_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/firewallPolicies/afwp-mock" }
  }

  mock_resource "azurerm_application_gateway" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/applicationGateways/agw-mock" }
  }
  mock_resource "azurerm_firewall" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/azureFirewalls/afw-mock" }
  }

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock" }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock" }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkSecurityGroups/nsg-mock" }
  }
  mock_resource "azurerm_route_table" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/routeTables/rt-mock" }
  }
  mock_resource "azurerm_nat_gateway" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/natGateways/ng-mock" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.core.windows.net" }
  }

  # A public IP is read as an address, not just an ID: AKS derives its
  # authorized_ip_ranges from the egress address and appends /32, so a random
  # string produces "must start with IPV4 address".
  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/publicIPAddresses/pip-mock"
      ip_address = "198.51.100.1"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock" }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Insights/actionGroups/ag-mock" }
  }
  mock_resource "azurerm_managed_redis" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Cache/redisEnterprise/redis-mock" }
  }
  mock_resource "azurerm_mssql_server" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Sql/servers/sql-mock" }
  }
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock" }
  }

  # Identities are consumed as principals, and a role assignment scope rejects
  # anything that is not a UUID.
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
      principal_id = "44444444-4444-4444-4444-444444444444"
      client_id    = "55555555-5555-5555-5555-555555555555"
      tenant_id    = "11111111-1111-1111-1111-111111111111"
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

  # Inside prod's own AzureFirewallSubnet, 10.30.0.0/26. It said 10.40.0.4 —
  # stage's range — until the mutation campaign put the two files side by side:
  # prod held stage's address and stage held prod's, exactly transposed. Azure
  # accepts an out-of-VNet next hop, because that is how you reach an appliance
  # across a peering, so nothing would have refused it and workload egress
  # would have black-holed against an address that does not exist here.
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

# The next hop has to be an address that exists in THIS network. Azure accepts
# one that does not — a peered appliance is named exactly that way — so the route
# table reads correctly while every workload packet goes to an address nothing
# answers for. prod pinned stage's address and stage pinned prod's, exactly
# transposed, until 2026-08-17.
#
# The containment check lives in the route-table module, which owns the
# precondition. What this environment is responsible for is ARMING it by passing
# its own address space, and a skipped check is indistinguishable from a passed
# one unless something asserts the difference.
run "the_next_hop_is_verified_against_this_vnets_address_space" {
  command = plan

  assert {
    condition     = output.next_hop_containment_checked
    error_message = "prod must pass its own address space to the route-table module. False here means the containment check was SKIPPED, so a next hop from another environment's range would plan clean and black-hole all egress."
  }

  # Keyed by the derived route table name, which a test file cannot reference,
  # so this asserts on the values.
  assert {
    condition     = values(output.virtual_appliance_next_hops) == ["10.30.0.4"]
    error_message = "prod's firewall next hop must be inside prod's own 10.30.0.0/16. 10.40.0.4 is stage's range and is the value this file carried until 2026-08-17."
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

################################################################################
# Apply against the mocks
#
# Every run above is plan-only, which leaves most of this environment's outputs
# untouched: anything derived from a value the provider computes is unknown at
# plan, and an assertion on an unknown is not an assertion. Applying against
# the mocks makes those values known.
#
# The values are mocks, so asserting one equals a particular string would test
# Terraform's generator. What this proves is that the output EXPRESSIONS
# resolve — the try(), the join over a computed attribute, the map
# comprehension over a module that may have count = 0. Those are this
# repository's code, a plan-only run skips them entirely, and a wrong reference
# surfaces here rather than on the day someone runs terraform output.
#
# Apply mode also reaches preconditions that plan cannot evaluate at all: the
# diagnostics module DISCOVERS what a resource can emit through a data source,
# and its "this setting would enable nothing" check is unreachable while that
# data source is unknown.
#
# Still no Azure: mock_provider intercepts every provider operation, so apply
# creates nothing and needs no credentials.
################################################################################

run "the_outputs_resolve_when_the_values_are_known" {
  command = apply

  assert {
    condition     = output.bastion_dns_name != null
    error_message = "The Bastion output must resolve. A null means the module is not being instantiated and the try() around it is masking that."
  }

  assert {
    condition     = output.aks_get_credentials_command != null && output.aks_get_credentials_command != ""
    error_message = "The kubectl command must assemble. It concatenates the resource group and cluster name, both unknown at plan."
  }

  assert {
    condition     = length(output.managed_identity_principal_ids) == length(output.managed_identity_ids)
    error_message = "Every managed identity must expose both an ID and a principal ID. A tier in one map and missing from the other means a role assignment elsewhere silently binds nothing."
  }

  assert {
    condition     = length(output.nsg_ids) == length(output.nsg_rules)
    error_message = "Every NSG must appear in both the ID map and the rule matrix."
  }

  assert {
    condition     = output.key_vault_uri != null && output.storage_blob_endpoint != null && output.sql_server_fqdn != null
    error_message = "The Key Vault, Storage and SQL endpoints must all resolve."
  }

  assert {
    condition     = output.aks_oidc_issuer_url != null
    error_message = "The OIDC issuer URL must resolve — a federated identity credential references it, so a null breaks workload identity."
  }

  assert {
    condition     = output.log_analytics_workspace_id != null
    error_message = "The workspace ID must resolve; every diagnostic setting targets it."
  }

  assert {
    condition     = output.application_gateway_public_ip != null
    error_message = "The Application Gateway public IP must resolve — it is the only ingress path into this environment."
  }

  assert {
    condition     = output.firewall_private_ip != null
    error_message = "The firewall's private IP must resolve. It is the next hop the workload route table points at, so a null here means egress has nowhere to go."
  }
}

################################################################################
# One distinct ID per subnet
#
# mock_resource defaults are per TYPE, so every subnet would otherwise be handed
# the same ID — and the nsg module groups its associations BY subnet ID to catch
# two NSGs claiming one subnet. Identical IDs make that condition genuinely
# true, and the module reports it correctly. The precondition is right; the
# mocks were wrong.
################################################################################

override_resource {
  target = module.networking.azurerm_subnet.this["AzureFirewallSubnet"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/AzureFirewallSubnet"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["AzureBastionSubnet"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/AzureBastionSubnet"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-agw-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-agw-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-app-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-app-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-biz-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-biz-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-db-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-db-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-pep-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-pep-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-mgmt-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mgmt-prod-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-aks-prod-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-aks-prod-cus"
  }
}
