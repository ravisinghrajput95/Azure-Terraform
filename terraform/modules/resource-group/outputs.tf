################################################################################
# Resource groups
#
# Every output is keyed by lifecycle scope, so a downstream module reads
# module.resource_group.names["net"] rather than depending on ordering.
################################################################################

output "ids" {
  description = "Map of lifecycle scope to resource group ID. Use these for role assignment scopes, diagnostic settings and management locks."
  value       = { for scope, rg in azurerm_resource_group.this : scope => rg.id }
}

output "names" {
  description = "Map of lifecycle scope to resource group name. This is the value downstream modules pass as resource_group_name."
  value       = { for scope, rg in azurerm_resource_group.this : scope => rg.name }
}

output "location" {
  description = "Region the groups were created in. Re-exported so downstream modules take their location from the created resource rather than re-deriving it, which keeps a single source of truth."
  value       = var.location
}

output "resource_groups" {
  description = "Full detail per scope: id, name, location and tags. For callers that need more than the ID or name."
  value = {
    for scope, rg in azurerm_resource_group.this :
    scope => {
      id       = rg.id
      name     = rg.name
      location = rg.location
      tags     = rg.tags
    }
  }
}

################################################################################
# Locks
################################################################################

output "locked_scopes" {
  description = "Scopes that actually received a management lock. Empty when enable_resource_locks is false. Check this before running `terraform destroy` — a locked group blocks deletion until the lock is removed."
  value       = sort(keys(azurerm_management_lock.this))
}

output "lock_ids" {
  description = "Map of lifecycle scope to management lock ID."
  value       = { for scope, lock in azurerm_management_lock.this : scope => lock.id }
}
