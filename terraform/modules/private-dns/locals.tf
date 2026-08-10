################################################################################
# Service key to privatelink zone name
#
# These names are dictated by Azure. A private endpoint's DNS zone group looks
# for a zone whose name matches exactly; anything else and no A record is
# written.
#
# Note that several services need more than one zone. Storage is the common
# case: blob, file, queue, table and dfs are separate sub-resources with
# separate zones, and a private endpoint for blob does not make file resolve.
################################################################################

locals {
  # Region-scoped zone names must still evaluate when location_hint is null,
  # because Terraform builds the whole map eagerly even for unrequested
  # services. The placeholder is never reachable in a valid configuration: the
  # precondition in main.tf rejects a region-scoped service without a hint.
  region = coalesce(var.location_hint, "REGION-HINT-REQUIRED")

  zone_name_by_service = {
    # Databases
    sql    = "privatelink.database.windows.net"
    sql_mi = "privatelink.${local.region}.database.windows.net"

    # Storage — one zone per sub-resource
    blob        = "privatelink.blob.core.windows.net"
    file        = "privatelink.file.core.windows.net"
    queue       = "privatelink.queue.core.windows.net"
    table       = "privatelink.table.core.windows.net"
    dfs         = "privatelink.dfs.core.windows.net"
    web_storage = "privatelink.web.core.windows.net"

    # Security
    keyvault = "privatelink.vaultcore.azure.net"

    # Caching
    redis            = "privatelink.redis.cache.windows.net"
    redis_enterprise = "privatelink.redisenterprise.cache.azure.net"

    # Messaging
    servicebus = "privatelink.servicebus.windows.net"
    eventhub   = "privatelink.servicebus.windows.net"

    # Other data
    cosmos_sql = "privatelink.documents.azure.com"
    search     = "privatelink.search.windows.net"
    appconfig  = "privatelink.azconfig.io"

    # Compute and platform
    acr         = "privatelink.azurecr.io"
    aks         = "privatelink.${local.region}.azmk8s.io"
    app_service = "privatelink.azurewebsites.net"
    signalr     = "privatelink.service.signalr.net"

    # Management
    monitor      = "privatelink.monitor.azure.com"
    automation   = "privatelink.azure-automation.net"
    backup       = "privatelink.${local.region}.backup.windowsazure.com"
    storage_sync = "privatelink.afs.azure.net"
  }

  unknown_services = sort(tolist(setsubtract(
    toset(var.services),
    toset(keys(local.zone_name_by_service))
  )))

  # Services whose zone name embeds a region. Requesting one without supplying
  # location_hint yields a zone containing the literal placeholder, which
  # resolves for nothing.
  region_scoped_services = ["sql_mi", "aks", "backup"]

  region_scoped_requested = [
    for service in var.services : service
    if contains(local.region_scoped_services, service)
  ]
}

################################################################################
# Zone set
#
# Several service keys deliberately map to the same zone name — eventhub and
# servicebus share privatelink.servicebus.windows.net. Deduplicating by zone
# name means requesting both does not attempt to create the zone twice.
################################################################################

locals {
  service_zone_names = [
    for service in var.services :
    lookup(local.zone_name_by_service, service, "UNKNOWN-SERVICE-${service}")
  ]

  zone_names = toset(concat(local.service_zone_names, var.additional_zones))

  # Reverse map, so a caller holding a service key can find its zone ID.
  zone_name_by_requested_service = {
    for service in var.services :
    service => lookup(local.zone_name_by_service, service, "UNKNOWN-SERVICE-${service}")
  }

  # One link per zone per VNet.
  links = merge([
    for zone_name in local.zone_names : {
      for link_name, vnet_id in var.virtual_network_ids :
      "${zone_name}/${link_name}" => {
        zone_name = zone_name
        link_name = link_name
        vnet_id   = vnet_id
      }
    }
  ]...)
}
