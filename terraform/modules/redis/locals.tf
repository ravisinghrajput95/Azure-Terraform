################################################################################
# Family characteristics
################################################################################

locals {
  sku_family = split("_", var.sku_name)[0]
  sku_size   = split("_", var.sku_name)[1]

  is_flash_optimized = local.sku_family == "FlashOptimized"

  # FlashOptimized always replicates; high availability cannot be disabled on
  # it, and Azure rejects the attempt.
  ha_cannot_be_disabled = local.is_flash_optimized && !var.high_availability_enabled
}

################################################################################
# Authentication coherence
#
# With access keys disabled, an Entra access policy assignment is the ONLY way
# to reach the data plane. A cache with keys off and no assignments is created
# successfully and cannot be connected to by anything.
################################################################################

locals {
  has_access_policy_assignments = length(var.access_policy_assignments) > 0

  no_usable_authentication = !var.access_keys_authentication_enabled && !local.has_access_policy_assignments
}

################################################################################
# Reachability
################################################################################

locals {
  has_private_endpoint = var.create_private_endpoint

  is_unreachable = !var.public_network_access_enabled && !local.has_private_endpoint

  private_endpoint_without_dns = local.has_private_endpoint && length(var.private_dns_zone_ids) == 0
}
