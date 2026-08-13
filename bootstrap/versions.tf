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
}
