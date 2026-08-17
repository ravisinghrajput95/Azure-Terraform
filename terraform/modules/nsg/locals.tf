################################################################################
# Rule flattening
#
# Rules are declared nested under their NSG but created as individual
# resources, so the nested map is flattened to "<nsg>/<rule>" keys.
#
# Keying on names rather than indices means adding a rule shows exactly one
# addition in the plan. With index keys, inserting a rule in the middle
# re-indexes everything after it and the diff shows a dozen unrelated changes —
# unreviewable when what is being reviewed is a firewall change.
################################################################################

locals {
  rules = merge([
    for nsg_name, nsg in var.network_security_groups : {
      for rule_name, rule in nsg.rules :
      "${nsg_name}/${rule_name}" => merge(rule, {
        nsg_name  = nsg_name
        rule_name = rule_name
      })
    }
  ]...)

  # Filtered on attach_to_subnet, a STATIC boolean — not on `subnet_id !=
  # null`. Filtering on the subnet ID makes the for_each KEY SET depend on a
  # value unknown until apply, so the plan fails from an empty state while
  # succeeding incrementally. That is the shape of bug that works in the
  # environment you built it in and breaks in the next one.
  associations = {
    for nsg_name, nsg in var.network_security_groups :
    nsg_name => nsg.subnet_id
    if nsg.attach_to_subnet
  }
}

################################################################################
# Rule inventory, in evaluation order
#
# Azure evaluates rules by direction then ascending priority, so the inventory
# is sorted that way rather than alphabetically. Priority is zero-padded in the
# sort key because sort() is lexicographic — without padding, priority 1000
# would sort before 200.
################################################################################

locals {
  sorted_rule_keys_by_nsg = {
    for nsg_name in keys(var.network_security_groups) :
    nsg_name => [
      for sort_key in sort([
        for key, rule in local.rules :
        format("%s|%04d|%s", rule.direction, rule.priority, key)
        if rule.nsg_name == nsg_name
      ]) : split("|", sort_key)[2]
    ]
  }

  rules_by_nsg = {
    for nsg_name, rule_keys in local.sorted_rule_keys_by_nsg :
    nsg_name => [
      for key in rule_keys : {
        name        = local.rules[key].rule_name
        priority    = local.rules[key].priority
        direction   = local.rules[key].direction
        access      = local.rules[key].access
        protocol    = local.rules[key].protocol
        description = local.rules[key].description

        # WHO the rule admits, and to WHAT. Without these the inventory
        # reports that an Allow exists on a port and not where it may come
        # from, which is the half that decides whether a tier boundary is real
        # — "Allow 443 inbound" reads identically whether the source is one
        # subnet or the whole internet.
        #
        # Singular and plural forms are collapsed to one list each. The
        # variable requires exactly one of the two to be set, so exactly one
        # side of each coalesce contributes and the result is never ambiguous.
        source_address_prefixes = coalescelist(
          local.rules[key].source_address_prefixes != null ? local.rules[key].source_address_prefixes : [],
          local.rules[key].source_address_prefix != null ? [local.rules[key].source_address_prefix] : [],
        )
        destination_address_prefixes = coalescelist(
          local.rules[key].destination_address_prefixes != null ? local.rules[key].destination_address_prefixes : [],
          local.rules[key].destination_address_prefix != null ? [local.rules[key].destination_address_prefix] : [],
        )
        destination_port_ranges = coalescelist(
          local.rules[key].destination_port_ranges != null ? local.rules[key].destination_port_ranges : [],
          local.rules[key].destination_port_range != null ? [local.rules[key].destination_port_range] : [],
        )
      }
    ]
  }
}

################################################################################
# Priority collisions
#
# Azure requires priorities to be unique within an NSG per direction. It
# rejects duplicates, but the error names only one of the two rules, so the
# cause is not obvious from the message.
################################################################################

locals {
  priority_groups = {
    for key, rule in local.rules :
    "${rule.nsg_name} ${rule.direction} priority ${rule.priority}" => rule.rule_name...
  }

  priority_collisions = sort([
    for group, rule_names in local.priority_groups :
    "${group} is used by: ${join(", ", sort(rule_names))}"
    if length(rule_names) > 1
  ])
}

################################################################################
# Default-deny audit
#
# See the comment on require_explicit_inbound_deny in variables.tf. Without a
# rule of this shape, Azure's AllowVnetInBound default permits all intra-VNet
# traffic and the NSG enforces nothing between tiers.
#
# A qualifying rule is an inbound Deny from any source, on any port, to any
# destination. A narrower deny blocks something specific but still leaves the
# built-in allow catching everything else.
################################################################################

locals {
  nsgs_with_inbound_deny = toset([
    for key, rule in local.rules : rule.nsg_name
    if rule.direction == "Inbound"
    && rule.access == "Deny"
    && rule.source_address_prefix == "*"
    && rule.destination_address_prefix == "*"
    && rule.destination_port_range == "*"
    && rule.protocol == "*"
  ])

  nsgs_without_inbound_deny = sort(tolist(setsubtract(
    toset(keys(var.network_security_groups)),
    local.nsgs_with_inbound_deny
  )))
}

################################################################################
# Subnet association conflicts
#
# Azure permits at most one NSG per subnet. Two NSGs naming the same subnet is
# not a merge — whichever applies last silently replaces the other, and the
# rules the operator believed were in force are simply absent.
################################################################################

locals {
  subnet_association_groups = {
    for nsg_name, subnet_id in local.associations :
    subnet_id => nsg_name...
  }

  duplicate_subnet_associations = sort([
    for subnet_id, nsg_names in local.subnet_association_groups :
    "${subnet_id} is claimed by: ${join(", ", sort(nsg_names))}"
    if length(nsg_names) > 1
  ])
}
