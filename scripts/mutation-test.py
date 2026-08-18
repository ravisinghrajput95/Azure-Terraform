#!/usr/bin/env python3
"""Mutation-test the environment and bootstrap suites.

The 22 module suites were measured rather than asserted: every precondition was
weakened to an always-true expression in turn and the suite re-run, to check
that something actually fails when the guard stops guarding. 106 of 111 are
confirmed that way, and the five that cannot fire are written up individually.

The environment and bootstrap suites never got that treatment. They were
spot-checked while being written, which proves an assertion CAN fail, not that
it fails for the reason it claims. That gap matters more here than anywhere
else in the repository: qa, stage and prod cannot be applied on this
subscription, so these suites are the only verification the three of them will
ever get, and stage's is the only thing that executes the Azure Firewall egress
path anywhere.

A composition root has no preconditions of its own to weaken — it declares no
resources — so the mutation target is the CONFIGURATION rather than the guard.
Each mutation below breaks one thing a specific `run` block claims to hold, and
the campaign records whether that run block noticed.

What makes this a measurement rather than a smoke test is the third outcome. A
mutation that turns the suite red proves nothing on its own: it may have broken
the plan outright, or tripped a precondition inside a child module, or been
caught by an unrelated assertion three runs earlier. So each mutation names the
run block that is SUPPOSED to catch it, and a catch by anything else is
reported separately — an assertion that never fires for its own reason is an
assertion whose claim is untested, whatever colour the suite is.

  guarded             the named run block failed — the assertion earns its place
  guarded-by-module   a child module's precondition fired first, by declared
                      expectation; the property holds, the assertion is not
                      what holds it
  guarded-elsewhere   something else failed first; the named claim is untested
  UNGUARDED           the suite passed with the configuration broken

No Azure. Every suite mocks the provider, so this runs plans and applies
against mocks: no credentials, no backend, nothing created. The bootstrap
target edits .tf files only and `terraform test` keeps its own ephemeral state,
so the live local terraform.tfstate in that directory is never opened — the
checksum is verified on both sides of the run regardless.

Mutations are applied to the working tree and reverted with `git checkout`
immediately afterwards, including on failure or interrupt. The run refuses to
start if any target file is already dirty, because the revert would otherwise
discard someone's work.

  ./scripts/mutation-test.py                    # everything, targets in parallel
  ./scripts/mutation-test.py --target stage     # one environment
  ./scripts/mutation-test.py --only stage-egress-loses-its-default-route
  ./scripts/mutation-test.py --list

Exit status is 0 when every mutation is `guarded` or `guarded-by-module`, 1
otherwise.
"""

import argparse
import concurrent.futures
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# The subprocess environment is built explicitly so that no ARM_* credential in
# the caller's shell can reach a provider. Terraform still needs its own PATH
# and plugin cache.
_PATH = os.environ.get("PATH", "")
_HOME = os.environ.get("HOME", "")

REPO = Path(__file__).resolve().parent.parent

# Kept off the .terraform directory `make plan` depends on, for the reason the
# Makefile explains: `terraform init -backend=false` still READS the backend
# recorded in an existing .terraform, so in an environment that has been
# init'd for real it tries to reach the state account before any test runs.
TF_DATA_DIR = ".terraform-validate"

# The live state for the account that holds every environment's remote state.
# Local, gitignored, and not recoverable by reading state back — the account is
# what holds the state. Nothing here should touch it; this proves it did not.
LIVE_STATE = REPO / "bootstrap" / "terraform.tfstate"

TARGET_DIRS = {
    "dev": REPO / "terraform" / "environments" / "dev",
    "qa": REPO / "terraform" / "environments" / "qa",
    "stage": REPO / "terraform" / "environments" / "stage",
    "prod": REPO / "terraform" / "environments" / "prod",
    "bootstrap": REPO / "bootstrap",
}


class Mutation:
    """One broken thing, and the run block that is supposed to notice.

    `module_guard` records the case where breaking the thing makes the plan
    invalid inside a child module. `terraform test` halts a file at the first
    run that ERRORS rather than merely failing an assertion, so those mutations
    are always attributed to the first run block and no later one executes:
    the environment assertion cannot be reached, and the module precondition is
    what actually holds the property.

    That is a real result, not a pass. It says the environment assertion
    documents an intent that something else enforces — worth keeping, worth not
    counting as coverage, and worth naming here so that a change in which layer
    catches it shows up as a change rather than as noise. The text is the
    reason, and it is printed in the report.
    """

    def __init__(self, ident, target, expect, why, edits, module_guard=None):
        self.id = ident
        self.target = target
        self.expect = expect
        self.why = why
        self.edits = edits
        self.module_guard = module_guard


def M(ident, target, expect, why, edits, module_guard=None):
    return Mutation(ident, target, expect, why, edits, module_guard)


################################################################################
# The catalogue
#
# One mutation per claim, phrased as the defect a reviewer would plausibly ship
# rather than as arbitrary damage. `expect` names the run block whose assertion
# describes exactly this failure.
################################################################################

