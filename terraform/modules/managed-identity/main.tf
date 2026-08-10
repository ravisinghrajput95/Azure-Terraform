################################################################################
# User-assigned managed identities
#
# One per compute tier, so the application tier cannot read the business
# tier's secrets. A single shared identity across tiers would make the NSG
# boundary between them decorative: network isolation without identity
# isolation means anything that reaches a tier inherits that tier's whole
# access footprint.
################################################################################

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.identities

  name                = each.value
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.unknown_identity_keys) == 0
      error_message = join(" ", [
        "role_assignments reference identity keys that do not exist:",
        "${join(", ", local.unknown_identity_keys)}.",
        "Available keys: ${join(", ", sort(keys(var.identities)))}."
      ])
    }
  }
}

################################################################################
# Entra ID propagation wait
#
# Azure role assignments and identity principals are eventually consistent, and
# Azure exposes no API to wait on. A principal created at second zero is
# frequently not yet resolvable when the next resource references it, producing
# PrincipalNotFound — intermittently, so it reads as a flaky apply rather than
# a consistency window.
#
# This is a timer, not a fix. It cannot guarantee readiness, only make the
# common case work. The correct engineering position is to prefer mechanisms
# that avoid the lookup entirely (see principal_type below) and to use this
# only for data-plane consumers where no such mechanism exists.
################################################################################

resource "time_sleep" "propagation" {
  count = local.wait_enabled ? 1 : 0

  create_duration = "${var.propagation_delay_seconds}s"

  # Re-wait if the set of identities changes, since a new principal has the
  # same propagation problem as the first one.
  triggers = {
    principal_ids = join(",", sort([
      for identity in azurerm_user_assigned_identity.this : identity.principal_id
    ]))
  }

  depends_on = [azurerm_user_assigned_identity.this]
}

################################################################################
# Role assignments
#
# principal_type is set explicitly to "ServicePrincipal". This is the important
# detail: without it, Azure looks the principal up in Entra ID to determine its
# type, and that lookup is exactly what fails for a principal created moments
# earlier. Declaring the type skips the lookup, so these assignments do not
# depend on propagation at all.
#
# skip_service_principal_aad_check is the older workaround for the same
# problem. principal_type supersedes it and is preferred — it states a fact
# rather than disabling a check.
################################################################################

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  principal_id   = azurerm_user_assigned_identity.this[each.value.identity_key].principal_id
  principal_type = "ServicePrincipal"

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  role_definition_id   = each.value.role_definition_id

  description = each.value.description

  condition         = each.value.condition
  condition_version = each.value.condition_version
}
