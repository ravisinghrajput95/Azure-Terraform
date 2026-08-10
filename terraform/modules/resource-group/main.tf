################################################################################
# Resource groups
#
# One group per lifecycle scope. Resource groups are the unit of RBAC scope and
# of deletion blast radius, so separating them means the identity that
# redeploys the application cannot delete the network edge or the database.
# See docs/ARCHITECTURE.md section 1.2.
#
# for_each over the scope map, never count over a list: with count, removing
# one scope re-indexes every group after it, and Terraform would plan to
# destroy and recreate unrelated resource groups. With for_each, each group is
# addressed by its scope name and removal affects only that group.
################################################################################

resource "azurerm_resource_group" "this" {
  for_each = var.resource_group_names

  name     = each.value
  location = var.location
  tags     = var.tags

  lifecycle {
    precondition {
      condition = length(local.unknown_lock_scopes) == 0
      error_message = join(" ", [
        "lock_scopes names scopes with no corresponding resource group:",
        "${join(", ", tolist(local.unknown_lock_scopes))}.",
        "Available scopes are: ${join(", ", local.requested_scopes)}.",
        "A lock for a group that is never created would silently do nothing."
      ])
    }
  }
}

################################################################################
# Management locks
#
# The conditional replacement for `prevent_destroy`, which requires a literal
# and therefore cannot vary by environment.
#
# A lock on a resource group cascades to every resource inside it. That is the
# intent for the network, security and data groups, whose contents should never
# be deleted by a routine apply. The application group is excluded by default
# so that scale set replacement still works.
#
# Note the operational consequence: with a lock in place, `terraform destroy`
# fails until the lock is removed. That is the point, but it does mean tearing
# down a locked environment is a two-step operation.
################################################################################

resource "azurerm_management_lock" "this" {
  for_each = local.locks

  name       = each.value.name
  scope      = azurerm_resource_group.this[each.key].id
  lock_level = var.lock_level
  notes      = each.value.notes
}