MUTATIONS = [
    ###########################################################################
    # dev — the only environment that has ever run
    ###########################################################################
    M(
        "dev-naming-region-drifts",
        "dev",
        "plans_with_the_documented_inputs",
        "dev's location default said eastus while the platform ran in Central US, "
        "and every name would have read -eus. This is that defect, reintroduced.",
        [("main.tf", "  location    = var.location", '  location    = "eastus"')],
    ),
    M(
        "dev-footprint-doubles",
        "dev",
        "the_profile_decides_the_topology",
        "A second compute tier doubles the vCPU footprint against a 4 vCPU quota.",
        [("main.tf", "  compute_tier_count = 1", "  compute_tier_count = 2")],
    ),
    M(
        "dev-locks-turned-on",
        "dev",
        "the_profile_decides_the_topology",
        "A management lock blocks terraform destroy, the primary cost control here.",
        [
            (
                "main.tf",
                "  enable_resource_locks = module.profile.enable_resource_locks",
                "  enable_resource_locks = true",
            )
        ],
    ),
    M(
        "dev-workspace-cap-removed",
        "dev",
        "the_profile_decides_the_topology",
        "Uncapping dev's workspace removes the protection on the free 5 GB allowance.",
        [
            (
                "main.tf",
                "  daily_quota_gb    = module.profile.profile.log_daily_quota_gb",
                "  daily_quota_gb    = -1",
            )
        ],
    ),
    M(
        "dev-default-route-over-nat-gateway",
        "dev",
        "nat_gateway_egress_adds_no_default_route",
        "A 0.0.0.0/0 route takes precedence over the NAT Gateway attachment and "
        "removes outbound access entirely. Terraform accepts it without comment.",
        [
            (
                "main.tf",
                """      routes = module.profile.egress_strategy == "firewall" ? {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = var.firewall_private_ip
        }
      } : {}""",
                """      routes = {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = "10.10.0.4"
        }
      }""",
            )
        ],
    ),
    M(
        "dev-bastion-subnet-associated",
        "dev",
        "bastion_subnet_is_excluded_from_routing_and_egress",
        "Associating AzureBastionSubnet with a route table breaks Bastion sessions.",
        [
            (
                "main.tf",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]\n"
                '        "AzureBastionSubnet" = module.networking.subnet_ids["AzureBastionSubnet"]',
            )
        ],
    ),
    M(
        "dev-aks-subnet-name-loses-region",
        "dev",
        "the_derived_subnet_name_reaches_every_consumer",
        "The derived subnet name stops matching what every consumer expects.",
        [
            (
                "main.tf",
                '  aks_subnet_name  = "snet-aks-${local.environment}-${local.loc}"',
                '  aks_subnet_name  = "snet-aks-${local.environment}"',
            )
        ],
    ),
    M(
        "dev-aks-nsg-name-loses-region",
        "dev",
        "the_derived_subnet_name_reaches_every_consumer",
        "The NSG name is derived separately from the subnet name, so it drifts "
        "separately too — this is the bastion NSG that read eus for months.",
        [
            (
                "main.tf",
                '  aks_nsg_name     = "nsg-aks-${local.environment}-${local.loc}"',
                '  aks_nsg_name     = "nsg-aks-${local.environment}"',
            )
        ],
    ),
    M(
        "dev-mgmt-subnet-unassociated",
        "dev",
        "every_workload_subnet_is_routed_and_secured",
        "An unassociated subnet silently keeps system routing.",
        [
            (
                "main.tf",
                "        (local.mgmt_subnet) = module.networking.subnet_ids[local.mgmt_subnet]\n",
                "",
            )
        ],
    ),
    M(
        "dev-fallthrough-deny-becomes-allow",
        "dev",
        "every_workload_subnet_is_routed_and_secured",
        "Without a low-priority deny, Azure's built-in AllowVnetInBound at 65000 "
        "permits every subnet to reach every other one. The NSG still exists and "
        "still reads as configured.",
        [
            (
                "nsg-rules.tf",
                """  deny_all_inbound = {
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny\"""",
                """  deny_all_inbound = {
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Allow\"""",
            )
        ],
    module_guard=(
            "the nsg module's own precondition requires an explicit inbound "
            "deny and fires first"
        ),
    ),
    M(
        "dev-redis-zone-is-the-retiring-one",
        "dev",
        "every_private_endpoint_service_has_a_zone",
        "Azure Cache for Redis uses privatelink.redis.cache.windows.net; this "
        "platform runs Managed Redis on privatelink.redis.azure.net. The wrong "
        "zone resolves the cache PUBLICLY from inside the VNet.",
        [
            (
                "main.tf",
                '  services = ["keyvault", "blob", "sql", "managed_redis"]',
                '  services = ["keyvault", "blob", "sql", "redis"]',
            )
        ],
    module_guard=(
            "the redis module looks its zone up by service key, so a missing "
            "managed_redis entry fails the plan before any output is evaluated"
        ),
    ),
    M(
        "dev-cost-centre-hardcoded",
        "dev",
        "governance_tags_are_applied",
        "Chargeback and incident response query these tags; a literal here "
        "detaches them from the supplied value.",
        [
            (
                "main.tf",
                "  cost_center         = var.cost_center",
                '  cost_center         = "CC-MUTANT-000"',
            )
        ],
    ),
    M(
        "dev-subscription-guid-unvalidated",
        "dev",
        "a_non_guid_subscription_is_refused",
        "azurerm 4.x no longer falls back to the CLI's selected subscription, so "
        "a malformed value must fail at plan rather than reaching the provider. "
        "Weakened to a permissive regex rather than to `true`: Terraform rejects "
        "a validation condition that does not reference its own variable, so the "
        "obvious always-true form never gets evaluated at all — the campaign "
        "would report the suite red for a reason that has nothing to do with it.",
        [
            (
                "variables.tf",
                '    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))',
                '    condition     = can(regex("^.*$", var.subscription_id))',
            )
        ],
    ),
    M(
        "dev-cap-reset-hour-unbounded",
        "dev",
        "an_impossible_cap_reset_hour_is_refused",
        "The hour defines the window the cap-warning query sums over. A wrong one "
        "produces a query Azure accepts and reports healthy while summing the "
        "wrong period.",
        [
            (
                "variables.tf",
                "    condition     = var.log_analytics_daily_cap_reset_hour_utc >= 0 && var.log_analytics_daily_cap_reset_hour_utc <= 23",
                "    condition     = var.log_analytics_daily_cap_reset_hour_utc >= 0",
            )
        ],
    ),
    M(
        "dev-data-plane-names-port-6380",
        "dev",
        "the_private_endpoint_subnet_admits_exactly_the_data_ports",
        "The regression these suites exist for: 6380 is Azure Cache for Redis, "
        "and this platform's Managed Redis listens on 10000. Every pod-to-cache "
        "call falls through to the deny, and nothing reports it.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_ranges = ["443", "1433", "10000"]',
                '          destination_port_ranges = ["443", "1433", "6380"]',
            )
        ],
    ),
    M(
        "dev-ssh-admitted-from-mgmt-subnet",
        "dev",
        "ssh_is_admitted_only_from_the_bastion_subnet",
        "No instance carries a public IP, so a second SSH source is a way in "
        "that bypasses Bastion entirely.",
        [
            (
                "nsg-rules.tf",
                "    destination_port_range     = \"22\"\n    source_address_prefix      = local.cidr[local.bastion_subnet]",
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.mgmt_subnet]',
            )
        ],
    ),
    M(
        "dev-ingress-source-stops-being-internet",
        "dev",
        "the_application_tier_ingress_source_is_the_internet_in_dev",
        "A public load balancer DNATs without replacing the source address, so a "
        "subnet CIDR here matches nothing and dev's ingress stops working.",
        [
            (
                "nsg-rules.tf",
                '  app_ingress_source = module.profile.enable_application_gateway ? "10.10.1.0/24" : "Internet"',
                '  app_ingress_source = "10.10.1.0/24"',
            )
        ],
    ),
    M(
        "dev-bastion-module-not-instantiated",
        "dev",
        "the_outputs_resolve_when_the_values_are_known",
        "count = 0 with a try() around the output produces null rather than an "
        "error — the masking the apply-mode run exists to catch.",
        [
            (
                "main.tf",
                "  count  = module.profile.enable_bastion ? 1 : 0",
                "  count  = 0",
            )
        ],
    ),
    ###########################################################################
    # qa — Application Gateway on NAT Gateway egress
    ###########################################################################
    M(
        "qa-naming-region-drifts",
        "qa",
        "plans_with_the_documented_inputs",
        "Every derived name carries the wrong region.",
        [("main.tf", "  location    = var.location", '  location    = "eastus"')],
    ),
    M(
        "qa-footprint-doubles",
        "qa",
        "the_profile_decides_the_topology",
        "A second compute tier doubles the vCPU footprint.",
        [("main.tf", "  compute_tier_count = 1", "  compute_tier_count = 2")],
    module_guard=(
            "the profile module refuses a footprint over the supplied quota, "
            "and doubling the tier count trips it before peak_vcpus is asserted"
        ),
    ),
    M(
        "qa-workspace-gains-a-cap",
        "qa",
        "the_profile_decides_the_topology",
        "A cap drops data once hit, including security signals, and blinds every "
        "alert rule at the same time.",
        [
            (
                "main.tf",
                "  daily_quota_gb    = module.profile.profile.log_daily_quota_gb",
                "  daily_quota_gb    = 0.5",
            )
        ],
    ),
    M(
        "qa-profile-reads-the-wrong-environment",
        "qa",
        "qa_does_not_fit_this_subscriptions_quota",
        "The environment name reaches only three modules, which is what makes a "
        "wrong one here invisible everywhere else.",
        [
            (
                "main.tf",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = local.environment",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = \"dev\"",
            )
        ],
    module_guard=(
            "handing qa dev's profile changes the cluster and Bastion shapes "
            "too, and one of those modules refuses the combination first"
        ),
    ),
    M(
        "qa-gateway-subnet-default-routed",
        "qa",
        "the_application_gateway_subnet_is_never_default_routed",
        "AppGW v2 needs direct control-plane access and reports permanently "
        "unhealthy behind a default route, with nothing in the resource to "
        "suggest the cause.",
        [
            (
                "main.tf",
                "    local.agw_subnet_name,\n  ]",
                "  ]",
            ),
            (
                "main.tf",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]\n"
                "        (local.agw_subnet_name) = module.networking.subnet_ids[local.agw_subnet_name]",
            ),
        ],
    ),
    M(
        "qa-tls-posture-claims-a-certificate",
        "qa",
        "ingress_reports_its_own_tls_posture",
        "The posture output would report HTTPS while the listener is plain HTTP.",
        [
            (
                "main.tf",
                "  agw_has_certificate = var.application_gateway_certificate_secret_id != null",
                "  agw_has_certificate = true",
            )
        ],
    module_guard=(
            "the application-gateway module refuses an HTTPS listener with no "
            "certificate, so the false posture never reaches an output"
        ),
    ),
    M(
        "qa-waf-flips-to-prevention",
        "qa",
        "ingress_reports_its_own_tls_posture",
        "qa is where WAF rules are tuned. Prevention against an untuned rule set "
        "blocks legitimate traffic, which is how a WAF ends up disabled outright.",
        [
            (
                "main.tf",
                "  waf_mode     = module.profile.profile.waf_mode",
                '  waf_mode     = "Prevention"',
            )
        ],
    ),
    M(
        "qa-certificate-never-reaches-the-listener",
        "qa",
        "a_certificate_turns_on_the_https_listener",
        "Supplying a certificate would change nothing — the variable is accepted "
        "and dropped.",
        [
            (
                "main.tf",
                "  ssl_certificate_key_vault_secret_id = var.application_gateway_certificate_secret_id",
                "  ssl_certificate_key_vault_secret_id = null",
            )
        ],
    ),
    M(
        "qa-default-route-over-nat-gateway",
        "qa",
        "nat_gateway_egress_adds_no_default_route",
        "A 0.0.0.0/0 route overrides the NAT Gateway and removes outbound access.",
        [
            (
                "main.tf",
                """      routes = module.profile.egress_strategy == "firewall" ? {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = var.firewall_private_ip
        }
      } : {}""",
                """      routes = {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          # qa's own range. It said 10.40.0.4 — stage's — until the
          # route-table module gained its containment check and refused the
          # plan before qa's assertion could be reached. The mutation has to
          # break exactly one thing to measure exactly one claim.
          next_hop_in_ip_address = "10.20.0.4"
        }
      }""",
            )
        ],
    ),
    M(
        "qa-bastion-subnet-associated",
        "qa",
        "bastion_subnet_is_excluded_from_routing",
        "A UDR on AzureBastionSubnet breaks Bastion sessions.",
        [
            (
                "main.tf",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]\n"
                '        "AzureBastionSubnet" = module.networking.subnet_ids["AzureBastionSubnet"]',
            )
        ],
    ),
    M(
        "qa-aks-subnet-name-loses-region",
        "qa",
        "the_derived_names_reach_every_consumer",
        "The derived subnet name stops matching what every consumer expects.",
        [
            (
                "main.tf",
                '  aks_subnet_name  = "snet-aks-${local.environment}-${local.loc}"',
                '  aks_subnet_name  = "snet-aks-${local.environment}"',
            )
        ],
    ),
    M(
        "qa-redis-zone-is-the-retiring-one",
        "qa",
        "every_private_endpoint_service_has_a_zone",
        "The wrong privatelink zone resolves the cache publicly from inside the VNet.",
        [
            (
                "main.tf",
                '  services = ["keyvault", "blob", "sql", "managed_redis"]',
                '  services = ["keyvault", "blob", "sql"]',
            )
        ],
    module_guard=(
            "the redis module looks its zone up by service key, so a missing "
            "managed_redis entry fails the plan before any output is evaluated"
        ),
    ),
    M(
        "qa-cost-centre-hardcoded",
        "qa",
        "governance_tags_are_applied",
        "The chargeback tag detaches from the supplied value.",
        [
            (
                "main.tf",
                "  cost_center         = var.cost_center",
                '  cost_center         = "CC-MUTANT-000"',
            )
        ],
    ),
    M(
        "qa-ingress-source-widens-to-internet",
        "qa",
        "the_application_tier_admits_only_the_gateway_subnet",
        "If this reads Internet the WAF is no longer the only way in, and every "
        "request can bypass it. Access and port read identically either way.",
        [
            (
                "nsg-rules.tf",
                "  app_ingress_source = module.profile.enable_application_gateway ? local.cidr[local.agw_subnet] : \"Internet\"",
                '  app_ingress_source = "Internet"',
            )
        ],
    ),
    M(
        "qa-business-tier-admits-the-gateway",
        "qa",
        "the_business_tier_cannot_be_reached_from_ingress",
        "Skipping a tier is a lateral movement path, and it makes the three-tier "
        "boundary diagrammatic rather than real.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.app_subnet]',
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.agw_subnet]',
            )
        ],
    ),
    M(
        "qa-data-plane-names-port-6380",
        "qa",
        "the_private_endpoint_subnet_admits_exactly_the_data_ports",
        "6380 is Azure Cache for Redis; this platform's Managed Redis is on 10000.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_ranges = ["443", "1433", "10000"]',
                '          destination_port_ranges = ["443", "1433", "6380"]',
            )
        ],
    ),
    M(
        "qa-ssh-admitted-from-mgmt-subnet",
        "qa",
        "ssh_is_admitted_only_from_the_bastion_subnet",
        "A second SSH source bypasses Bastion, which is the only operator path in.",
        [
            (
                "nsg-rules.tf",
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.bastion_subnet]',
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.mgmt_subnet]',
            )
        ],
    ),
    M(
        "qa-bastion-module-not-instantiated",
        "qa",
        "the_outputs_resolve_when_the_values_are_known",
        "count = 0 behind a try() produces null rather than an error.",
        [
            (
                "main.tf",
                "  count  = module.profile.enable_bastion ? 1 : 0",
                "  count  = 0",
            )
        ],
    ),
    ###########################################################################
    # stage — the only place the Azure Firewall egress path runs at all
    ###########################################################################
    M(
        "stage-naming-region-drifts",
        "stage",
        "plans_with_the_documented_inputs",
        "Every derived name carries the wrong region.",
        [("main.tf", "  location    = var.location", '  location    = "eastus"')],
    ),
    M(
        "stage-egress-loses-its-default-route",
        "stage",
        "egress_is_forced_through_the_firewall",
        "The UDR is what forces traffic into the firewall. Without it the "
        "firewall is billed in full and inspects nothing, and there is nothing "
        "in either resource to indicate the traffic is not arriving.",
        [
            (
                "main.tf",
                '          address_prefix = "0.0.0.0/0"',
                '          address_prefix = "10.0.0.0/8"',
            )
        ],
    ),
    M(
        "stage-firewall-subnet-default-routed",
        "stage",
        "the_firewall_subnets_are_never_default_routed",
        "A default route on AzureFirewallSubnet sends the firewall's own egress "
        "back into itself.",
        [
            (
                "main.tf",
                '    "AzureFirewallSubnet",\n',
                "",
            ),
            (
                "main.tf",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]\n"
                '        "AzureFirewallSubnet" = module.networking.subnet_ids["AzureFirewallSubnet"]',
            ),
        ],
    ),
    M(
        "stage-next-hop-fallback-removed",
        "stage",
        "the_next_hop_falls_back_to_the_firewall_module",
        "The fallback is what lets the environment be applied in one pass. "
        "Without it a null variable leaves the route pointing nowhere.",
        [
            (
                "main.tf",
                """          next_hop_in_ip_address = coalesce(
            var.firewall_private_ip,
            try(module.firewall[0].private_ip_address, null),
          )""",
                "          next_hop_in_ip_address = var.firewall_private_ip",
            )
        ],
    ),
    M(
        "stage-tls-posture-claims-a-certificate",
        "stage",
        "ingress_is_the_application_gateway",
        "The posture output would report HTTPS while the listener is plain HTTP.",
        [
            (
                "main.tf",
                "  agw_has_certificate = var.application_gateway_certificate_secret_id != null",
                "  agw_has_certificate = true",
            )
        ],
    module_guard=(
            "the application-gateway module refuses an HTTPS listener with no "
            "certificate, so the false posture never reaches an output"
        ),
    ),
    M(
        "stage-waf-drops-to-detection",
        "stage",
        "ingress_is_the_application_gateway",
        "stage matches prod's WAF posture, and it is where the enforcing "
        "configuration is exercised before prod sees it. Detection logs what "
        "Prevention would have blocked and blocks nothing; the portal shows a "
        "WAF either way.",
        [
            (
                "main.tf",
                "  waf_mode     = module.profile.profile.waf_mode",
                '  waf_mode     = "Detection"',
            )
        ],
    ),
    M(
        "stage-next-hop-check-disarmed",
        "stage",
        "the_next_hop_is_verified_against_this_vnets_address_space",
        "Dropping the address space silently disarms the route-table module's "
        "containment check. The plan stays valid and the module reports the "
        "check as not performed, which is exactly the state that made the "
        "transposed next hop survive for months.",
        [
            (
                "main.tf",
                "  vnet_address_space = local.vnet_address_space\n\n  subnets_forbidding_default_route = [",
                "  subnets_forbidding_default_route = [",
            )
        ],
    ),
    M(
        "stage-next-hop-takes-prods-address",
        "stage",
        "the_next_hop_is_verified_against_this_vnets_address_space",
        "The original defect: stage's next hop in prod's range. Now refused by "
        "the route-table module rather than planning clean, which is why this "
        "is expected to be caught by the module rather than by an assertion.",
        [
            (
                "main.tf",
                '  vnet_address_space = local.vnet_address_space',
                '  vnet_address_space = ["10.30.0.0/16"]',
            )
        ],
        module_guard=(
            "the route-table module's next-hop containment precondition refuses "
            "the plan, which is the point of adding it"
        ),
    ),
    M(
        "stage-aks-subnet-name-loses-region",
        "stage",
        "the_derived_names_reach_every_consumer",
        "A mismatch associates nothing and reports success — and in this "
        "environment it also means that subnet's egress bypasses the firewall.",
        [
            (
                "main.tf",
                '  aks_subnet_name  = "snet-aks-${local.environment}-${local.loc}"',
                '  aks_subnet_name  = "snet-aks-${local.environment}"',
            )
        ],
    ),
    M(
        "stage-fallthrough-deny-becomes-allow",
        "stage",
        "the_derived_names_reach_every_consumer",
        "Without the fallthrough deny, Azure's built-in AllowVnetInBound permits "
        "all intra-VNet traffic.",
        [
            (
                "nsg-rules.tf",
                """  deny_all_inbound = {
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny\"""",
                """  deny_all_inbound = {
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Allow\"""",
            )
        ],
    module_guard=(
            "the nsg module's own precondition requires an explicit inbound "
            "deny and fires first"
        ),
    ),
    M(
        "stage-mgmt-subnet-unassociated",
        "stage",
        "every_workload_subnet_is_routed",
        "An unassociated subnet keeps system routing, so its egress leaves "
        "without passing the firewall.",
        [
            (
                "main.tf",
                "        (local.mgmt_subnet) = module.networking.subnet_ids[local.mgmt_subnet]\n",
                "",
            )
        ],
    ),
    M(
        "stage-redis-zone-dropped",
        "stage",
        "every_private_endpoint_service_has_a_zone",
        "A private endpoint with no matching zone registers no A record, and the "
        "client resolves the service publicly from inside the VNet.",
        [
            (
                "main.tf",
                '  services = ["keyvault", "blob", "sql", "managed_redis"]',
                '  services = ["keyvault", "blob", "sql"]',
            )
        ],
    module_guard=(
            "the redis module looks its zone up by service key, so a missing "
            "managed_redis entry fails the plan before any output is evaluated"
        ),
    ),
    M(
        "stage-cost-centre-hardcoded",
        "stage",
        "governance_tags_are_applied",
        "The chargeback tag detaches from the supplied value.",
        [
            (
                "main.tf",
                "  cost_center         = var.cost_center",
                '  cost_center         = "CC-MUTANT-000"',
            )
        ],
    ),
    M(
        "stage-profile-reads-the-wrong-environment",
        "stage",
        "stage_does_not_fit_this_subscriptions_quota",
        "The environment name reaches only three modules. A wrong one here "
        "silently gives stage qa's topology and qa's footprint.",
        [
            (
                "main.tf",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = local.environment",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = \"qa\"",
            )
        ],
    ),
    M(
        "stage-ingress-source-widens-to-internet",
        "stage",
        "the_application_tier_admits_only_the_gateway_subnet",
        "If this reads Internet the WAF is no longer the only way in.",
        [
            (
                "nsg-rules.tf",
                "  app_ingress_source = module.profile.enable_application_gateway ? local.cidr[local.agw_subnet] : \"Internet\"",
                '  app_ingress_source = "Internet"',
            )
        ],
    ),
    M(
        "stage-business-tier-admits-the-gateway",
        "stage",
        "the_business_tier_cannot_be_reached_from_ingress",
        "Skipping a tier is a lateral movement path.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.app_subnet]',
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.agw_subnet]',
            )
        ],
    ),
    M(
        "stage-data-plane-names-port-6380",
        "stage",
        "the_private_endpoint_subnet_admits_exactly_the_data_ports",
        "6380 is Azure Cache for Redis; Managed Redis is on 10000. This "
        "environment has never run, so nothing else could surface it.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_ranges = ["443", "1433", "10000"]',
                '          destination_port_ranges = ["443", "1433", "6380"]',
            )
        ],
    ),
    M(
        "stage-ssh-admitted-from-mgmt-subnet",
        "stage",
        "ssh_is_admitted_only_from_the_bastion_subnet",
        "A second SSH source bypasses Bastion.",
        [
            (
                "nsg-rules.tf",
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.bastion_subnet]',
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.mgmt_subnet]',
            )
        ],
    ),
    M(
        "stage-bastion-module-not-instantiated",
        "stage",
        "the_outputs_resolve_when_the_values_are_known",
        "count = 0 behind a try() produces null rather than an error.",
        [
            (
                "main.tf",
                "  count  = module.profile.enable_bastion ? 1 : 0",
                "  count  = 0",
            )
        ],
    ),
    ###########################################################################
    # prod — locks, IDPS and an enforcing WAF
    ###########################################################################
    M(
        "prod-naming-region-drifts",
        "prod",
        "plans_with_the_documented_inputs",
        "Every derived name carries the wrong region.",
        [("main.tf", "  location    = var.location", '  location    = "eastus"')],
    ),
    M(
        "prod-locks-turned-off",
        "prod",
        "production_controls_are_wired",
        "The locks are the reason prod differs from dev here. Off, terraform "
        "destroy works against production.",
        [
            (
                "main.tf",
                "  enable_resource_locks = module.profile.enable_resource_locks",
                "  enable_resource_locks = false",
            )
        ],
    ),
    M(
        "prod-waf-drops-to-detection",
        "prod",
        "production_controls_are_wired",
        "Detection logs what Prevention would have blocked and blocks nothing. "
        "The right starting point for an untuned rule set and the wrong place to "
        "stop — and the portal shows a WAF either way.",
        [
            (
                "main.tf",
                "  waf_mode     = module.profile.profile.waf_mode",
                '  waf_mode     = "Detection"',
            )
        ],
    ),
    M(
        "prod-workspace-gains-a-cap",
        "prod",
        "production_controls_are_wired",
        "A cap drops data once hit, including security signals, and blinds every "
        "alert rule at once. This is the failure that was measured in dev: "
        "kube-audit at 995 MB/day against a 512 MB/day cap.",
        [
            (
                "main.tf",
                "  daily_quota_gb    = module.profile.profile.log_daily_quota_gb",
                "  daily_quota_gb    = 0.5",
            )
        ],
    ),
    M(
        "prod-egress-loses-its-default-route",
        "prod",
        "egress_is_forced_through_the_firewall",
        "Without the UDR the firewall is a billed appliance no traffic reaches.",
        [
            (
                "main.tf",
                '          address_prefix = "0.0.0.0/0"',
                '          address_prefix = "10.0.0.0/8"',
            )
        ],
    ),
    M(
        "prod-firewall-subnet-default-routed",
        "prod",
        "the_subnets_that_forbid_a_default_route_have_none",
        "The firewall would route its own egress through itself.",
        [
            (
                "main.tf",
                '    "AzureFirewallSubnet",\n',
                "",
            ),
            (
                "main.tf",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]",
                "        (local.aks_subnet)  = module.networking.subnet_ids[local.aks_subnet]\n"
                '        "AzureFirewallSubnet" = module.networking.subnet_ids["AzureFirewallSubnet"]',
            ),
        ],
    ),
    M(
        "prod-tls-posture-claims-a-certificate",
        "prod",
        "ingress_is_the_application_gateway",
        "prod is where HTTP-only ingress matters most, and the degraded mode is "
        "reported rather than refused — so the report has to be true.",
        [
            (
                "main.tf",
                "  agw_has_certificate = var.application_gateway_certificate_secret_id != null",
                "  agw_has_certificate = true",
            )
        ],
    module_guard=(
            "the application-gateway module refuses an HTTPS listener with no "
            "certificate, so the false posture never reaches an output"
        ),
    ),
    M(
        "prod-certificate-never-reaches-the-listener",
        "prod",
        "a_certificate_turns_on_the_https_listener",
        "Supplying a certificate would change nothing.",
        [
            (
                "main.tf",
                "  ssl_certificate_key_vault_secret_id = var.application_gateway_certificate_secret_id",
                "  ssl_certificate_key_vault_secret_id = null",
            )
        ],
    ),
    M(
        "prod-aks-subnet-name-loses-region",
        "prod",
        "the_derived_names_reach_every_consumer",
        "A mismatch associates nothing and reports success.",
        [
            (
                "main.tf",
                '  aks_subnet_name  = "snet-aks-${local.environment}-${local.loc}"',
                '  aks_subnet_name  = "snet-aks-${local.environment}"',
            )
        ],
    ),
    M(
        "prod-next-hop-check-disarmed",
        "prod",
        "the_next_hop_is_verified_against_this_vnets_address_space",
        "Dropping the address space silently disarms the containment check "
        "while the plan stays valid.",
        [
            (
                "main.tf",
                "  vnet_address_space = local.vnet_address_space\n\n  subnets_forbidding_default_route = [",
                "  subnets_forbidding_default_route = [",
            )
        ],
    ),
    M(
        "prod-mgmt-subnet-unassociated",
        "prod",
        "every_workload_subnet_is_routed",
        "An unassociated subnet's egress leaves without passing the firewall.",
        [
            (
                "main.tf",
                "        (local.mgmt_subnet) = module.networking.subnet_ids[local.mgmt_subnet]\n",
                "",
            )
        ],
    ),
    M(
        "prod-redis-zone-dropped",
        "prod",
        "every_private_endpoint_service_has_a_zone",
        "A private endpoint with no matching zone resolves publicly from inside "
        "the VNet.",
        [
            (
                "main.tf",
                '  services = ["keyvault", "blob", "sql", "managed_redis"]',
                '  services = ["keyvault", "blob", "sql"]',
            )
        ],
    module_guard=(
            "the redis module looks its zone up by service key, so a missing "
            "managed_redis entry fails the plan before any output is evaluated"
        ),
    ),
    M(
        "prod-cost-centre-hardcoded",
        "prod",
        "governance_tags_are_applied",
        "The chargeback tag detaches from the supplied value.",
        [
            (
                "main.tf",
                "  cost_center         = var.cost_center",
                '  cost_center         = "CC-MUTANT-000"',
            )
        ],
    ),
    M(
        "prod-profile-reads-the-wrong-environment",
        "prod",
        "prod_does_not_fit_this_subscriptions_quota",
        "The environment name reaches only three modules, so a wrong one here "
        "gives prod qa's footprint and qa's controls without touching anything "
        "that looks like a control.",
        [
            (
                "main.tf",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = local.environment",
                "module \"profile\" {\n  source = \"../../modules/profile\"\n\n  environment             = \"qa\"",
            )
        ],
    ),
    M(
        "prod-ingress-source-widens-to-internet",
        "prod",
        "the_application_tier_admits_only_the_gateway_subnet",
        "If this reads Internet the WAF is no longer the only way in.",
        [
            (
                "nsg-rules.tf",
                "  app_ingress_source = module.profile.enable_application_gateway ? local.cidr[local.agw_subnet] : \"Internet\"",
                '  app_ingress_source = "Internet"',
            )
        ],
    ),
    M(
        "prod-business-tier-admits-the-gateway",
        "prod",
        "the_business_tier_cannot_be_reached_from_ingress",
        "Skipping a tier is a lateral movement path.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.app_subnet]',
                '          destination_port_range     = "8443"\n          source_address_prefix      = local.cidr[local.agw_subnet]',
            )
        ],
    ),
    M(
        "prod-data-plane-names-port-6380",
        "prod",
        "the_private_endpoint_subnet_admits_exactly_the_data_ports",
        "6380 is Azure Cache for Redis; Managed Redis is on 10000.",
        [
            (
                "nsg-rules.tf",
                '          destination_port_ranges = ["443", "1433", "10000"]',
                '          destination_port_ranges = ["443", "1433", "6380"]',
            )
        ],
    ),
    M(
        "prod-ssh-admitted-from-mgmt-subnet",
        "prod",
        "ssh_is_admitted_only_from_the_bastion_subnet",
        "A second SSH source bypasses Bastion.",
        [
            (
                "nsg-rules.tf",
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.bastion_subnet]',
                '    destination_port_range     = "22"\n    source_address_prefix      = local.cidr[local.mgmt_subnet]',
            )
        ],
    ),
    M(
        "prod-bastion-module-not-instantiated",
        "prod",
        "the_outputs_resolve_when_the_values_are_known",
        "count = 0 behind a try() produces null rather than an error.",
        [
            (
                "main.tf",
                "  count  = module.profile.enable_bastion ? 1 : 0",
                "  count  = 0",
            )
        ],
    ),
    ###########################################################################
    # bootstrap — the only deployed configuration, and the only one on local
    # state. It declares its own resources, so the precondition can be weakened
    # in place the way the module campaign weakened all 110.
    ###########################################################################
    M(
        "bootstrap-container-name-loses-its-environment",
        "bootstrap",
        "creates_one_container_per_environment",
        "The container name is written into each environment's backend.conf, so "
        "a change here points an environment at a container that does not exist.",
        [
            (
                "main.tf",
                '  name               = "tfstate-${each.value}"',
                '  name               = "tfstate"',
            )
        ],
    ),
    M(
        "bootstrap-container-set-stops-following-the-variable",
        "bootstrap",
        "adding_an_environment_adds_its_container",
        "A missing container is a blocked deployment: it is the one prerequisite "
        "before an environment can run terraform init.",
        [
            (
                "main.tf",
                "  for_each = var.environments",
                '  for_each = toset(["dev", "qa", "stage", "prod"])',
            )
        ],
    ),
    M(
        "bootstrap-state-key-loses-its-environment",
        "bootstrap",
        "backend_config_is_usable_as_written",
        "Two environments sharing a state key share a state file, and the second "
        "apply adopts the first's resources.",
        [
            (
                "outputs.tf",
                '      "key                  = \\"cloudcart.${env}.tfstate\\"",',
                '      "key                  = \\"cloudcart.tfstate\\"",',
            )
        ],
    ),
    M(
        "bootstrap-backend-drops-entra-auth",
        "bootstrap",
        "backend_config_is_usable_as_written",
        "The account has shared keys disabled, so a backend config without this "
        "cannot reach state at all — and it fails at init as an authentication "
        "error rather than a configuration one.",
        [
            (
                "outputs.tf",
                '      "use_azuread_auth     = true",',
                '      "use_azuread_auth     = false",',
            )
        ],
    ),
    M(
        "bootstrap-soft-delete-window-misreported",
        "bootstrap",
        "a_soft_delete_window_of_exactly_a_week_is_allowed",
        "The summary is what someone reads instead of checking the account, so a "
        "wrong number there is worse than no summary. Measured against the "
        "seven-day run rather than the one whose error message claims this: "
        "state_protections_are_reported_accurately pins 30 while its own input "
        "is 30, so it cannot tell a derived value from a hardcoded one. The "
        "campaign found that, and the note in the test file records it.",
        [
            (
                "outputs.tf",
                'var.blob_soft_delete_retention_days > 0 ? "Blob soft delete retains deletions for ${var.blob_soft_delete_retention_days} days."',
                'var.blob_soft_delete_retention_days > 0 ? "Blob soft delete retains deletions for 30 days."',
            )
        ],
    ),
    M(
        "bootstrap-shared-key-warning-suppressed",
        "bootstrap",
        "a_weakened_posture_is_reported_as_a_warning",
        "A shared key bypasses RBAC entirely and is attributable to nobody. "
        "Enabling it must be reported, not hidden.",
        [
            (
                "outputs.tf",
                'var.shared_access_key_enabled ? "WARNING: shared key access is ENABLED. The backends use Entra auth and do not need it; a leaked key grants total control of every environment\'s state." : "Shared key access disabled; Entra ID only.",',
                '"Shared key access disabled; Entra ID only.",',
            )
        ],
    ),
    M(
        "bootstrap-soft-delete-floor-removed",
        "bootstrap",
        "a_soft_delete_window_too_short_to_help_is_refused",
        "A window shorter than a week rarely outlives the weekend on which the "
        "deletion happened. 0 disables the protection deliberately; 1 to 6 is "
        "someone thinking they have it.",
        [
            (
                "main.tf",
                "      condition     = var.blob_soft_delete_retention_days == 0 || var.blob_soft_delete_retention_days >= 7",
                "      condition     = var.blob_soft_delete_retention_days >= 0",
            )
        ],
    ),
    M(
        "bootstrap-account-name-charset-unvalidated",
        "bootstrap",
        "a_malformed_storage_account_name_is_refused",
        "Azure rejects a malformed storage account name with an error that does "
        "not name the rule it broke. Widened to permit hyphens, so only the "
        "charset half of the rule is weakened.",
        [
            (
                "variables.tf",
                '    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))',
                '    condition     = can(regex("^[a-z0-9-]{3,24}$", var.storage_account_name))',
            )
        ],
    ),
    M(
        "bootstrap-account-name-length-unvalidated",
        "bootstrap",
        "an_oversized_storage_account_name_is_refused",
        "The same validation carries two claims; this weakens only the length "
        "bound, so each is measured on its own.",
        [
            (
                "variables.tf",
                '    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))',
                '    condition     = can(regex("^[a-z0-9]{3,64}$", var.storage_account_name))',
            )
        ],
    ),
    M(
        "bootstrap-resource-group-name-unvalidated",
        "bootstrap",
        "a_malformed_resource_group_name_is_refused",
        "This configuration has no caller to validate its inputs first, so the "
        "variable validations are the only thing between a typo and an Azure "
        "error that does not name the rule it broke.",
        [
            (
                "variables.tf",
                '    condition     = can(regex("^[a-zA-Z0-9._()-]{1,90}$", var.resource_group_name))',
                '    condition     = can(regex("^.*$", var.resource_group_name))',
            )
        ],
    ),
]


