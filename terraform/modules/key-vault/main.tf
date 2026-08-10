################################################################################
# Key Vault
#
# RBAC authorization, always. The legacy access policy model is not exposed by
# this module at all:
#
#   - Access policies do not compose with Azure RBAC. A vault using them
#     ignores role assignments entirely, so a principal with "Key Vault
#     Administrator" still cannot read a secret.
#   - Policy grants are invisible to `az role assignment list` and to standard
#     access reviews, so they accumulate unnoticed.
#   - They are per-vault, so the same grant must be repeated everywhere rather
#     than assigned once at a resource group scope.
#
# Note the argument is rbac_authorization_enabled. The older
# enable_rbac_authorization is deprecated in azurerm 4.x.
################################################################################

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  rbac_authorization_enabled = true

  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  enabled_for_deployment          = var.enabled_for_deployment
  enabled_for_disk_encryption     = var.enabled_for_disk_encryption
  enabled_for_template_deployment = var.enabled_for_template_deployment

  dynamic "network_acls" {
    for_each = local.emit_network_acls ? [1] : []

    content {
      default_action             = var.network_acls_default_action
      bypass                     = var.network_acls_bypass
      ip_rules                   = var.allowed_ip_rules
      virtual_network_subnet_ids = var.allowed_subnet_ids
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.is_unreachable
      error_message = join(" ", [
        "public_network_access_enabled is false and no private_endpoint_subnet_id was supplied.",
        "The vault would be created successfully and then be unreachable by everything, including Terraform —",
        "the control plane still works, so the apply SUCCEEDS and the failure appears only when a secret is first read.",
        "Supply a private endpoint subnet, or leave the public endpoint enabled behind an IP allowlist."
      ])
    }

    precondition {
      condition = !local.acls_are_permissive
      error_message = join(" ", [
        "network_acls_default_action is \"Allow\" while IP or subnet rules are configured.",
        "This reads as an allowlist and is not one: default Allow permits every source that is not explicitly denied,",
        "so the rules have no effect. Use \"Deny\" as the default action."
      ])
    }

    precondition {
      condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
      error_message = "create_private_endpoint is true but private_endpoint_subnet_id is null."
    }

    precondition {
      condition = !local.private_endpoint_without_dns
      error_message = join(" ", [
        "A private endpoint is configured but private_dns_zone_ids is empty.",
        "The endpoint would be created with no A record, so the vault hostname resolves to its PUBLIC address from inside the VNet —",
        "which fails outright when public access is disabled, and silently bypasses the private path when it is not.",
        "Pass the private-dns module's zone_ids_by_service[\"keyvault\"]."
      ])
    }
  }
}

################################################################################
# Private endpoint
#
# The in-VNet path to the vault's data plane. Paired with the private DNS zone
# so the vault's own hostname resolves to this endpoint's private address —
# applications use the standard vault URI and reach it privately, with no
# code change.
################################################################################

resource "azurerm_private_endpoint" "this" {
  count = local.has_private_endpoint ? 1 : 0

  name                = var.private_endpoint_name
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }

  tags = var.tags
}

################################################################################
# Role assignments
#
# Scoped to this vault, so a grant dies with the vault rather than outliving it
# as an orphaned assignment against a deleted scope.
#
# principal_type is declared rather than looked up. Azure otherwise queries
# Entra ID to determine the type, and that query is exactly what fails for a
# principal created moments earlier in the same apply.
################################################################################

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = azurerm_key_vault.this.id
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
  role_definition_name = each.value.role_definition_name
  description          = each.value.description
}
