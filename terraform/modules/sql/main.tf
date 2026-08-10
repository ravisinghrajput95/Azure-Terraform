################################################################################
# Logical server
#
# Note what is ABSENT: administrator_login and administrator_login_password are
# never set, and this module does not accept them.
#
# With azuread_authentication_only = true, SQL authentication is disabled. No
# password is generated, so none is written to Terraform state in plaintext,
# none is stored in Key Vault, none is rotated, and none can leak. That is
# strictly stronger than "no hardcoded secrets" — the secret does not exist.
#
# Azure does still record a placeholder administratorLogin value on the server
# (something like CloudSAxxxxxxxx). It is an artefact of the API, not a usable
# credential: with SQL auth disabled it cannot authenticate, and no password
# was ever set for it.
#
# The provider does offer administrator_login_password_wo, a write-only
# argument that keeps a password out of state. That is the right answer IF a
# SQL login is unavoidable. Having no login at all is better still.
################################################################################

resource "azurerm_mssql_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.server_version

  minimum_tls_version                  = var.minimum_tls_version
  public_network_access_enabled        = var.public_network_access_enabled
  outbound_network_restriction_enabled = var.outbound_network_restriction_enabled
  connection_policy                    = var.connection_policy

  azuread_administrator {
    login_username              = var.entra_administrator_login
    object_id                   = var.entra_administrator_object_id
    azuread_authentication_only = var.azuread_authentication_only
  }

  # A system-assigned identity lets the server authenticate outbound — required
  # for customer-managed TDE keys and for auditing to a storage account with
  # shared keys disabled.
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.is_unreachable
      error_message = join(" ", [
        "public_network_access_enabled is false and no private_endpoint_subnet_id was supplied.",
        "The server would be created successfully and then be unreachable by every client, including schema migrations.",
        "Supply a private endpoint subnet, or leave the public endpoint enabled behind firewall rules."
      ])
    }

    precondition {
      condition = !local.private_endpoint_without_dns
      error_message = join(" ", [
        "A private endpoint is configured but private_dns_zone_ids is empty.",
        "The endpoint would register no A record, so the server FQDN resolves to its PUBLIC address from inside the VNet —",
        "failing outright when public access is disabled, and silently bypassing the private path when it is not.",
        "Pass the private-dns module's zone_ids_by_service[\"sql\"]."
      ])
    }
  }
}

################################################################################
# Firewall rules
#
# Only reachable when the public endpoint is enabled. Deliberately no
# "AllowAllWindowsAzureIps" rule: that entry (0.0.0.0-0.0.0.0) permits every
# Azure resource in EVERY tenant, including other customers'. It is one of the
# most common Azure SQL exposures and the variable validation rejects it.
################################################################################

resource "azurerm_mssql_firewall_rule" "this" {
  for_each = var.public_network_access_enabled ? var.allowed_ip_rules : {}

  name             = each.key
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = each.value.start_ip
  end_ip_address   = each.value.end_ip
}

################################################################################
# Database
################################################################################

resource "azurerm_mssql_database" "this" {
  name      = var.database_name
  server_id = azurerm_mssql_server.this.id

  sku_name     = var.sku_name
  max_size_gb  = var.max_size_gb
  collation    = var.collation
  license_type = null

  zone_redundant       = var.zone_redundant
  storage_account_type = var.storage_account_type

  # Sent only for DataWarehouse SKUs. Every other tier ignores the value and
  # keeps reporting true, so sending false would produce a diff on every plan
  # forever. Real backup redundancy comes from storage_account_type above,
  # which Azure does honour — verified as currentBackupStorageRedundancy.
  geo_backup_enabled = local.is_datawarehouse ? var.geo_backup_enabled : null

  # Serverless only. On a provisioned SKU these are rejected, which the
  # precondition below catches first.
  auto_pause_delay_in_minutes = local.is_serverless ? var.auto_pause_delay_in_minutes : null
  min_capacity                = local.is_serverless ? var.min_capacity : null

  # On by default in Azure, set explicitly so it is visible in configuration
  # rather than inherited.
  transparent_data_encryption_enabled = true

  short_term_retention_policy {
    retention_days = var.short_term_retention_days
  }

  dynamic "long_term_retention_policy" {
    for_each = var.long_term_retention_enabled ? [var.long_term_retention] : []

    content {
      weekly_retention  = long_term_retention_policy.value.weekly
      monthly_retention = long_term_retention_policy.value.monthly
      yearly_retention  = long_term_retention_policy.value.yearly
      week_of_year      = long_term_retention_policy.value.week_of_year
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.zone_redundancy_unsupported
      error_message = join(" ", [
        "zone_redundant is true but sku_name is \"${var.sku_name}\".",
        "Zone redundancy requires a Business Critical (BC_) or Premium (P) tier;",
        "General Purpose, and serverless in particular, does not offer it.",
        "Azure rejects this combination with an error naming the property rather than the SKU."
      ])
    }

    precondition {
      condition = !local.geo_backup_mismatch
      error_message = join(" ", [
        "geo_backup_enabled is true but storage_account_type is \"${var.storage_account_type}\".",
        "Geo-redundant backups require geo-redundant backup storage.",
        "Set storage_account_type to \"Geo\" or \"GeoZone\", or disable geo_backup_enabled."
      ])
    }
  }
}

################################################################################
# Private endpoint
#
# subresource "sqlServer" covers the database engine. Paired with the
# privatelink.database.windows.net zone so the server's own FQDN resolves to
# this endpoint from inside the VNet — connection strings need no change.
################################################################################

resource "azurerm_private_endpoint" "this" {
  count = local.has_private_endpoint ? 1 : 0

  name                = var.private_endpoint_name
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.server_name}"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }

  tags = var.tags
}
