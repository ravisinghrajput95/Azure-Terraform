################################################################################
# Storage account
#
# The defaults here are the security posture, not decoration:
#
#   shared_access_key_enabled = false
#       Account keys are the most frequently leaked Azure credential. Static,
#       non-expiring, unscopable, and they grant total control of the account.
#       Disabling them forces every consumer onto Entra ID.
#
#   allow_nested_items_to_be_public = false
#       Forecloses anonymous public blob access ACCOUNT-WIDE, regardless of any
#       per-container setting. One switch that removes the most common storage
#       data-exposure incident.
#
#   cross_tenant_replication_enabled = false
#       Object replication to another tenant is an exfiltration path requiring
#       no network access at all.
################################################################################

resource "azurerm_storage_account" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = var.account_tier
  account_replication_type = var.account_replication_type
  account_kind             = var.account_kind
  access_tier              = var.access_tier

  shared_access_key_enabled       = var.shared_access_key_enabled
  default_to_oauth_authentication = var.default_to_oauth_authentication
  local_user_enabled              = var.local_user_enabled

  min_tls_version                   = var.min_tls_version
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = var.allow_nested_items_to_be_public
  cross_tenant_replication_enabled  = var.cross_tenant_replication_enabled
  infrastructure_encryption_enabled = var.infrastructure_encryption_enabled

  public_network_access_enabled = var.public_network_access_enabled

  blob_properties {
    versioning_enabled  = var.blob_versioning_enabled
    change_feed_enabled = var.blob_change_feed_enabled

    dynamic "delete_retention_policy" {
      for_each = var.blob_delete_retention_days > 0 ? [1] : []
      content {
        days = var.blob_delete_retention_days
      }
    }

    dynamic "container_delete_retention_policy" {
      for_each = var.container_delete_retention_days > 0 ? [1] : []
      content {
        days = var.container_delete_retention_days
      }
    }
  }

  dynamic "network_rules" {
    for_each = local.emit_network_rules ? [1] : []

    content {
      default_action             = var.network_rules_default_action
      bypass                     = var.network_rules_bypass
      ip_rules                   = var.allowed_ip_rules
      virtual_network_subnet_ids = var.allowed_subnet_ids
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.is_unreachable
      error_message = join(" ", [
        "public_network_access_enabled is false and no private endpoints are configured.",
        "The account would be created successfully and then be unreachable for data operations by everything, including Terraform.",
        "The control plane is not subject to network rules, so the apply SUCCEEDS and the failure appears on first data access."
      ])
    }

    precondition {
      condition = !local.rules_are_permissive
      error_message = join(" ", [
        "network_rules_default_action is \"Allow\" while IP or subnet rules are configured.",
        "This reads as an allowlist and is not one: Allow permits every source not explicitly denied, so the rules have no effect."
      ])
    }

    precondition {
      condition = length(local.subresources_missing_dns) == 0
      error_message = join(" ", [
        "Private endpoints requested for sub-resources with no DNS zone:",
        "${join(", ", local.subresources_missing_dns)}.",
        "Each sub-resource needs its OWN privatelink zone — a blob endpoint does not make file resolve.",
        "Without the zone the endpoint registers no A record and the account resolves to its PUBLIC address from inside the VNet."
      ])
    }

    precondition {
      condition = !local.containers_without_data_plane_grant
      error_message = join(" ", [
        "Containers are requested and shared_access_key_enabled is false, but no data-plane role is granted in role_assignments.",
        "Container creation authenticates as the caller's Entra principal, and CONTROL-PLANE roles do not confer data access —",
        "a subscription Owner with no data role receives 403 on a container list.",
        "Grant the deploying principal one of: ${join(", ", local.data_plane_roles)}."
      ])
    }
  }
}

################################################################################
# Role assignments
#
# Scoped to this account, so grants die with it rather than outliving it.
#
# With shared keys disabled these are the ONLY path to the data. Note that
# Owner and Contributor are control-plane roles: they permit deleting the
# account but not reading a blob in it.
################################################################################

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = azurerm_storage_account.this.id
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
  role_definition_name = each.value.role_definition_name
  description          = each.value.description
}

################################################################################
# RBAC propagation wait
#
# Entra ID role assignments are eventually consistent. A data-plane grant made
# at second zero is frequently not effective when the next call uses it, and
# the resulting 403 is indistinguishable from a genuinely missing permission.
#
# A timer, not a fix — see modules/managed-identity/README.md.
################################################################################

resource "time_sleep" "rbac_propagation" {
  count = local.wait_for_rbac ? 1 : 0

  create_duration = "${var.rbac_propagation_delay_seconds}s"

  triggers = {
    role_assignments = join(",", sort([
      for assignment in azurerm_role_assignment.this : assignment.id
    ]))
  }

  depends_on = [azurerm_role_assignment.this]
}

################################################################################
# Containers
#
# storage_account_id, not storage_account_name — the name form is deprecated in
# azurerm 4.x.
#
# Container creation is a DATA-plane operation. With shared keys disabled it
# requires the provider's storage_use_azuread flag and a data-plane role on the
# caller.
################################################################################

resource "azurerm_storage_container" "this" {
  for_each = var.containers

  name                  = each.key
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = each.value.access_type
  metadata              = each.value.metadata

  depends_on = [
    azurerm_role_assignment.this,
    time_sleep.rbac_propagation,
  ]
}

################################################################################
# Private endpoints
#
# One per sub-resource. blob, file, queue, table and dfs are distinct endpoints
# with distinct DNS zones.
################################################################################

resource "azurerm_private_endpoint" "this" {
  for_each = local.private_endpoints

  name                = each.value.name
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}-${each.value.subresource}"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = each.value.zone_ids
  }

  tags = var.tags
}
