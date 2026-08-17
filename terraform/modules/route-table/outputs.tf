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

# False means the next-hop containment check did not run, not that it passed.
# The distinction is the whole value of the output: a check skipped because
# vnet_address_space was left empty is indistinguishable from a check that
# succeeded unless something says so out loud.
output "next_hop_containment_checked" {
  description = "Whether every VirtualAppliance next hop was verified to be an address inside this VNet. FALSE means the check was SKIPPED because vnet_address_space is empty — which is correct only when the appliance is deliberately in a peered network. Azure accepts an out-of-VNet next hop either way, so nothing else will report it."
  value       = local.next_hop_containment_checked
}

output "virtual_appliance_next_hops" {
  description = "Map of \"<table>/<route>\" to the VirtualAppliance address it points at. Worth reading on any environment whose egress is inspected: this is the list of addresses that must exist and must answer, and a wrong entry here is invisible in every other output."
  value       = local.virtual_appliance_next_hops
}
