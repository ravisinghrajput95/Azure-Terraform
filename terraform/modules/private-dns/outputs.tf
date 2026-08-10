################################################################################
# Zones
#
# zone_ids_by_service is the output private endpoints actually consume: a
# private_dns_zone_group takes a list of zone IDs, and the caller holds a
# service key rather than a zone name.
#
#   private_dns_zone_ids = [module.private_dns.zone_ids_by_service["sql"]]
################################################################################

output "zone_ids_by_service" {
  description = "Map of requested service key to that service's privatelink zone ID. This is what a private endpoint's private_dns_zone_group consumes."
  value = {
    for service, zone_name in local.zone_name_by_requested_service :
    service => azurerm_private_dns_zone.this[zone_name].id
  }
}

output "zone_names_by_service" {
  description = "Map of requested service key to the privatelink zone name Azure expects for it."
  value       = local.zone_name_by_requested_service
}

output "zone_ids" {
  description = "Map of zone name to zone ID, covering both service-derived and additional_zones entries."
  value       = { for name, zone in azurerm_private_dns_zone.this : name => zone.id }
}

output "zone_names" {
  description = "All zone names created, deduplicated. Several service keys share a zone — eventhub and servicebus both use privatelink.servicebus.windows.net."
  value       = sort(tolist(local.zone_names))
}

output "resource_group_name" {
  description = "Resource group holding the zones."
  value       = var.resource_group_name
}

################################################################################
# Links
################################################################################

output "linked_virtual_network_ids" {
  description = "Virtual networks these zones are linked to. A zone with no link is invisible to a VNet's resolver, so its records have no effect there."
  value       = var.virtual_network_ids
}

output "link_count" {
  description = "Total number of virtual network links created — one per zone per VNet."
  value       = length(local.links)
}

output "registration_enabled" {
  description = "Whether linked VNets auto-register VM records into these zones. Should be false for privatelink zones: Azure permits only one registration-enabled link per VNet across all zones, and VM records do not belong in a zone Azure manages for private endpoints."
  value       = var.registration_enabled
}
