################################################################################
# Version constraints
#
# First module in the platform that creates Azure resources, so the first to
# declare a provider requirement.
#
# Child modules declare required_providers but NEVER a provider block. The
# provider is configured once in the environment root module and inherited.
# A provider block inside a reusable module makes it impossible to use that
# module twice with different credentials or subscriptions, and Terraform
# cannot remove it from state cleanly once present.
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
