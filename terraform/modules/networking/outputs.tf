################################################################################
# Virtual network
################################################################################

output "vnet_id" {
  description = "ARM resource ID of the virtual network. Private DNS zone links and peerings target this."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Virtual network name."
  value       = azurerm_virtual_network.this.name
}

output "address_space" {
  description = "VNet address space."
  value       = azurerm_virtual_network.this.address_space
}

output "resource_group_name" {
  description = "Resource group containing the network."
  value       = azurerm_virtual_network.this.resource_group_name
}

output "location" {
  description = "Region the network was created in."
  value       = azurerm_virtual_network.this.location
}

################################################################################
# Subnets
#
# Keyed by subnet name so downstream modules address them explicitly —
# module.networking.subnet_ids["snet-app-dev-eus"] — rather than by list
# position, which changes whenever a subnet is added or removed.
################################################################################

output "subnet_ids" {
  description = "Map of subnet name to ARM resource ID. This is what NSG associations, route table associations, private endpoints and scale sets consume."
  value       = { for key, subnet in azurerm_subnet.this : key => subnet.id }
}

output "subnet_cidrs" {
  description = "Map of subnet name to address prefix. NSG rules use these as source and destination prefixes, so tier-to-tier rules are derived from the address plan rather than restated."
  value       = { for key, subnet in azurerm_subnet.this : key => subnet.address_prefixes[0] }
}

output "subnets" {
  description = "Full detail per subnet: id, name, cidr and the network policy settings actually applied."
  value = {
    for key, subnet in azurerm_subnet.this :
    key => {
      id                                = subnet.id
      name                              = subnet.name
      cidr                              = subnet.address_prefixes[0]
      service_endpoints                 = subnet.service_endpoints
      private_endpoint_network_policies = subnet.private_endpoint_network_policies
      default_outbound_access_enabled   = subnet.default_outbound_access_enabled
    }
  }
}

################################################################################
# Egress
################################################################################

output "nat_gateway_id" {
  description = "NAT Gateway resource ID, or null when not deployed."
  value       = var.enable_nat_gateway ? azurerm_nat_gateway.this[0].id : null
}

output "nat_gateway_public_ip" {
  description = "The public IP address all outbound traffic is SNATed to. This is the address to allowlist on any external service the workload calls."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : null
}

output "nat_gateway_is_zonal" {
  description = "Whether the NAT Gateway is pinned to a single availability zone. When true, a zone outage removes egress for every associated subnet. When false the gateway is regional. Neither is zone-redundant — that requires one gateway per zone, or Azure Firewall."
  value       = var.enable_nat_gateway ? length(var.nat_gateway_zones) > 0 : null
}

output "nat_associated_subnets" {
  description = "Subnets whose egress routes through the NAT Gateway. A subnet absent from this list, with no firewall route, has no outbound internet access — default outbound access was retired in September 2025."
  value       = sort(keys(local.nat_associated_subnets))
}

output "subnets_without_egress" {
  description = "Subnets with neither a NAT Gateway association nor implicit outbound access. Expected for AzureBastionSubnet, which manages its own path, but worth checking for anything else that appears here."
  value = sort([
    for key, subnet in var.subnets : key
    if !subnet.default_outbound_access_enabled
    && !contains(keys(local.nat_associated_subnets), key)
  ])
}
