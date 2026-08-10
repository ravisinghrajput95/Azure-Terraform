################################################################################
# Private DNS zones
#
# Zones are global; they take no location argument.
#
# These must exist BEFORE any private endpoint is created. A private endpoint
# whose DNS zone group finds no matching zone registers no A record, and the
# client then falls back to public DNS — resolving the service to its public
# address from inside the VNet. The endpoint exists, the NSG permits it, and
# traffic leaves the network anyway.
################################################################################

resource "azurerm_private_dns_zone" "this" {
  for_each = local.zone_names

  name                = each.value
  resource_group_name = var.resource_group_name

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.unknown_services) == 0
      error_message = join(" ", [
        "Unknown service keys: ${join(", ", local.unknown_services)}.",
        "Valid keys are: ${join(", ", sort(keys(local.zone_name_by_service)))}.",
        "If the service genuinely has no key here, add it to the module's table rather than using additional_zones —",
        "a mistyped zone name has no error path and results in a private endpoint that silently resolves publicly."
      ])
    }

    precondition {
      condition = length(local.region_scoped_requested) == 0 || var.location_hint != null
      error_message = join(" ", [
        "These services have region-scoped privatelink zones and require location_hint:",
        "${join(", ", local.region_scoped_requested)}.",
        "Without it the zone name would contain a literal placeholder and resolve for nothing."
      ])
    }
  }
}

################################################################################
# Virtual network links
#
# A zone with no link to a VNet is invisible to that VNet's resolver. The zone
# exists, holds correct records, and nothing in the network can see it.
#
# registration_enabled stays false. Azure permits at most ONE
# registration-enabled link per virtual network across all zones, and spending
# it on a privatelink zone both pollutes a zone Azure manages on behalf of
# private endpoints and makes the slot unavailable for a genuine
# VM-registration zone later.
################################################################################

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.links

  name                  = "link-${each.value.link_name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_name].name
  virtual_network_id    = each.value.vnet_id

  registration_enabled = var.registration_enabled
  resolution_policy    = var.resolution_policy

  tags = var.tags

  lifecycle {
    precondition {
      condition = !var.registration_enabled || length(local.zone_names) <= 1
      error_message = join(" ", [
        "registration_enabled is true across ${length(local.zone_names)} zones.",
        "Azure permits at most one registration-enabled virtual network link per VNet across ALL private DNS zones,",
        "so this would fail at apply after creating some of the links.",
        "Privatelink zones should always use registration_enabled = false."
      ])
    }
  }
}
