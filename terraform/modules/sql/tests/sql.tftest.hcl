################################################################################
# Unit tests for the sql module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# Azure SQL provisioning is REGION- and SUBSCRIPTION-restricted in ways no API
# reports (ARCHITECTURE.md §6a), so none of this can be proven by an apply on
# this subscription. These tests are the only thing exercising the module's
# coherence logic at all.
################################################################################

mock_provider "azurerm" {}

variables {
  server_name         = "sql-cloudcart-test-cus-001"
  database_name       = "sqldb-cloudcart-test-cus"
  resource_group_name = "rg-cloudcart-test-cus-data"
  location            = "centralus"
  tags                = { environment = "test" }

  # There is no SQL login anywhere in this platform, so there is no password to
  # rotate, store, or leak into state.
  entra_administrator_login     = "sql-admins"
  entra_administrator_object_id = "00000000-0000-0000-0000-000000000001"
  entra_administrator_is_group  = true
  azuread_authentication_only   = true

  public_network_access_enabled = false
  create_private_endpoint       = true
  private_endpoint_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pep"
  private_endpoint_name         = "pep-sql-cloudcart-test-cus-001"
  private_dns_zone_ids          = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"]
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_server" {
  command = plan

  assert {
    condition     = output.azuread_authentication_only == true
    error_message = "Entra-only authentication is the intended posture and must be reported."
  }

  assert {
    condition     = strcontains(output.reachable_from, "no password was ever set")
    error_message = "With SQL authentication disabled the output must say there is no password at all."
  }

  assert {
    condition     = output.administrator_is_individual == false
    error_message = "A group administrator must not report as an individual."
  }
}

run "reports_an_individual_administrator" {
  command = plan

  # A person as SQL administrator is a governance weakness: it cannot be
  # granted to a second operator and it disappears with the leaver. Reported,
  # not refused — this tenant contains zero Entra groups, so it is sometimes
  # the only option available.
  variables {
    entra_administrator_is_group = false
  }

  assert {
    condition     = output.administrator_is_individual == true
    error_message = "An individual administrator must be reported as such."
  }
}

################################################################################
# Reachability
################################################################################

run "rejects_a_server_nothing_can_reach" {
  command = plan

  variables {
    public_network_access_enabled = false
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  expect_failures = [azurerm_mssql_server.this]
}

run "rejects_a_private_endpoint_with_no_dns_zone" {
  command = plan

  variables {
    create_private_endpoint = true
    private_dns_zone_ids    = []
  }

  expect_failures = [azurerm_mssql_server.this]
}

run "accepts_a_public_server_with_firewall_rules" {
  command = plan

  variables {
    public_network_access_enabled = true
    allowed_ip_rules              = { operator = { start_ip = "203.0.113.4", end_ip = "203.0.113.4" } }
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  assert {
    condition     = strcontains(output.reachable_from, "1 firewall rule(s)")
    error_message = "A public server must report how many firewall rules actually exist."
  }
}

################################################################################
# Zone redundancy is a tier, not a flag
#
# Azure rejects zone_redundant on a SKU that does not offer it, and serverless
# in particular does not. The error names the database rather than the tier.
################################################################################

run "rejects_zone_redundancy_on_a_serverless_sku" {
  command = plan

  variables {
    sku_name       = "GP_S_Gen5_1"
    zone_redundant = true
  }

  expect_failures = [azurerm_mssql_database.this]
}

run "accepts_zone_redundancy_on_business_critical" {
  command = plan

  variables {
    sku_name       = "BC_Gen5_2"
    zone_redundant = true
  }

  assert {
    condition     = output.is_serverless == false
    error_message = "A Business Critical SKU is provisioned, not serverless."
  }
}

run "reports_serverless_auto_pause" {
  command = plan

  # Paused databases bill for storage only, which is what makes serverless
  # near-free in an environment used a few hours a day. The cost is a cold
  # start of several seconds on the first connection.
  variables {
    sku_name                    = "GP_S_Gen5_1"
    auto_pause_delay_in_minutes = 60
  }

  assert {
    condition     = output.is_serverless == true
    error_message = "A GP_S_ SKU is serverless and must be reported as such."
  }

  assert {
    condition     = output.auto_pause_delay_in_minutes == 60
    error_message = "The auto-pause delay must be reported as configured."
  }
}

################################################################################
# Geo-redundant backup needs geo-redundant backup storage
#
# Asking for a geo backup while the backup storage is Local retains nothing
# off-region, and the setting that has to change is the one not named in the
# request.
################################################################################

run "rejects_a_geo_backup_with_local_backup_storage" {
  command = plan

  variables {
    sku_name             = "DW100c"
    geo_backup_enabled   = true
    storage_account_type = "Local"
  }

  expect_failures = [azurerm_mssql_database.this]
}

run "accepts_a_geo_backup_with_geo_backup_storage" {
  command = plan

  variables {
    sku_name             = "DW100c"
    geo_backup_enabled   = true
    storage_account_type = "Geo"
  }

  assert {
    condition     = output.database_name == "sqldb-cloudcart-test-cus"
    error_message = "A coherent geo-backup configuration must be accepted."
  }
}
