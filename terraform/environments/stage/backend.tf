################################################################################
# Remote state
#
# Partial configuration. The storage account, container and key are supplied at
# init time from backend.conf, which is gitignored:
#
#   terraform init -backend-config=backend.conf
#
# The backend cannot live in the state it stores, so the storage account is
# bootstrapped out of band. See docs/DEPLOYMENT.md, Phase 0.
#
# use_azuread_auth in backend.conf makes the backend authenticate with the
# caller's Entra identity rather than a storage account access key. The account
# is created with shared key access available but unused; RBAC is the path.
################################################################################

terraform {
  backend "azurerm" {}
}