################################################################################
# Running one mutation
################################################################################

ANSI = re.compile(r"\x1b\[[0-9;]*m")
RUN_RESULT = re.compile(r'run "([A-Za-z0-9_]+)"\.\.\.\s*(pass|fail|skip)')


def run_terraform(directory, args, timeout=900):
    """Invoke terraform in `directory` with the isolated data directory."""
    env = {
        "TF_DATA_DIR": TF_DATA_DIR,
        "TF_IN_AUTOMATION": "1",
        "PATH": _PATH,
        "HOME": _HOME,
        # No ARM_* credentials are set, and none are needed: every suite mocks
        # the provider. If one ever stopped mocking, it would fail here rather
        # than reach Azure.
    }
    proc = subprocess.run(
        ["terraform", *args],
        cwd=directory,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, ANSI.sub("", proc.stdout + proc.stderr)


def parse_runs(output):
    """Return (failed, passed) run-block names."""
    failed, passed = [], []
    for name, result in RUN_RESULT.findall(output):
        (failed if result == "fail" else passed).append(name)
    return failed, passed


def error_summaries(output):
    """The `Error:` headlines, which say whether a failure was an assertion.

    Terraform draws its diagnostics inside a box, so the headline arrives as
    "│ Error: Test assertion failed" rather than at the start of the line. A
    matcher that misses that reports every genuine error as "no detail", which
    is the difference between a result you can act on and one you cannot.
    """
    seen, out = set(), []
    for line in output.splitlines():
        line = line.lstrip("│╷╵| ").strip()
        if line.startswith("Error: ") and line not in seen:
            seen.add(line)
            out.append(line[len("Error: ") :])
    return out


def apply_edits(directory, edits):
    """Apply every edit, requiring each `old` to appear exactly once."""
    touched = []
    for relpath, old, new in edits:
        path = directory / relpath
        text = path.read_text()
        count = text.count(old)
        if count != 1:
            raise LookupError(
                f"{relpath}: pattern occurs {count} times, expected exactly 1.\n"
                f"  {old.splitlines()[0][:80]}"
            )
        path.write_text(text.replace(old, new, 1))
        touched.append(path)
    return touched


def revert(paths):
    if not paths:
        return
    subprocess.run(
        ["git", "checkout", "--", *[str(p) for p in paths]],
        cwd=REPO,
        check=True,
        capture_output=True,
    )


def run_mutation(mutation, verbose=False):
    directory = TARGET_DIRS[mutation.target]
    touched = []
    started = time.time()
    try:
        touched = apply_edits(directory, mutation.edits)
    except LookupError as exc:
        revert(touched)
        return {
            "id": mutation.id,
            "target": mutation.target,
            "expect": mutation.expect,
            "outcome": "STALE",
            "detail": str(exc),
            "seconds": 0.0,
        }

    try:
        code, output = run_terraform(directory, ["test"])
    finally:
        revert(touched)

    failed, _ = parse_runs(output)
    errors = error_summaries(output)
    elapsed = time.time() - started

    if mutation.expect in failed:
        outcome, detail = "guarded", ""
    elif mutation.module_guard and (failed or code != 0):
        outcome = "guarded-by-module"
        detail = mutation.module_guard
    elif failed:
        outcome = "guarded-elsewhere"
        detail = "caught by " + ", ".join(failed)
        if errors:
            detail += f" ({errors[0]})"
    elif code != 0:
        # Red without a named run block: the configuration did not even load,
        # so no assertion was exercised.
        outcome = "guarded-elsewhere"
        detail = errors[0] if errors else "suite errored before any run block"
    else:
        outcome = "UNGUARDED"
        detail = "suite passed with the configuration broken"

    if verbose:
        print(output)

    return {
        "id": mutation.id,
        "target": mutation.target,
        "expect": mutation.expect,
        "outcome": outcome,
        "detail": detail,
        "seconds": elapsed,
    }


def run_target(target, mutations, verbose=False):
    """Init once, then run this target's mutations one at a time."""
    directory = TARGET_DIRS[target]
    code, output = run_terraform(
        directory, ["init", "-backend=false", "-input=false"], timeout=600
    )
    if code != 0:
        return [
            {
                "id": f"{target}-init",
                "target": target,
                "expect": "",
                "outcome": "STALE",
                "detail": f"terraform init failed: {output.strip().splitlines()[-1] if output.strip() else code}",
                "seconds": 0.0,
            }
        ]

    results = []
    for mutation in mutations:
        result = run_mutation(mutation, verbose=verbose)
        print(
            f"  {result['outcome']:<18} {result['target']}/{result['id']}"
            + (f"  — {result['detail']}" if result["detail"] else ""),
            flush=True,
        )
        results.append(result)
    return results


################################################################################
# Safety and entry point
################################################################################


def dirty_targets(targets):
    """Target directories with uncommitted changes — reverting would eat them."""
    dirty = []
    for target in targets:
        directory = TARGET_DIRS[target]
        proc = subprocess.run(
            ["git", "status", "--porcelain", "--", str(directory)],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=True,
        )
        if proc.stdout.strip():
            dirty.append((target, proc.stdout.strip()))
    return dirty


def check_catalogue(mutations):
    """Every mutation must name a run block that still exists.

    A mutation whose `expect` names a run block that has since been renamed or
    deleted can never be `guarded`. It reports `guarded-elsewhere` forever,
    which reads as a weak assertion in the suite rather than as a stale entry
    here — the campaign accusing the tests of a fault that is its own. This is
    cheap enough to run on every `make check`, and it is the one way the
    catalogue rots silently.
    """
    problems = []

    seen = {}
    for mutation in mutations:
        if mutation.id in seen:
            problems.append(f"duplicate id: {mutation.id}")
        seen[mutation.id] = mutation

    run_names = {}
    for target, directory in TARGET_DIRS.items():
        names = set()
        for path in sorted((directory / "tests").glob("*.tftest.hcl")):
            names.update(re.findall(r'^run "([A-Za-z0-9_]+)"', path.read_text(), re.M))
        run_names[target] = names

    for mutation in mutations:
        if mutation.expect not in run_names.get(mutation.target, set()):
            problems.append(
                f"{mutation.target}/{mutation.id}: no run block named "
                f'"{mutation.expect}" in {mutation.target}/tests/'
            )

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)

    print(
        f"{len(mutations) - len(problems)}/{len(mutations)} mutations name a run "
        "block that exists."
    )
    return 1 if problems else 0


