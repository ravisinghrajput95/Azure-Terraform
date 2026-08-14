################################################################################
# Subnet name checks
#
# Azure requires these two subnets to be named exactly. The API rejects a wrong
# name with an error naming the FIREWALL, not the subnet, which sends people to
# look at the firewall configuration for a network problem.
#
# The name is the last path segment of the subnet ID, so this is checkable at
# plan time without a data source.
################################################################################

locals {
  subnet_name            = var.subnet_id == null ? null : element(split("/", var.subnet_id), length(split("/", var.subnet_id)) - 1)
  management_subnet_name = var.management_subnet_id == null ? null : element(split("/", var.management_subnet_id), length(split("/", var.management_subnet_id)) - 1)

  subnet_is_misnamed            = local.subnet_name != "AzureFirewallSubnet"
  management_subnet_is_misnamed = var.management_subnet_id != null && local.management_subnet_name != "AzureFirewallManagementSubnet"
}

################################################################################
# Management plane
#
# The Basic tier ALWAYS requires a separate management subnet and public IP.
# Standard and Premium require them only for forced tunnelling. Missing either
# fails the apply with a message that does not name what is missing.
################################################################################

locals {
  has_management_plane = var.management_subnet_id != null

  basic_without_management = var.sku_tier == "Basic" && !local.has_management_plane
}

################################################################################
# Premium-only capabilities
################################################################################

locals {
  intrusion_detection_requested = var.intrusion_detection_mode != null

  idps_without_premium = local.intrusion_detection_requested && var.sku_tier != "Premium"

  # Terminating TLS on an application rule is Premium-only for the same reason:
  # inspection requires the Premium data path. On a lower tier the rule is
  # accepted and the traffic passes through uninspected.
  tls_terminating_rules = sort(flatten([
    for collection_name, collection in var.application_rule_collections : [
      for rule_name, rule in collection.rules : "${collection_name}/${rule_name}"
      if rule.terminate_tls
    ]
  ]))

  tls_inspection_without_premium = length(local.tls_terminating_rules) > 0 && var.sku_tier != "Premium"
}

################################################################################
# THE ORDERING TRAP
#
# Azure Firewall processes rule collections by TYPE first and priority second:
#
#   1. NAT rules
#   2. Network rules
#   3. Application rules
#
# The type order is fixed and cannot be changed by priority. A network rule
# permitting 0.0.0.0/0 on 443 therefore matches ordinary web traffic BEFORE any
# application rule is consulted, and every FQDN allow-list beneath it becomes
# unreachable.
#
# Nothing reports this. Both rule sets exist, both display as configured, the
# firewall is healthy, and traffic leaves without FQDN filtering. It is the
# single most common way an Azure Firewall ends up permitting what its
# configuration appears to forbid.
#
# Detected as: an ALLOW network rule whose destination covers everything, on a
# port that application rules also serve, while application rules exist.
################################################################################

locals {
  wildcard_destinations = ["*", "0.0.0.0/0", "Internet"]

  # Ports application rules typically serve. A broad network allow on one of
  # these is what shadows them.
  application_ports = ["80", "443", "8080", "8443", "*"]

  has_application_rules = length(var.application_rule_collections) > 0

  broad_network_allows = sort(flatten([
    for collection_name, collection in var.network_rule_collections : [
      for rule_name, rule in collection.rules : "${collection_name}/${rule_name}"
      if collection.action == "Allow"
      && length(setintersection(toset(rule.destination_addresses), toset(local.wildcard_destinations))) > 0
      && length(setintersection(toset(rule.destination_ports), toset(local.application_ports))) > 0
    ]
  ]))

  network_rules_shadow_application_rules = (
    local.has_application_rules
    && length(local.broad_network_allows) > 0
    && !var.acknowledge_broad_network_allow
  )
}

################################################################################
# FQDNs in network rules require the DNS proxy
#
# An FQDN in a NETWORK rule is resolved by the firewall itself. With the proxy
# disabled there is nothing to resolve it: the rule is accepted, shows as
# configured, and matches nothing.
################################################################################

locals {
  network_rules_using_fqdns = sort(flatten([
    for collection_name, collection in var.network_rule_collections : [
      for rule_name, rule in collection.rules : "${collection_name}/${rule_name}"
      if length(rule.destination_fqdns) > 0
    ]
  ]))

  fqdn_network_rules_without_dns_proxy = length(local.network_rules_using_fqdns) > 0 && !var.dns_proxy_enabled
}

################################################################################
# Priority collisions
#
# Two collections of the same type sharing a priority is rejected by Azure with
# an error that names neither collection.
################################################################################

locals {
  network_priorities     = [for _, c in var.network_rule_collections : c.priority]
  application_priorities = [for _, c in var.application_rule_collections : c.priority]
  nat_priorities         = [for _, c in var.nat_rule_collections : c.priority]

  duplicate_network_priorities     = length(local.network_priorities) != length(distinct(local.network_priorities))
  duplicate_application_priorities = length(local.application_priorities) != length(distinct(local.application_priorities))
  duplicate_nat_priorities         = length(local.nat_priorities) != length(distinct(local.nat_priorities))

  has_duplicate_priorities = (
    local.duplicate_network_priorities
    || local.duplicate_application_priorities
    || local.duplicate_nat_priorities
  )
}

################################################################################
# Coverage
################################################################################

locals {
  total_collections = (
    length(var.network_rule_collections)
    + length(var.application_rule_collections)
    + length(var.nat_rule_collections)
  )

  has_any_rules = local.total_collections > 0

  # A firewall that is the egress next hop and permits nothing blackholes every
  # outbound connection while reporting healthy.
  deployed_without_rules = !local.has_any_rules && !var.acknowledge_no_rules

  rule_count = (
    sum(concat([0], [for _, c in var.network_rule_collections : length(c.rules)]))
    + sum(concat([0], [for _, c in var.application_rule_collections : length(c.rules)]))
    + sum(concat([0], [for _, c in var.nat_rule_collections : length(c.rules)]))
  )
}

################################################################################
# Posture
################################################################################

locals {
  is_zone_redundant = length(var.zones) >= 2

  threat_intel_enforces = var.threat_intelligence_mode == "Deny"
  idps_enforces         = var.intrusion_detection_mode == "Deny"

  ##############################################################################
  # Indicative cost
  #
  # Order of magnitude at US list price, before data processing, which is
  # roughly $0.016/GB and is charged on top of every hour below.
  ##############################################################################
  hourly_rate_usd = {
    Basic    = 0.395
    Standard = 1.25
    Premium  = 1.75
  }

  indicative_monthly_cost_usd = ceil(lookup(local.hourly_rate_usd, var.sku_tier, 1.25) * 730)
}
