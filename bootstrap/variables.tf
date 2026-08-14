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
  description = <<-EOT
    Globally unique state account name.

    NO DEFAULT, deliberately. A storage account name is a public DNS label —
    `<name>.blob.core.windows.net` resolves for anyone — so committing one to a
    public repository publishes the exact endpoint holding every environment's
    Terraform state. Access is still RBAC-gated and shared keys are disabled,
    so the name alone grants nothing; it is an unnecessary disclosure and a
    free target, not a breach.

    Supply it in `terraform.tfvars`, which is gitignored. See
    `terraform.tfvars.example`.

    Not derived from the naming module either: that module is part of the
    codebase this account stores the state for, and the bootstrap must not
    depend on it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names are 3-24 characters, lowercase letters and digits only. Azure rejects anything else with an error that does not name the rule."
  }
}

variable "environments" {
  description = "One state container per environment. Adding an environment here is the only step needed before its root module can `terraform init`."
  type        = set(string)
  default     = ["dev", "qa", "stage", "prod"]
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    Whether the account accepts shared-key authentication.

    FALSE, and set that way on the live account on 2026-08-14. Shared keys are
    static, non-expiring, unscopable, attributable to no one, and grant total
    control of every state file in the account. Every backend here uses
    `use_azuread_auth = true`, so nothing needs them.

    Verified after the change: key auth returns "Key based authentication is not
    permitted on this storage account", while `terraform plan` against dev still
    reads state, takes the lock and releases it.

    Setting this back to true reopens a path that bypasses RBAC entirely.
  EOT
  type        = bool
  default     = false
}

variable "blob_soft_delete_retention_days" {
  description = <<-EOT
    Soft-delete window for blobs and containers. 0 disables both.

    30, and set that way on the live account on 2026-08-14. Versioning was
    already on and protects against overwrite -- a truncated state push rolls
    back to the previous version. Soft delete is the separate protection against
    DELETION, which is the failure that ends a platform rather than
    inconveniencing it.
  EOT
  type        = number
  default     = 30
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
