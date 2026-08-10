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
      # In dev, purge on destroy so the name is immediately reusable. The
      # profile module keeps purge protection off in dev for the same reason.
      purge_soft_delete_on_destroy = true
    }
  }
}
