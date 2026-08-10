################################################################################
# Placement
################################################################################

variable "resource_group_name" {
  description = "Resource group for the route tables. Should be the \"net\" lifecycle scope."
  type        = string
}

variable "location" {
  description = "Azure region, normalised form."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Route tables
################################################################################

variable "route_tables" {
  description = <<-EOT
    Map of route table name to its configuration.

      bgp_route_propagation_enabled
          Whether routes learned over BGP from an ExpressRoute or VPN gateway
          are applied to the associated subnets. Defaults to FALSE. Leaving it
          enabled means a gateway added later can advertise a route that
          bypasses the intended egress path — a firewall can be silently
          circumvented by a network change made elsewhere.

      routes
          Map of route name to { address_prefix, next_hop_type,
          next_hop_in_ip_address }. May be empty: a route table with no routes
          is still meaningful, because disabling BGP propagation is itself a
          control.

      subnet_ids
          Subnets to associate. Azure permits at most ONE route table per
          subnet.
  EOT

  type = map(object({
    bgp_route_propagation_enabled = optional(bool, false)
    subnet_ids                    = optional(list(string), [])

    routes = optional(map(object({
      address_prefix         = string
      next_hop_type          = string
      next_hop_in_ip_address = optional(string)
    })), {})
  }))

  validation {
    condition = alltrue(flatten([
      for rt in values(var.route_tables) : [
        for route in values(rt.routes) :
        contains(["VirtualAppliance", "VnetLocal", "Internet", "VirtualNetworkGateway", "None"], route.next_hop_type)
      ]
    ]))
    error_message = "next_hop_type must be one of: VirtualAppliance, VnetLocal, Internet, VirtualNetworkGateway, None."
  }

  # A VirtualAppliance route without a next hop address is accepted by
  # Terraform and rejected by Azure. Any other type with an address set is
  # accepted by Azure and the address silently ignored.
  validation {
    condition = alltrue(flatten([
      for rt in values(var.route_tables) : [
        for route in values(rt.routes) :
        (route.next_hop_type == "VirtualAppliance") == (route.next_hop_in_ip_address != null)
      ]
    ]))
    error_message = "next_hop_in_ip_address must be set when next_hop_type is VirtualAppliance, and must be null for every other type."
  }

  validation {
    condition = alltrue(flatten([
      for rt in values(var.route_tables) : [
        for route in values(rt.routes) :
        route.next_hop_in_ip_address == null || can(cidrhost("${route.next_hop_in_ip_address}/32", 0))
      ]
    ]))
    error_message = "next_hop_in_ip_address must be a valid IPv4 address."
  }
}

################################################################################
# Subnets that must never carry a default route
#
# A 0.0.0.0/0 route on these subnets does not fail at apply. It breaks the
# service at runtime, and the resulting failure names the service rather than
# the route — which is why both are among the most common production incidents
# in a hub-and-spoke or DMZ topology.
#
#   AzureBastionSubnet    Bastion requires direct outbound connectivity. A
#                         default route to a firewall makes it fail to
#                         provision, or drops sessions once deployed.
#
#   Application Gateway   AppGW v2 requires direct access to its control plane.
#   subnet                Forcing it through a firewall breaks health probes
#                         and the gateway reports permanently unhealthy.
#
#   AzureFirewallSubnet   The firewall is the next hop. Pointing its own subnet
#                         at itself is a routing loop.
#
#   GatewaySubnet         Same class of problem for VPN/ExpressRoute gateways.
################################################################################

variable "subnets_forbidding_default_route" {
  description = "Subnet NAMES that must never be associated with a route table carrying a 0.0.0.0/0 route. The Azure-reserved names are included by default; add the Application Gateway subnet name, which varies by environment."
  type        = list(string)
  default     = ["AzureBastionSubnet", "AzureFirewallSubnet", "AzureFirewallManagementSubnet", "GatewaySubnet", "RouteServerSubnet"]
}
