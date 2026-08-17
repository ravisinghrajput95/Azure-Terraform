################################################################################
# Flattening
################################################################################

locals {
  routes = merge([
    for table_name, table in var.route_tables : {
      for route_name, route in table.routes :
      "${table_name}/${route_name}" => merge(route, {
        table_name = table_name
        route_name = route_name
      })
    }
  ]...)

  # Keyed by "<table>/<subnet-name>". Both components are static map keys, so
  # the for_each key set is known at plan time even from an empty state — a
  # key derived from a subnet ID would be unknown until apply and fail the plan
  # for any fresh environment.
  associations = merge([
    for table_name, table in var.route_tables : {
      for subnet_name, subnet_id in table.subnets :
      "${table_name}/${subnet_name}" => {
        table_name  = table_name
        subnet_name = subnet_name
        subnet_id   = subnet_id
      }
    }
  ]...)
}

################################################################################
# Default-route safety
#
# A subnet name is the last path segment of its ARM resource ID:
#   /subscriptions/.../virtualNetworks/<vnet>/subnets/<name>
################################################################################

locals {
  tables_with_default_route = toset([
    for key, route in local.routes : route.table_name
    if route.address_prefix == "0.0.0.0/0"
  ])

  # Subnet names come straight from the map keys, so this check resolves at
  # PLAN time. Extracting a name from a subnet ID would defer it to apply,
  # which is exactly when a bad route has already been sent to Azure.
  forbidden_default_route_violations = sort([
    for key, assoc in local.associations :
    "${assoc.subnet_name} would receive a 0.0.0.0/0 route from ${assoc.table_name}"
    if contains(local.tables_with_default_route, assoc.table_name)
    && contains(var.subnets_forbidding_default_route, assoc.subnet_name)
  ])
}

################################################################################
# Next-hop containment
#
# A VirtualAppliance next hop has to be an address inside this VNet, because the
# appliance it names is in this VNet. Azure does not enforce that — a next hop
# in a peered network is legitimate — so a transposed or stale address produces
# a route table that reads correctly and black-holes everything matching it.
#
# Terraform has no "is this address inside this prefix" function, so the test is
# to mask the address with the prefix's own length and compare network
# addresses: 10.40.0.4 under /16 is 10.40.0.0, which is the network of
# 10.40.0.0/16, so it is inside. can() guards the arithmetic rather than letting
# an IPv6 entry or a malformed prefix throw.
#
# Unknown addresses are skipped deliberately. stage and prod may take the next
# hop from the firewall module's computed private IP, which is unknown at plan;
# Terraform then defers the whole precondition to apply, where the value is
# known and the check still runs. What it must not do is report a pass over a
# value it never saw.
################################################################################

locals {
  next_hop_containment_checked = length(var.vnet_address_space) > 0

  virtual_appliance_next_hops = {
    for key, route in local.routes : key => route.next_hop_in_ip_address
    if route.next_hop_type == "VirtualAppliance" && route.next_hop_in_ip_address != null
  }

  # The empty-list guard is not cosmetic: anytrue([]) is false, so without it a
  # disabled check would report every next hop as a violation.
  next_hop_outside_vnet = !local.next_hop_containment_checked ? [] : sort([
    for key, ip in local.virtual_appliance_next_hops :
    "${key} points at ${ip}, which is not inside ${join(", ", var.vnet_address_space)}"
    # try() rather than `can(...) && ...`: Terraform 1.9.8, which CI pins, does
    # NOT short-circuit &&, so the guarded expression would be evaluated anyway
    # and throw on the input the guard exists to reject. A failed mask yields
    # null, which matches no network.
    if !anytrue([
      for cidr in var.vnet_address_space :
      try(cidrhost("${ip}/${split("/", cidr)[1]}", 0), null) == cidrhost(cidr, 0)
    ])
  ])
}

################################################################################
# Duplicate association detection
#
# Azure permits at most one route table per subnet. Because local.associations
# is keyed by subnet ID, a second table claiming the same subnet would silently
# overwrite the first entry during the merge rather than producing an error —
# so the conflict is detected against the raw input instead.
################################################################################

locals {
  claims_by_subnet = {
    for key, assoc in local.associations :
    assoc.subnet_name => assoc.table_name...
  }

  duplicate_subnet_claims = sort([
    for subnet_name, table_names in local.claims_by_subnet :
    "${subnet_name} is claimed by: ${join(", ", sort(table_names))}"
    if length(table_names) > 1
  ])
}

################################################################################
# Reporting
################################################################################

locals {
  tables_without_routes = sort([
    for table_name, table in var.route_tables : table_name
    if length(table.routes) == 0
  ])
}
