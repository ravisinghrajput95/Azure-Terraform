################################################################################
# Placement
################################################################################

variable "name" {
  description = "Vault name, from naming.recovery_services_vault. Unique within the resource group."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,49}$", var.name))
    error_message = "Recovery Services vault names must be 2-50 characters, start with a letter, and contain only letters, numbers and hyphens."
  }
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"mon\" lifecycle scope — the vault must outlive the resources it protects, so it does not belong in the app group that gets torn down."
  type        = string
}

variable "location" {
  description = "Azure region. A vault can only protect resources in its OWN region, so this must match the workloads it backs up."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Vault configuration
################################################################################

variable "sku" {
  description = "Vault SKU. \"Standard\" for Recovery Services; \"RS0\" is the legacy tier and should not be used for new vaults."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "RS0"], var.sku)
    error_message = "sku must be Standard or RS0."
  }
}

variable "storage_mode_type" {
  description = <<-EOT
    Backup storage redundancy.

    Cannot be changed once ANY item is protected in the vault — Azure rejects
    the update, and the only remedy is a new vault, which means losing the
    existing recovery points. Choose it deliberately at creation.

    GeoRedundant costs materially more than LocallyRedundant and is the Azure
    default, so leaving it unset in a cost-sensitive environment is an
    expensive silence.
  EOT
  type        = string
  default     = "LocallyRedundant"

  validation {
    condition     = contains(["LocallyRedundant", "GeoRedundant", "ZoneRedundant"], var.storage_mode_type)
    error_message = "storage_mode_type must be LocallyRedundant, GeoRedundant or ZoneRedundant."
  }
}

variable "cross_region_restore_enabled" {
  description = "Allow restore into the paired region. Requires storage_mode_type = \"GeoRedundant\" — the combination is rejected by a precondition rather than at apply, because the Azure error names only one of the two settings."
  type        = bool
  default     = false
}

variable "immutability" {
  description = <<-EOT
    Immutability state: "Disabled", "Unlocked" or "Locked".

    "Locked" is IRREVERSIBLE. Once locked, recovery points cannot be deleted
    or shortened by anyone — including a subscription owner, including
    Microsoft support — for the whole of their retention. It is the correct
    posture against ransomware and the wrong one anywhere a mistake needs
    undoing. Requires explicit acknowledgement.
  EOT
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "Unlocked", "Locked"], var.immutability)
    error_message = "immutability must be Disabled, Unlocked or Locked."
  }
}

variable "immutability_lock_acknowledged" {
  description = "Explicit acknowledgement that immutability = \"Locked\" is irreversible. Required only for that value, so the irreversible choice cannot be made by editing one word."
  type        = bool
  default     = false
}

variable "public_network_access_enabled" {
  description = "Whether the vault accepts traffic from public networks. Backup traffic from Azure resources does not need this, but disabling it without a private endpoint blocks management operations from an operator machine."
  type        = bool
  default     = true
}

variable "system_assigned_identity_enabled" {
  description = "Enable a system-assigned managed identity. Required for customer-managed keys and for cross-subscription restore."
  type        = bool
  default     = true
}

################################################################################
# Monitoring
################################################################################

variable "alerts_for_all_job_failures_enabled" {
  description = "Built-in vault alerting on backup job failures. Independent of the monitor module's action group — this is Azure Backup's own notification path, and it is the only one that reports a backup that silently stopped running."
  type        = bool
  default     = true
}

variable "alerts_for_critical_operation_failures_enabled" {
  description = "Built-in vault alerting on critical operations, such as deleting backup data."
  type        = bool
  default     = true
}

################################################################################
# VM backup policies
#
# Policies cost nothing. Azure bills per PROTECTED INSTANCE plus the storage
# its recovery points consume, so a vault holding policies and protecting
# nothing is free.
################################################################################

variable "vm_backup_policies" {
  description = <<-EOT
    Virtual machine backup policies, keyed by policy name.

    The retention weekday alignment is the reason this module validates as much
    as it does. On a Weekly schedule, a retention rule naming a weekday the
    backup does not run on retains NOTHING — Azure accepts the policy, shows it
    as valid, and silently keeps no long-term recovery points at all.
  EOT

  type = map(object({
    frequency = optional(string, "Daily")
    time      = optional(string, "23:00")
    timezone  = optional(string, "UTC")

    # Required when frequency is "Weekly"; ignored when Daily.
    weekdays = optional(set(string), [])

    instant_restore_retention_days = optional(number, 2)

    retention_daily = optional(number)

    retention_weekly = optional(object({
      count    = number
      weekdays = set(string)
    }))

    retention_monthly = optional(object({
      count    = number
      weekdays = set(string)
      weeks    = set(string)
    }))

    retention_yearly = optional(object({
      count    = number
      months   = set(string)
      weekdays = set(string)
      weeks    = set(string)
    }))
  }))

  default = {}
}

################################################################################
# File share backup policies
################################################################################

variable "file_share_backup_policies" {
  description = "Azure Files backup policies, keyed by policy name. Same weekday-alignment rules as VM policies."

  type = map(object({
    frequency = optional(string, "Daily")
    time      = optional(string, "23:00")
    timezone  = optional(string, "UTC")

    retention_daily = optional(number)

    retention_weekly = optional(object({
      count    = number
      weekdays = set(string)
    }))
  }))

  default = {}
}
