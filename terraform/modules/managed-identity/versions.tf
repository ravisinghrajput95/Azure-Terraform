################################################################################
# Version constraints
#
# The time provider is required for the Entra ID propagation delay. See the
# comment on time_sleep in main.tf — Azure role assignments are eventually
# consistent, and there is no API to wait on.
################################################################################

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
