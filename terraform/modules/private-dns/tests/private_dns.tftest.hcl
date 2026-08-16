################################################################################
# Unit tests for the private-dns module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# A private endpoint with no zone, or with the WRONG zone, is the quietest
# failure in this platform. The endpoint is created and gets a private IP;
# clients keep resolving the public name and are refused at the data plane. It
# reads as a firewall problem, and the thing to fix is a DNS zone.
#
# The zone names themselves are the trap. privatelink.redis.azure.net is Azure
# MANAGED Redis; privatelink.redis.cache.windows.net is Azure Cache for Redis.
# Both are real, neither errors, and only one resolves the cache this platform
# runs.
################################################################################

mock_provider "azurerm" {}

variables {
  resource_group_name = "rg-cloudcart-test-cus-net"
  tags                = { environment = "test" }

  services = ["sql", "blob", "keyvault", "managed_redis"]
  virtual_network_ids = {
    vnet = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_zone_set" {
  command = plan

  assert {
    condition     = length(output.zone_names) == 4
    error_message = "One zone per requested service."
  }

  assert {
    condition     = output.zone_names_by_service["managed_redis"] == "privatelink.redis.azure.net"
    error_message = "managed_redis must map to the Managed Redis zone, NOT privatelink.redis.cache.windows.net, which is Azure Cache for Redis and resolves nothing this platform runs."
  }

  assert {
    condition     = output.zone_names_by_service["sql"] == "privatelink.database.windows.net"
    error_message = "sql must map to the SQL privatelink zone."
  }

  assert {
    condition     = output.link_count == 4
    error_message = "Every zone must be linked to the VNet — an unlinked zone resolves for nobody."
  }
}

################################################################################
# Unknown service keys
#
# A typo'd service key would otherwise produce a zone literally named
# UNKNOWN-SERVICE-<key>, which Azure accepts as a private DNS zone name and
# which resolves for nothing.
################################################################################

run "rejects_an_unknown_service_key" {
  command = plan

  variables {
    services = ["sql", "blobb"]
  }

  expect_failures = [azurerm_private_dns_zone.this]
}

################################################################################
# Region-scoped zones
#
# Some zone names embed the region. Without location_hint the zone name carries
# a literal placeholder, so it is created and resolves for nothing.
################################################################################

run "rejects_a_region_scoped_service_with_no_location_hint" {
  command = plan

  variables {
    services      = ["sql_mi"]
    location_hint = null
  }

  expect_failures = [azurerm_private_dns_zone.this]
}

run "accepts_a_region_scoped_service_with_a_location_hint" {
  command = plan

  variables {
    services      = ["sql_mi"]
    location_hint = "centralus"
  }

  assert {
    condition     = output.zone_names_by_service["sql_mi"] == "privatelink.centralus.database.windows.net"
    error_message = "A region-scoped zone must embed the supplied region."
  }
}

run "accepts_services_that_are_not_region_scoped_with_no_hint" {
  command = plan

  # Only sql_mi, aks and backup embed a region. Requiring the hint for every
  # service would reject the ordinary case.
  variables {
    services      = ["sql", "blob"]
    location_hint = null
  }

  assert {
    condition     = length(output.zone_names) == 2
    error_message = "Non-region-scoped services must not require a location hint."
  }
}

################################################################################
# Auto-registration
#
# Registration is a property of the zone-to-VNet LINK, and a VNet can have
# auto-registration enabled on at most one zone. Enabling it across several
# links is accepted per link and then conflicts.
################################################################################

run "rejects_registration_across_multiple_zones" {
  command = plan

  variables {
    services             = ["sql", "blob"]
    registration_enabled = true
  }

  expect_failures = [azurerm_private_dns_zone_virtual_network_link.this]
}

run "accepts_registration_on_a_single_zone" {
  command = plan

  variables {
    services             = ["sql"]
    registration_enabled = true
  }

  assert {
    condition     = output.registration_enabled == true
    error_message = "Registration must be reported as configured when it is permitted."
  }
}

################################################################################
# Shared zone names
#
# Several service keys map to the same zone deliberately — eventhub and
# servicebus share privatelink.servicebus.windows.net. Creating that zone twice
# would fail, so the zone set is deduplicated while the per-service lookup
# still answers for both.
################################################################################

run "deduplicates_services_that_share_one_zone" {
  command = plan

  variables {
    services = ["eventhub", "servicebus"]
  }

  assert {
    condition     = length(output.zone_names) == 1
    error_message = "Two services sharing a zone name must produce ONE zone, not a duplicate-name failure."
  }

  assert {
    condition     = output.zone_names_by_service["eventhub"] == output.zone_names_by_service["servicebus"]
    error_message = "Both service keys must resolve to the same shared zone."
  }
}

################################################################################
# Additional zones
################################################################################

run "accepts_additional_zones_alongside_services" {
  command = plan

  variables {
    services         = ["sql"]
    additional_zones = ["privatelink.example.internal"]
  }

  assert {
    condition     = length(output.zone_names) == 2
    error_message = "A caller-supplied zone must be created alongside the service-derived ones."
  }
}
