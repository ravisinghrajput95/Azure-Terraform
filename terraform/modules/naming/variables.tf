################################################################################
# Required inputs
################################################################################

variable "workload" {
  description = "Short workload or application identifier. Appears in every resource name, so it is length-constrained to keep globally-unique names (storage accounts cap at 24 characters) within their limits."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.workload))
    error_message = "workload must be 2-10 characters, lowercase letters and digits only, and start with a letter. Storage account names are built from this value and cannot contain hyphens or uppercase."
  }
}

variable "environment" {
  description = "Deployment environment. Drives both the name segment and the environment profile selected downstream."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "location" {
  description = "Azure region. Accepts either the display name ('East US') or the internal name ('eastus'); both normalise to the same abbreviation."
  type        = string

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

################################################################################
# Optional inputs
################################################################################

variable "instance" {
  description = "Three-digit instance number, allowing a second parallel deployment of the same workload in the same region without a name collision."
  type        = string
  default     = "001"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.instance))
    error_message = "instance must be exactly three digits, e.g. \"001\"."
  }
}

variable "unique_seed" {
  description = "Seed mixed into the hash suffix applied to globally-unique resource names (storage, Key Vault, SQL, Redis). Pass the subscription ID so the same workload deployed in a different subscription or tenant produces different global names. Leaving this empty still yields deterministic names, but two tenants deploying identical inputs would collide."
  type        = string
  default     = ""
}

variable "resource_group_scopes" {
  description = "Lifecycle scopes that each receive their own resource group. See docs/ARCHITECTURE.md section 1.2 — resource groups are the unit of RBAC and deletion blast radius, so compute and network edge are deliberately separated."
  type        = list(string)
  default     = ["net", "sec", "data", "app", "mon"]

  validation {
    condition     = length(var.resource_group_scopes) > 0
    error_message = "resource_group_scopes must contain at least one scope."
  }

  validation {
    condition     = alltrue([for s in var.resource_group_scopes : can(regex("^[a-z][a-z0-9]{1,7}$", s))])
    error_message = "Each resource group scope must be 2-8 lowercase alphanumeric characters starting with a letter."
  }

  validation {
    condition     = length(distinct(var.resource_group_scopes)) == length(var.resource_group_scopes)
    error_message = "resource_group_scopes must not contain duplicates."
  }
}

variable "tiers" {
  description = "Workload tiers that receive their own subnet, NSG and (where applicable) scale set. Names are precomputed for each tier so callers never concatenate strings themselves."
  type        = list(string)
  default     = ["app", "biz", "db", "pep", "mgmt"]

  validation {
    condition     = length(var.tiers) > 0
    error_message = "tiers must contain at least one tier."
  }

  validation {
    condition     = alltrue([for t in var.tiers : can(regex("^[a-z][a-z0-9]{1,7}$", t))])
    error_message = "Each tier must be 2-8 lowercase alphanumeric characters starting with a letter."
  }

  validation {
    condition     = length(distinct(var.tiers)) == length(var.tiers)
    error_message = "tiers must not contain duplicates."
  }
}

variable "compute_tiers" {
  description = "Subset of var.tiers that actually host compute and therefore need scale set and managed identity names. Kept separate so the module does not emit names for combinations that never exist (there is no scale set in the private endpoint subnet). Must be a subset of var.tiers."
  type        = list(string)
  default     = ["app", "biz"]

  validation {
    condition     = length(distinct(var.compute_tiers)) == length(var.compute_tiers)
    error_message = "compute_tiers must not contain duplicates."
  }

  # Cross-variable references in validation blocks require Terraform >= 1.9,
  # which versions.tf pins. Before 1.9 this check could only live in a
  # precondition, far away from the input it constrains.
  validation {
    condition     = alltrue([for t in var.compute_tiers : contains(var.tiers, t)])
    error_message = "Every entry in compute_tiers must also appear in tiers. A compute tier with no subnet cannot be deployed."
  }
}

variable "location_abbreviations" {
  description = "Override or extend the built-in region abbreviation table. Merged over the defaults, so supplying a single new region does not require restating the whole map. Keys must be normalised region names (lowercase, no spaces)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.location_abbreviations : can(regex("^[a-z0-9]{2,6}$", v))])
    error_message = "Each location abbreviation must be 2-6 lowercase alphanumeric characters."
  }
}
