################################################################################
# Network security groups
#
# The `security_rule` argument is deliberately NOT set here. It is
# Optional+Computed in the provider schema, so omitting it means Terraform does
# not manage rules on this resource at all, leaving the separate
# azurerm_network_security_rule resources below as the single owner.
#
# Setting both forms is the NSG equivalent of the inline-subnet trap: each
# apply removes the rules the other form created, and the configuration never
# reaches a clean plan.
################################################################################

resource "azurerm_network_security_group" "this" {
  for_each = var.network_security_groups

  name                = each.key
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.priority_collisions) == 0
      error_message = join("\n", concat(
        ["Rule priorities must be unique within an NSG per direction. Azure rejects duplicates but names only one of the conflicting rules:"],
        local.priority_collisions
      ))
    }

    precondition {
      condition = length(local.duplicate_subnet_associations) == 0
      error_message = join("\n", concat(
        ["Azure permits at most one NSG per subnet. These subnets are claimed by more than one NSG, and whichever applies last would silently replace the other:"],
        local.duplicate_subnet_associations
      ))
    }

    precondition {
      condition = !var.require_explicit_inbound_deny || length(local.nsgs_without_inbound_deny) == 0
      error_message = join(" ", [
        "These NSGs have no explicit inbound deny-all rule:",
        "${join(", ", local.nsgs_without_inbound_deny)}.",
        "Azure's built-in AllowVnetInBound rule at priority 65000 permits ALL traffic between any two VNet addresses on any port,",
        "so an NSG containing only Allow rules provides no isolation between tiers — the built-in rule catches everything the explicit rules did not.",
        "Add an inbound Deny rule (protocol *, source *, destination *, ports *) at a priority below 65000, conventionally 4096.",
        "Set require_explicit_inbound_deny = false only for an NSG deliberately intended to be permissive."
      ])
    }
  }
}

################################################################################
# Security rules
#
# Individual resources rather than inline blocks, so each rule appears as its
# own line in plan output. A firewall change should be readable as "one rule
# added" rather than as a diff of an opaque set.
################################################################################

resource "azurerm_network_security_rule" "this" {
  for_each = local.rules

  name                        = each.value.rule_name
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.value.nsg_name].name

  priority    = each.value.priority
  direction   = each.value.direction
  access      = each.value.access
  protocol    = each.value.protocol
  description = each.value.description

  source_port_range  = each.value.source_port_ranges == null ? each.value.source_port_range : null
  source_port_ranges = each.value.source_port_ranges

  destination_port_range  = each.value.destination_port_range
  destination_port_ranges = each.value.destination_port_ranges

  source_address_prefix   = each.value.source_address_prefix
  source_address_prefixes = each.value.source_address_prefixes

  destination_address_prefix   = each.value.destination_address_prefixes == null ? each.value.destination_address_prefix : null
  destination_address_prefixes = each.value.destination_address_prefixes
}

################################################################################
# Subnet associations
#
# Kept in this module rather than in networking so that the subnet resource and
# its NSG association are not both owned by code that could reorder them. The
# association depends on the rules existing first: associating an NSG whose
# rules have not yet been created would briefly apply a default-deny to live
# traffic.
################################################################################

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = local.associations

  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.this[each.key].id

  depends_on = [azurerm_network_security_rule.this]
}
