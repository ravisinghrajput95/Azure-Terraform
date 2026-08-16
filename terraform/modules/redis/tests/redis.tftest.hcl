################################################################################
# Unit tests for the redis module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# This module is Azure MANAGED Redis (Microsoft.Cache/redisEnterprise), not
# Azure Cache for Redis. The distinction is not cosmetic — it listens on 10000
# rather than 6380, and the private-endpoint NSG once allowed the wrong one,
# which would have sent every pod-to-cache call into a deny with the cache
# reporting healthy.
#
# The preconditions here all guard the same shape of failure: Azure creates the
# cache successfully and something about it does not work. A cache nobody can
# reach, a cache nobody can authenticate to, and a private endpoint that
# resolves nowhere all provision cleanly.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "redis-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-data"
  location            = "centralus"
  tags                = { environment = "test" }

  sku_name = "Balanced_B1"

  # Keys are off and Entra ID is the only way in, which is the intended
  # posture and also the one that needs an assignment to be usable at all.
  access_keys_authentication_enabled = false
  access_policy_assignments = {
    app = { principal_id = "00000000-0000-0000-0000-000000000001" }
  }

  public_network_access_enabled = false
  create_private_endpoint       = true
  private_endpoint_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pep"
  private_dns_zone_ids          = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net"]

  # Required once create_private_endpoint is true; it has no default, so a
  # caller enabling the endpoint without it fails on the resource rather than
  # on a precondition.
  private_endpoint_name = "pep-redis-cloudcart-test-cus-001"
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_cache" {
  command = plan

  assert {
    condition     = output.access_keys_enabled == false
    error_message = "Access keys must stay disabled in the baseline configuration."
  }

  assert {
    condition     = strcontains(output.reachable_from, "Private endpoint from inside the VNet.")
    error_message = "A private-endpoint cache must say so in its posture output."
  }

  assert {
    condition     = strcontains(output.reachable_from, "No public endpoint.")
    error_message = "With public access off, the posture output must state it."
  }
}

################################################################################
# Reachability
#
# The headline case. Azure accepts a cache with no public endpoint and no
# private endpoint, creates it, reports it healthy, and no client anywhere can
# open a connection to it.
################################################################################

run "rejects_a_cache_nothing_can_reach" {
  command = plan

  variables {
    public_network_access_enabled = false
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  expect_failures = [azurerm_managed_redis.this]
}

run "accepts_a_public_cache_with_no_private_endpoint" {
  command = plan

  # Reachable, so the precondition must not fire. It is a worse posture, and
  # the module reports that in an output rather than refusing it — Managed
  # Redis has no IP allowlist, so this really is open to the internet.
  variables {
    public_network_access_enabled = true
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  assert {
    condition     = strcontains(output.reachable_from, "open to the internet")
    error_message = "A public Managed Redis has no IP allowlist and the output must say so plainly."
  }
}

################################################################################
# Authentication
#
# With access keys disabled and no access policy assignment, there is no
# principal that can authenticate. The cache is created and every connection
# is refused.
################################################################################

run "rejects_a_cache_no_principal_can_authenticate_to" {
  command = plan

  variables {
    access_keys_authentication_enabled = false
    access_policy_assignments          = {}
  }

  expect_failures = [azurerm_managed_redis.this]
}

run "accepts_keys_as_the_only_authentication" {
  command = plan

  # Usable, therefore not refused — but the posture output has to warn, because
  # a static key is unscopable, non-expiring and attributable to nobody.
  variables {
    access_keys_authentication_enabled = true
    access_policy_assignments          = {}
  }

  assert {
    condition     = strcontains(output.reachable_from, "WARNING: access keys are ENABLED.")
    error_message = "Enabling static access keys must be reported as a warning."
  }
}

################################################################################
# Private endpoint and DNS
#
# A private endpoint with no private DNS zone gets an IP that nothing resolves
# to. Clients keep resolving the public name, which the firewall then refuses —
# a failure that reads as a network problem rather than a missing zone link.
################################################################################

run "rejects_a_private_endpoint_with_no_dns_zone" {
  command = plan

  variables {
    create_private_endpoint = true
    private_dns_zone_ids    = []
  }

  expect_failures = [azurerm_managed_redis.this]
}

run "rejects_a_private_endpoint_with_no_subnet" {
  command = plan

  variables {
    create_private_endpoint    = true
    private_endpoint_subnet_id = null
  }

  expect_failures = [azurerm_private_endpoint.this]
}

################################################################################
# High availability
#
# FlashOptimized always replicates. Asking for it without HA is rejected by
# Azure, and the error names the SKU rather than the setting.
################################################################################

run "rejects_flash_optimized_without_high_availability" {
  command = plan

  variables {
    sku_name                  = "FlashOptimized_A250"
    high_availability_enabled = false
  }

  expect_failures = [azurerm_managed_redis.this]
}

run "accepts_a_balanced_sku_without_high_availability" {
  command = plan

  # Permitted, and the degraded posture is stated rather than refused: dev runs
  # a single node deliberately.
  variables {
    sku_name                  = "Balanced_B0"
    high_availability_enabled = false
  }

  assert {
    condition     = strcontains(output.availability_summary, "NO SLA")
    error_message = "A single-node cache must state that it carries no SLA."
  }

  assert {
    condition     = output.high_availability_enabled == false
    error_message = "The HA flag must be reported as configured."
  }
}

run "reports_high_availability_when_enabled" {
  command = plan

  variables {
    sku_name                  = "Balanced_B1"
    high_availability_enabled = true
  }

  assert {
    condition     = strcontains(output.availability_summary, "SLA applies")
    error_message = "A replicated cache must state that the SLA applies."
  }
}
