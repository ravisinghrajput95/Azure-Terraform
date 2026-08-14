################################################################################
# Provider
#
# Configured once here and inherited by every child module. No child module
# declares a provider block — doing so would prevent the module being used
# twice with different credentials, and Terraform cannot cleanly remove such a
# block once it exists in state.
#
# Authentication is by Azure CLI (`az login`). There is deliberately no
# client_secret: a service principal secret in a tfvars file is a static
# credential sitting in plaintext on disk and in shell history. For CI, use
# workload identity federation (OIDC) rather than adding a secret here.
################################################################################

provider "azurerm" {
  subscription_id = var.subscription_id

  # Authenticate storage DATA-plane operations with the caller's Entra
  # identity rather than an account key. Required, because the storage module
  # sets shared_access_key_enabled = false — without this flag the provider
  # would try to fetch a key that does not exist.
  storage_use_azuread = true

  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources
      # Terraform does not know about. The default (true) will happily delete
      # anything created outside Terraform that happens to live in the group.
      prevent_deletion_if_contains_resources = true
    }

    key_vault {
      # Recover a soft-deleted vault of the same name rather than failing.
      recover_soft_deleted_key_vaults = true

      ##########################################################################
      # FALSE, and this is the one provider difference between prod and every
      # other environment.
      #
      # prod is the only environment with key_vault_purge_protection = true.
      # Purge protection and purge-on-destroy are mutually exclusive by
      # definition: purge protection exists precisely to make the vault
      # unpurgeable for its full retention period, so a provider configured to
      # purge on destroy is asking Azure to do something it will refuse.
      #
      # dev, qa and stage all set this true, because their vault names are
      # deterministic and purge protection would block rebuilding them for 90
      # days. prod is not rebuilt on a whim, and a vault that can be destroyed
      # and immediately purged is a vault whose keys can be destroyed and
      # immediately purged.
      ##########################################################################
      purge_soft_delete_on_destroy = false
    }
  }
}
