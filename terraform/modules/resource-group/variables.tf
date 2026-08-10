################################################################################
# Required inputs
################################################################################

variable "resource_group_names" {
  description = "Map of lifecycle scope to resource group name, as produced by the naming module's resource_group_names output. Keys become the map keys of every output, so downstream modules address a group by scope (\"net\", \"data\") rather than by index."
  type        = map(string)

  validation {
    condition     = length(var.resource_group_names) > 0
    error_message = "resource_group_names must contain at least one entry."
  }

  validation {
    condition     = alltrue([for name in values(var.resource_group_names) : length(name) >= 1 && length(name) <= 90])
    error_message = "Azure resource group names must be 1-90 characters."
  }

  # Azure permits alphanumerics, underscore, parentheses, hyphen, period and
  # unicode letters, but a name may not end with a period.
  validation {
    condition     = alltrue([for name in values(var.resource_group_names) : can(regex("^[a-zA-Z0-9_().-]+$", name)) && !endswith(name, ".")])
    error_message = "Resource group names may contain only alphanumerics, underscore, parentheses, hyphen and period, and must not end with a period."
  }

  validation {
    condition     = length(distinct(values(var.resource_group_names))) == length(values(var.resource_group_names))
    error_message = "Resource group names must be unique. Two scopes sharing a name would collapse into one group."
  }
}

variable "location" {
  description = "Azure region, normalised form (e.g. \"eastus\"). Pass the naming module's location_normalized output rather than the raw input, so that \"East US\" and \"eastus\" cannot produce two different values in state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must be the normalised Azure region name: lowercase alphanumerics only, e.g. \"eastus\". Use the naming module's location_normalized output."
  }
}

variable "tags" {
  description = "Tags applied to every resource group, from the tags module. Azure does not propagate these to resources inside the group — each resource must be tagged independently."
  type        = map(string)
}

################################################################################
# Deletion protection
#
# Terraform's `lifecycle { prevent_destroy }` cannot be made conditional: it
# requires a literal and rejects any variable or expression. There is no way to
# enable it for production and not for dev.
#
# azurerm_management_lock CAN be conditional, so deletion protection is
# delivered through Azure locks driven by the profile module's
# enable_resource_locks flag.
################################################################################

variable "enable_resource_locks" {
  description = "Whether to apply management locks. Pass the profile module's enable_resource_locks output. Locks are off in dev because they block `terraform destroy`, which is the primary cost control on a credit-limited subscription."
  type        = bool
  default     = false
}

variable "lock_scopes" {
  description = "Which lifecycle scopes receive a lock when enable_resource_locks is true. Deliberately excludes \"app\" by default: a CanNotDelete lock on a resource group cascades to every resource inside it, which would block the routine scale set replacements that application deploys depend on."
  type        = list(string)
  default     = ["net", "sec", "data"]
}

variable "lock_level" {
  description = "Lock severity. CanNotDelete permits reads and updates but blocks deletion. ReadOnly blocks updates too, which breaks Terraform's ability to manage tags and most other properties — use it only for a genuinely frozen resource group."
  type        = string
  default     = "CanNotDelete"

  validation {
    condition     = contains(["CanNotDelete", "ReadOnly"], var.lock_level)
    error_message = "lock_level must be either CanNotDelete or ReadOnly."
  }
}
