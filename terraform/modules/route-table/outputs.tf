################################################################################
# Route tables
################################################################################

output "ids" {
  description = "Map of route table name to ARM resource ID."
  value       = { for name, rt in azurerm_route_table.this : name => rt.id }
}

output "names" {
  description = "Map of route table name to name."
  value       = { for name, rt in azurerm_route_table.this : name => rt.name }
}

################################################################################
# Associations
################################################################################

output "associations" {
  description = "Map of \"<table>/<subnet-name>\" to its association detail."
  value       = local.associations
}

output "associated_subnet_names" {
  description = "Map of route table name to the subnet names it is applied to. Names rather than resource IDs, because routing is reviewed by humans."
  value = {
    for table_name in keys(var.route_tables) :
    table_name => sort([
      for key, assoc in local.associations : assoc.subnet_name
      if assoc.table_name == table_name
    ])
  }
}

################################################################################
# Routing posture
################################################################################

output "tables_with_default_route" {
  description = "Route tables carrying a 0.0.0.0/0 route. Empty means egress is not being forced through a virtual appliance — correct when a NAT Gateway provides egress, since a NAT Gateway attaches to the subnet directly and is not a UDR next hop."
  value       = sort(tolist(local.tables_with_default_route))
}

output "tables_without_routes" {
  description = "Route tables with no routes at all. Not necessarily an error: an empty table still disables BGP route propagation on its subnets, which prevents a gateway added later from advertising a route that bypasses the intended egress path."
  value       = local.tables_without_routes
}

output "bgp_propagation_enabled_tables" {
  description = "Route tables where BGP route propagation is left ON. Should normally be empty — a propagated route can be more specific than the configured default and silently divert egress away from the firewall."
  value = sort([
    for name, table in var.route_tables : name
    if table.bgp_route_propagation_enabled
  ])
}

output "route_count" {
  description = "Total number of routes managed by this module."
  value       = length(local.routes)
}
