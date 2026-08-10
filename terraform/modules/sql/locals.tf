################################################################################
# Reachability
################################################################################

locals {
  has_private_endpoint = var.create_private_endpoint

  is_unreachable = !var.public_network_access_enabled && !local.has_private_endpoint

  private_endpoint_without_dns = local.has_private_endpoint && length(var.private_dns_zone_ids) == 0
}

################################################################################
# SKU characteristics
#
# The service objective encodes tier and compute model in its name:
#   GP_S_Gen5_1   General Purpose, Serverless, Gen5 hardware, 1 max vCore
#   GP_Gen5_2     General Purpose, provisioned
#   BC_Gen5_4     Business Critical, provisioned
#
# Several settings are only valid for one shape, and Azure rejects the wrong
# combination with an error that names the property rather than the SKU.
################################################################################

locals {
  is_serverless = startswith(var.sku_name, "GP_S_")

  # Zone redundancy requires Business Critical or Premium. General Purpose —
  # and serverless in particular — does not offer it.
  supports_zone_redundancy = startswith(var.sku_name, "BC_") || startswith(var.sku_name, "P")

  zone_redundancy_unsupported = var.zone_redundant && !local.supports_zone_redundancy

  # Serverless-only settings applied to a provisioned SKU are rejected.
  serverless_settings_on_provisioned = !local.is_serverless && var.auto_pause_delay_in_minutes != -1
}

################################################################################
# Backup coherence
#
# Geo-redundant backups require geo-redundant backup storage. Azure rejects the
# mismatch, but only after the database has begun provisioning.
################################################################################

locals {
  backup_storage_is_geo = contains(["Geo", "GeoZone"], var.storage_account_type)

  # geo_backup_enabled applies to DataWarehouse SKUs only. On any other tier
  # Azure ignores the value and continues to report true, so sending false
  # produces a permanent diff — the configuration never converges and every
  # subsequent plan carries noise that hides real changes.
  is_datawarehouse = startswith(var.sku_name, "DW")

  geo_backup_mismatch = local.is_datawarehouse && var.geo_backup_enabled && !local.backup_storage_is_geo
}

################################################################################
# Governance signal
#
# A single named user as Entra administrator is a governance weakness, not a
# technical fault: it ties database administration to one person's account,
# which breaks when they leave and cannot be reviewed as a role. Surfaced
# rather than blocked, because in a personal or trial subscription there may be
# no group to use.
################################################################################

locals {
  administrator_is_individual = !var.entra_administrator_is_group
}
