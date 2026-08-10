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

  associations = merge([
    for table_name, table in var.route_tables : {
      for subnet_id in table.subnet_ids :
      # Keyed by subnet ID rather than by index, so removing one association
      # does not re-index and recreate the others.
      subnet_id => table_name
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

  # subnet_id => subnet name
  associated_subnet_names = {
    for subnet_id, table_name in local.associations :
    subnet_id => element(split("/", subnet_id), length(split("/", subnet_id)) - 1)
  }

  forbidden_default_route_violations = sort([
    for subnet_id, table_name in local.associations :
    "${local.associated_subnet_names[subnet_id]} would receive a 0.0.0.0/0 route from ${table_name}"
    if contains(local.tables_with_default_route, table_name)
    && contains(var.subnets_forbidding_default_route, local.associated_subnet_names[subnet_id])
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
  subnet_claims = {
    for pair in flatten([
      for table_name, table in var.route_tables : [
        for subnet_id in table.subnet_ids : {
          subnet_id  = subnet_id
          table_name = table_name
        }
      ]
    ]) : "${pair.table_name}|${pair.subnet_id}" => pair
  }

  claims_by_subnet = {
    for key, claim in local.subnet_claims :
    claim.subnet_id => claim.table_name...
  }

  duplicate_subnet_claims = sort([
    for subnet_id, table_names in local.claims_by_subnet :
    "${element(split("/", subnet_id), length(split("/", subnet_id)) - 1)} is claimed by: ${join(", ", sort(table_names))}"
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
