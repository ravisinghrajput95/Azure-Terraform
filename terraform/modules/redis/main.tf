################################################################################
# Azure Managed Redis
#
# Microsoft.Cache/redisEnterprise, NOT the classic azurerm_redis_cache.
#
# Classic Azure Cache for Redis is retiring and its API now rejects creation
# outright:
#
#   BadRequest: Azure Cache for Redis is retiring, create Azure Managed Redis
#   instance instead.
#
# So the classic Basic/Standard/Premium tiers and their C and P families are
# simply unavailable for new deployments. Managed Redis is the replacement, and
# for the smallest size it is slightly CHEAPER than the classic Basic tier it
# supersedes.
#
# Two defaults here are security decisions rather than tuning:
#
#   client_protocol = "Encrypted"
#       The plaintext protocol carries the access key and every cached value in
#       clear text.
#
#   access_keys_authentication_enabled = false
#       Access keys are static, non-expiring, unscopable and grant total
#       control. Clients authenticate with a managed identity through an access
#       policy assignment instead.
################################################################################

resource "azurerm_managed_redis" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = var.sku_name

  high_availability_enabled = var.high_availability_enabled

  # A string enum here, not a boolean — unlike almost every other Azure
  # resource in this platform.
  public_network_access = var.public_network_access_enabled ? "Enabled" : "Disabled"

  default_database {
    access_keys_authentication_enabled = var.access_keys_authentication_enabled
    client_protocol                    = var.client_protocol
    clustering_policy                  = var.clustering_policy
    eviction_policy                    = var.eviction_policy
    port                               = var.port
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !local.ha_cannot_be_disabled
      error_message = "high_availability_enabled is false but the SKU family is FlashOptimized, which always replicates and does not permit disabling HA."
    }

    precondition {
      condition = !local.no_usable_authentication
      error_message = join(" ", [
        "access_keys_authentication_enabled is false and no access_policy_assignments were supplied.",
        "With keys disabled, an Entra access policy assignment is the ONLY path to the data plane —",
        "the cache would be created successfully and nothing could connect to it."
      ])
    }

    precondition {
      condition     = !local.is_unreachable
      error_message = "public_network_access_enabled is false and create_private_endpoint is false. The cache would be created successfully and then be unreachable by every client."
    }

    precondition {
      condition = !local.private_endpoint_without_dns
      error_message = join(" ", [
        "A private endpoint is configured but private_dns_zone_ids is empty.",
        "The endpoint would register no A record, so the cache hostname resolves to its PUBLIC address from inside the VNet.",
        "Note that Managed Redis uses privatelink.redis.azure.net — a DIFFERENT zone from classic Azure Cache for Redis,",
        "which used privatelink.redis.cache.windows.net. Supplying the classic zone registers no usable record."
      ])
    }
  }
}

################################################################################
# Access policy assignments
#
# The Managed Redis equivalent of a data-plane role assignment. Required for
# every client once access keys are disabled.
#
# The resource takes only the cache and the principal — the policy itself is
# implicit. There is no per-assignment name or policy selector, so this grants
# the built-in full data access policy and nothing narrower is expressible.
################################################################################

resource "azurerm_managed_redis_access_policy_assignment" "this" {
  for_each = var.access_policy_assignments

  managed_redis_id = azurerm_managed_redis.this.id
  object_id        = each.value.principal_id
}

################################################################################
# Private endpoint
#
# subresource "redisEnterprise" — NOT "redisCache", which is the classic
# service's subresource name and is rejected here.
################################################################################

resource "azurerm_private_endpoint" "this" {
  count = local.has_private_endpoint ? 1 : 0

  name                = var.private_endpoint_name
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_managed_redis.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
      error_message = "create_private_endpoint is true but private_endpoint_subnet_id is null."
    }
  }
}
