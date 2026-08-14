################################################################################
# Version constraints
#
# NOTE: no backend block. This configuration deliberately uses LOCAL state.
# See README.md — making the bootstrap self-hosting is a circular dependency.
################################################################################

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # REQUIRED, not a preference, since shared_access_key_enabled = false.
  #
  # Reading a storage account touches the data plane — the provider fetches
  # queue and share properties as part of a plain refresh — and it does that
  # with a shared key unless told otherwise. With keys disabled the account is
  # unreadable and even `terraform import` fails:
  #
  #   Error: retrieving queue properties ... 403 Key based authentication is
  #   not permitted on this storage account.
  #
  # The error names the queue endpoint, which is misleading: nothing here uses
  # queues. It is the provider's own read path, and this flag switches it to
  # Entra ID. The caller then needs a data-plane role — Storage Blob Data
  # Contributor or Owner — because control-plane Owner alone is not enough.
  storage_use_azuread = true
}
