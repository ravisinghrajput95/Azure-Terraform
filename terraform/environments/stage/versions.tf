################################################################################
# Version constraints
#
# azurerm 4.x, not the 3.117 pinned by the legacy root configuration. Version 4
# requires an explicit subscription_id and changes resource provider
# registration behaviour, so the two are not interchangeable.
#
# The exact patch version is locked by .terraform.lock.hcl, which is committed.
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
