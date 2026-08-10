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
