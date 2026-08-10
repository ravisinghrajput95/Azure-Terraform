################################################################################
# SKU capability matrix
#
# Encoding this rather than documenting it means an unsupported combination
# fails the plan in a second, instead of failing an apply several minutes into
# provisioning a resource that takes ~10 minutes to create.
################################################################################

locals {
  is_developer = var.sku == "Developer"
  is_premium   = var.sku == "Premium"

  # Standard and Premium share the advanced feature set.
  supports_advanced_features = contains(["Standard", "Premium"], var.sku)

  # Developer is a shared regional instance attached by VNet ID. Every other
  # SKU deploys into AzureBastionSubnet with its own public IP.
  uses_dedicated_subnet = !local.is_developer

  # Basic is fixed at 2 instances; Developer is shared.
  supports_scale_units = local.supports_advanced_features

  supports_zones = local.supports_advanced_features
}

################################################################################
# Feature validation
################################################################################

locals {
  advanced_features_requested = compact([
    var.file_copy_enabled ? "file_copy_enabled" : "",
    var.tunneling_enabled ? "tunneling_enabled" : "",
    var.ip_connect_enabled ? "ip_connect_enabled" : "",
    var.shareable_link_enabled ? "shareable_link_enabled" : "",
  ])

  premium_features_requested = compact([
    var.session_recording_enabled ? "session_recording_enabled" : "",
  ])

  unsupported_advanced_features = local.supports_advanced_features ? [] : local.advanced_features_requested
  unsupported_premium_features  = local.is_premium ? [] : local.premium_features_requested

  # Developer does not support Kerberos either.
  unsupported_kerberos = local.is_developer && var.kerberos_enabled
}
