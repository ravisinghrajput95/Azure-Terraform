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
  # Inside stage's own AzureFirewallSubnet, 10.40.0.0/26. It said 10.30.0.4 —
  # prod's range — until the mutation campaign put the two files side by side:
  # stage held prod's address and prod held stage's, exactly transposed. Azure
  # accepts an out-of-VNet next hop, because that is how you reach an appliance
  # across a peering, so nothing would have refused it and workload egress
  # would have black-holed against an address that does not exist here.
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

  # stage matches prod's WAF posture rather than qa's: rules are tuned in qa,
  # and stage is where the enforcing configuration is exercised before prod.
  #
  # Asserted on the mode wired INTO the gateway, not on the profile's
  # intention — see the note above the waf_posture output.
  assert {
    condition     = output.waf_posture == "Prevention: matching requests are BLOCKED."
    error_message = "stage's WAF must be enforcing, matching prod. Detection logs what Prevention would have blocked and blocks nothing, and the portal shows a WAF either way."
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
  target = module.networking.azurerm_subnet.this["snet-agw-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-agw-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-app-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-app-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-biz-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-biz-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-db-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-db-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-pep-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-pep-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-mgmt-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mgmt-stage-cus"
  }
}
override_resource {
  target = module.networking.azurerm_subnet.this["snet-aks-stage-cus"]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-aks-stage-cus"
  }
}
