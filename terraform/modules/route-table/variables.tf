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

      subnets
          Map of subnet NAME to subnet ID. A map keyed by name, not a list of
          IDs, for two reasons: the key set stays known at plan time so
          for_each resolves from an empty state, and the forbidden-default-route
          check can compare names without parsing them out of IDs that are
          themselves unknown until apply.
  EOT

  type = map(object({
    bgp_route_propagation_enabled = optional(bool, false)
    subnets                       = optional(map(string), {})

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

################################################################################
# The VNet these tables serve
#
# Supplied so a VirtualAppliance next hop can be checked to be an address that
# exists in this network. Azure ACCEPTS a next hop outside the VNet — that is
# how a peered or ExpressRoute-reachable appliance is named — so there is no
# API error to rely on. The route applies in seconds, every packet matching it
# is handed to an address nothing answers for, and the symptom is total egress
# loss with a routing table that reads exactly as designed.
#
# This is not hypothetical here. stage's test file pinned prod's firewall
# address and prod's pinned stage's, exactly transposed, and nothing in the
# repository objected: the plan was clean, the "a default route exists"
# assertion passed, and only reading the two files side by side found it.
#
# Optional, because a hub-and-spoke deployment legitimately points at an
# appliance in another VNet. Left empty the check cannot run — which is
# reported by next_hop_containment_checked rather than left to look like a
# check that passed.
################################################################################

variable "vnet_address_space" {
  description = "Address space of the VNet these route tables serve, as CIDR strings. When set, every VirtualAppliance next hop must fall inside it. Leave empty ONLY when the next hop is deliberately in a peered network — an empty list disables the check, and next_hop_containment_checked then reports false."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.vnet_address_space : can(cidrhost(cidr, 0))
    ])
    error_message = "Every entry in vnet_address_space must be a valid CIDR block."
  }
}