def state_checksum():
    if not LIVE_STATE.exists():
        return None
    return hashlib.sha256(LIVE_STATE.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(
        description="Mutation-test the environment and bootstrap suites.",
    )
    parser.add_argument(
        "--target",
        action="append",
        choices=sorted(TARGET_DIRS),
        help="Limit to one target; repeatable. Default is all of them.",
    )
    parser.add_argument("--only", action="append", help="Run one mutation by id.")
    parser.add_argument("--list", action="store_true", help="List mutations and exit.")
    parser.add_argument(
        "--check-catalogue",
        action="store_true",
        help="Verify every mutation names a run block that still exists, and "
        "that no two mutations share an id. Reads files only — no terraform, no "
        "edits — so it is safe to run from `make check` on a dirty tree.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Apply and revert every edit without running terraform, to check the "
        "catalogue still matches the configuration. Seconds rather than minutes, "
        "and the failure mode it catches — a mutation that silently stopped "
        "applying — would otherwise read as a suite that got better.",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=len(TARGET_DIRS),
        help="Targets to run in parallel. Mutations within a target are serial, "
        "because they edit the same files.",
    )
    parser.add_argument("--verbose", action="store_true", help="Print terraform output.")
    args = parser.parse_args()

    selected = MUTATIONS
    if args.target:
        selected = [m for m in selected if m.target in args.target]
    if args.only:
        selected = [m for m in selected if m.id in args.only]

    if not selected:
        print("no mutations selected", file=sys.stderr)
        return 1

    if args.list:
        for mutation in selected:
            print(f"{mutation.target:<10} {mutation.id:<48} -> {mutation.expect}")
        print(f"\n{len(selected)} mutations")
        return 0

    if args.check_catalogue:
        return check_catalogue(selected)

    if shutil.which("terraform") is None:
        print("terraform is not on PATH", file=sys.stderr)
        return 1

    targets = sorted({m.target for m in selected})

    dirty = dirty_targets(targets)
    if dirty:
        print(
            "Refusing to run: these targets have uncommitted changes, and every\n"
            "mutation is reverted with `git checkout`, which would discard them.\n",
            file=sys.stderr,
        )
        for target, status in dirty:
            print(f"  {target}:\n{status}", file=sys.stderr)
        return 1

    if args.dry_run:
        stale = 0
        for mutation in selected:
            touched = []
            try:
                touched = apply_edits(TARGET_DIRS[mutation.target], mutation.edits)
                print(f"  ok    {mutation.target}/{mutation.id}")
            except LookupError as exc:
                stale += 1
                print(f"  STALE {mutation.target}/{mutation.id}: {exc}")
            finally:
                revert(touched)
        print(f"\n{len(selected) - stale}/{len(selected)} mutations still apply cleanly.")
        return 1 if stale else 0

    before = state_checksum()

    print(f"{len(selected)} mutations across {len(targets)} targets: {', '.join(targets)}")
    print("mock_provider throughout — no credentials, no backend, nothing created.\n")

    by_target = {t: [m for m in selected if m.target == t] for t in targets}
    results = []
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {
            pool.submit(run_target, t, by_target[t], args.verbose): t for t in targets
        }
        try:
            for future in concurrent.futures.as_completed(futures):
                results.extend(future.result())
        except KeyboardInterrupt:
            print("\ninterrupted — reverting", file=sys.stderr)
            for target in targets:
                subprocess.run(
                    ["git", "checkout", "--", str(TARGET_DIRS[target])],
                    cwd=REPO,
                    capture_output=True,
                )
            raise

    after = state_checksum()
    if before != after:
        print(
            f"\nSTOP: {LIVE_STATE} changed during this run "
            f"({before} -> {after}). Nothing here should have opened it.",
            file=sys.stderr,
        )
        return 1

    ###########################################################################
    # Report
    ###########################################################################

    order = {
        "UNGUARDED": 0,
        "guarded-elsewhere": 1,
        "STALE": 2,
        "guarded-by-module": 3,
        "guarded": 4,
    }
    results.sort(key=lambda r: (order.get(r["outcome"], 9), r["target"], r["id"]))

    print("\n" + "=" * 78)
    counts = {}
    for result in results:
        counts[result["outcome"]] = counts.get(result["outcome"], 0) + 1

    for outcome in ("UNGUARDED", "guarded-elsewhere", "STALE", "guarded-by-module"):
        rows = [r for r in results if r["outcome"] == outcome]
        if not rows:
            continue
        print(f"\n{outcome} ({len(rows)}):")
        for row in rows:
            print(f"  {row['target']}/{row['id']}")
            print(f"      expected {row['expect']} to fail")
            print(f"      {row['detail']}")

    guarded = counts.get("guarded", 0)
    by_module = counts.get("guarded-by-module", 0)
    print(
        f"\n{guarded}/{len(results)} mutations were caught by the run block that "
        f"claims to guard them, in {time.time() - started:.0f}s."
    )
    if by_module:
        print(
            f"{by_module} more were caught by a child module's precondition before "
            "any environment assertion could run. Those properties are held; the "
            "environment assertion is not what holds them."
        )
    if before is not None:
        print(f"{LIVE_STATE.name} unchanged ({before[:12]}).")

    return 0 if guarded + by_module == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
