################################################################################
# Phase 0 — Terraform state backend
#
# The backend cannot live in the state it stores. This configuration therefore
# runs on LOCAL state and creates the remote backend everything else uses.
#
# That is a deliberate circular-dependency break, not an oversight:
#
#   - It is small, and changes almost never.
#   - Making it self-hosting means the account holding the state is described
#     by state inside itself. Losing it loses the ability to describe it.
#   - Local state here is acceptable precisely because these resources are
#     re-derivable: the account name is an input, and the containers are empty
#     scaffolding.
#
# The state file this produces is gitignored. If it is lost, `terraform import`
# reconstructs it — see README.md, which lists the commands.
################################################################################

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

################################################################################
# State storage account
#
# Every setting here exists to protect state, which must be treated as a secret:
# it holds resource IDs, connection metadata, and any value a provider marked
# sensitive but still had to persist.
################################################################################

# AZU-0012 — "No network rules defined and default action allows access."
#
# TRUE, unlike the two occurrences of this rule in terraform/modules, which are
# artefacts of Trivy not resolving a dynamic block. There is genuinely no
# network rule here: this account is reachable from any address on the internet
# and gated by Entra ID alone, because shared_access_key_enabled is false.
#
# Accepted, with the reasoning in SECURITY.md, because both remedies cost more
# than they buy here: an IP allowlist breaks the CI plan job, whose GitHub-
# hosted runners change address per run, and a private endpoint needs a VNet
# that outlives every environment plus self-hosted runners to reach it. Neither
# fits a repository whose environments are torn down to nothing.
#
# Review by 2027-02-15. That date is a commitment, NOT a mechanism, and the
# difference was measured rather than assumed: Trivy 0.72.0 accepts
# `#trivy:ignore:AZU-0012 exp:<date>` here and suppresses the finding just the
# same once the date has passed — an expiry of 2020-01-01 still suppressed it.
# A `.trivyignore.yaml` with `expiredAt` did not suppress anything at all, at
# any of three path spellings. So there is no expiring-ignore available in this
# position, and writing `exp:` would have looked like a control that re-raises
# this finding on its own when nothing does. Deleting these two lines is the
# only thing that brings it back.
#trivy:ignore:AZU-0012
resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # TLS below 1.2 is broken, and state in transit is state in the clear.
  min_tls_version = "TLS1_2"

  # No anonymous read, ever. A public state file is a map of the estate.
  allow_nested_items_to_be_public = false

  # Static, non-expiring, unscopable, and grants total control of every state
  # file. The backends use use_azuread_auth = true, so nothing here needs it.
  shared_access_key_enabled = var.shared_access_key_enabled

  blob_properties {
    # Versioning is the protection that matters most: a corrupted or truncated
    # state push is recoverable by rolling back to the previous version.
    versioning_enabled = true

    # Versioning protects against overwrite. Soft delete protects against
    # DELETION, which is the failure that ends a platform rather than
    # inconveniencing it.
    dynamic "delete_retention_policy" {
      for_each = var.blob_soft_delete_retention_days > 0 ? [1] : []

      content {
        days = var.blob_soft_delete_retention_days
      }
    }

    # Blob soft delete does NOT cover deleting the container. Removing a
    # container takes every blob inside it with it, and without this the blob
    # policy above never gets the chance to apply.
    dynamic "container_delete_retention_policy" {
      for_each = var.blob_soft_delete_retention_days > 0 ? [1] : []

      content {
        days = var.blob_soft_delete_retention_days
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.blob_soft_delete_retention_days == 0 || var.blob_soft_delete_retention_days >= 7
      error_message = "blob_soft_delete_retention_days must be 0 (disabled) or at least 7. A window shorter than a week rarely outlives the weekend on which the deletion happened."
    }
  }
}

################################################################################
# One container per environment
#
# for_each over a statically-known variable. Adding an environment is a
# one-word change here, and is the only prerequisite before that environment's
# root module can run `terraform init`.
################################################################################

resource "azurerm_storage_container" "tfstate" {
  for_each = var.environments

  name               = "tfstate-${each.value}"
  storage_account_id = azurerm_storage_account.tfstate.id

  # Never "blob" or "container". Either makes every state file world-readable.
  container_access_type = "private"
}
