################################################################################
# Version constraints
#
# The time provider covers Entra ID RBAC propagation. With shared access keys
# disabled, container creation authenticates as the caller's Entra principal —
# so the data-plane role assignment must be EFFECTIVE before a container can be
# created, and Azure offers no API to wait on.
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
