################################################################################
# Inputs
################################################################################

variable "subscription_id" {
  description = "Subscription the state backend lives in. Required by azurerm v4."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group holding the state account. Deliberately separate from every workload resource group so that destroying an environment cannot reach its own state."
  type        = string
  default     = "REDACTED-STATE-RG"
}

variable "location" {
  description = <<-EOT
    Region for the state account.

    Defaults to eastus, which is where the existing account already lives —
    predating the platform's move to centralus (ARCHITECTURE.md §6a). State does
    not need to be co-located with the resources it describes, and moving a
    storage account means recreating it and copying every state file, so the
    mismatch is left alone deliberately rather than tidied.
  EOT
  type        = string
  default     = "eastus"
}

variable "storage_account_name" {
  description = "Globally unique state account name. Not derived from the naming module: that module is part of the codebase this account stores the state for, and the bootstrap must not depend on it."
  type        = string
  default     = "REDACTED-STATE-ACCOUNT"
}

variable "environments" {
  description = "One state container per environment. Adding an environment here is the only step needed before its root module can `terraform init`."
  type        = set(string)
  default     = ["dev", "qa", "stage", "prod"]
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    Whether the account accepts shared-key authentication.

    SHOULD be false: shared keys are static, non-expiring, unscopable and grant
    total control of every state file, and the backends here already use
    `use_azuread_auth = true`. It defaults to TRUE only because that is the
    account's current live state, and flipping it is a change to a live backend
    that deserves to be made deliberately rather than discovered during an
    unrelated apply. See README.md.
  EOT
  type        = bool
  default     = true
}

variable "blob_soft_delete_retention_days" {
  description = "Blob soft-delete window. 0 disables it, which is the account's current live state. Versioning already protects against overwrite; soft delete is what protects against deletion."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags applied to the bootstrap resources."
  type        = map(string)
  default = {
    workload  = "cloudcart"
    purpose   = "terraform-state"
    managedBy = "Terraform"
  }
}
