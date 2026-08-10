################################################################################
# Public IP
#
# Created for Basic and above only. The Developer SKU is a shared regional
# instance with no dedicated public endpoint.
#
# Standard SKU, Static allocation — Bastion accepts nothing else, and the Basic
# SKU public IP was retired by Azure in September 2025 in any case.
################################################################################

resource "azurerm_public_ip" "this" {
  count = local.uses_dedicated_subnet ? 1 : 0

  name                = var.public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location

  allocation_method = "Static"
  sku               = "Standard"
  zones             = local.supports_zones ? var.zones : []

  tags = var.tags
}

################################################################################
# Bastion host
#
# Operator access to instances that have no public IP and accept SSH from
# nowhere except the Bastion subnet. This is the module that makes the
# "no public compute" position workable rather than merely stated.
################################################################################

resource "azurerm_bastion_host" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # Developer attaches by VNet ID and consumes no subnet. Every other SKU takes
  # an ip_configuration pointing at AzureBastionSubnet.
  virtual_network_id = local.is_developer ? var.virtual_network_id : null

  dynamic "ip_configuration" {
    for_each = local.uses_dedicated_subnet ? [1] : []

    content {
      name                 = "configuration"
      subnet_id            = var.subnet_id
      public_ip_address_id = azurerm_public_ip.this[0].id
    }
  }

  scale_units = local.supports_scale_units ? var.scale_units : null
  zones       = local.supports_zones ? var.zones : []

  copy_paste_enabled = var.copy_paste_enabled
  kerberos_enabled   = local.is_developer ? null : var.kerberos_enabled

  file_copy_enabled      = local.supports_advanced_features ? var.file_copy_enabled : null
  tunneling_enabled      = local.supports_advanced_features ? var.tunneling_enabled : null
  ip_connect_enabled     = local.supports_advanced_features ? var.ip_connect_enabled : null
  shareable_link_enabled = local.supports_advanced_features ? var.shareable_link_enabled : null

  session_recording_enabled = local.is_premium ? var.session_recording_enabled : null

  tags = var.tags

  lifecycle {
    ############################################################################
    # Network placement must match the SKU. Azure rejects a mismatch only after
    # several minutes of provisioning.
    ############################################################################
    precondition {
      condition     = !local.is_developer || (var.virtual_network_id != null && var.subnet_id == null)
      error_message = "The Developer SKU attaches by virtual_network_id and does not use AzureBastionSubnet. Set virtual_network_id and leave subnet_id null."
    }

    precondition {
      condition     = local.is_developer || (var.subnet_id != null && var.virtual_network_id == null)
      error_message = "The ${var.sku} SKU deploys into AzureBastionSubnet. Set subnet_id and leave virtual_network_id null."
    }

    precondition {
      condition     = !local.uses_dedicated_subnet || var.public_ip_name != null
      error_message = "The ${var.sku} SKU requires a public IP; set public_ip_name."
    }

    ############################################################################
    # Features must be supported by the SKU.
    ############################################################################
    precondition {
      condition = length(local.unsupported_advanced_features) == 0
      error_message = join(" ", [
        "These features require the Standard or Premium SKU but the SKU is ${var.sku}:",
        "${join(", ", local.unsupported_advanced_features)}.",
        "Native client tunneling in particular is the usual reason to move off Developer or Basic."
      ])
    }

    precondition {
      condition = length(local.unsupported_premium_features) == 0
      error_message = join(" ", [
        "These features require the Premium SKU but the SKU is ${var.sku}:",
        "${join(", ", local.unsupported_premium_features)}."
      ])
    }

    precondition {
      condition     = !local.unsupported_kerberos
      error_message = "kerberos_enabled is not supported on the Developer SKU."
    }

    ############################################################################
    # Session recording exists to produce an audit trail. Shareable links grant
    # session access to principals with no Azure RBAC on the target, so the
    # recording cannot be attributed to an identity. Azure rejects the pairing;
    # this explains why.
    ############################################################################
    precondition {
      condition     = !(var.session_recording_enabled && var.shareable_link_enabled)
      error_message = "session_recording_enabled cannot be combined with shareable_link_enabled: a shareable link grants access without Azure RBAC, so recorded sessions could not be attributed to an identity."
    }

    precondition {
      condition     = length(var.zones) == 0 || local.supports_zones
      error_message = "Availability zones require the Standard or Premium SKU; the SKU is ${var.sku}."
    }
  }
}
