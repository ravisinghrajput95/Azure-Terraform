################################################################################
# Route tables
#
# The `route` argument is deliberately NOT set. Like the NSG's security_rule,
# it is Optional+Computed, so omitting it leaves the separate azurerm_route
# resources below as the single owner. Setting both forms means each apply
# removes the routes the other created.
#
# bgp_route_propagation_enabled defaults to false. Leaving BGP propagation on
# means an ExpressRoute or VPN gateway attached later can advertise routes into
# these subnets — potentially a more specific route that bypasses the firewall
# entirely. The egress control would then be defeated by a network change made
# somewhere else, with nothing in this configuration changing.
################################################################################

resource "azurerm_route_table" "this" {
  for_each = var.route_tables

  name                = each.key
  resource_group_name = var.resource_group_name
  location            = var.location

  bgp_route_propagation_enabled = each.value.bgp_route_propagation_enabled

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.duplicate_subnet_claims) == 0
      error_message = join("\n", concat(
        ["Azure permits at most one route table per subnet. These subnets are claimed by more than one:"],
        local.duplicate_subnet_claims
      ))
    }
  }
}

################################################################################
# Routes
#
# Individual resources so each route is its own line in plan output. A routing
# change is the fastest way to cause a total environment outage — it applies in
# seconds and there is no health check — so the diff needs to be readable.
################################################################################

resource "azurerm_route" "this" {
  for_each = local.routes

  name                = each.value.route_name
  resource_group_name = var.resource_group_name
  route_table_name    = azurerm_route_table.this[each.value.table_name].name

  address_prefix         = each.value.address_prefix
  next_hop_type          = each.value.next_hop_type
  next_hop_in_ip_address = each.value.next_hop_in_ip_address

  lifecycle {
    precondition {
      condition = length(local.next_hop_outside_vnet) == 0
      error_message = join("\n", concat(
        [
          "A VirtualAppliance next hop is not an address in this VNet.",
          "Azure ACCEPTS this — a next hop in a peered network is legitimate — so there is no API error to catch it:",
          "",
        ],
        local.next_hop_outside_vnet,
        [
          "",
          "The route applies in seconds, every packet matching it goes to an address nothing in this network answers for,",
          "and the symptom is total egress loss with a routing table that reads exactly as designed.",
          "",
          "If the appliance really is in a peered VNet, leave vnet_address_space empty and record why.",
        ]
      ))
    }
  }
}

################################################################################
# Subnet associations
#
# The preconditions here encode the two documented breakages from
# docs/ARCHITECTURE.md section 2. Neither fails at apply — both break the
# service at runtime, with an error naming the service rather than the route.
################################################################################

resource "azurerm_subnet_route_table_association" "this" {
  for_each = local.associations

  subnet_id      = each.value.subnet_id
  route_table_id = azurerm_route_table.this[each.value.table_name].id

  # Routes must exist before the table is attached. Associating an empty table
  # that is about to receive a default route would briefly leave the subnet
  # with system routing, then switch it — a transition worth avoiding on a
  # live subnet.
  depends_on = [azurerm_route.this]

  lifecycle {
    precondition {
      condition = length(local.forbidden_default_route_violations) == 0
      error_message = join("\n", concat(
        [
          "A 0.0.0.0/0 route would be applied to a subnet that cannot tolerate one.",
          "This does not fail at apply — it breaks the service at runtime, and the error names the service rather than the route:",
          "",
        ],
        local.forbidden_default_route_violations,
        [
          "",
          "Azure Bastion and Application Gateway v2 both require direct outbound access to their control planes.",
          "AzureFirewallSubnet pointing at the firewall is a routing loop.",
        ]
      ))
    }
  }
}
