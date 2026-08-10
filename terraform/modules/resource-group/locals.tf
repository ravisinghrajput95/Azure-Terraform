################################################################################
# Lock selection
#
# Locks are created only for scopes that both appear in lock_scopes and exist
# in resource_group_names. Intersecting rather than indexing means a lock_scopes
# entry naming a group that was not requested is caught by the precondition in
# main.tf with a useful message, instead of raising an index error.
################################################################################

locals {
  requested_scopes = keys(var.resource_group_names)

  # Scopes named in lock_scopes that have no corresponding resource group.
  unknown_lock_scopes = setsubtract(toset(var.lock_scopes), toset(local.requested_scopes))

  locked_scopes = var.enable_resource_locks ? tolist(setintersection(
    toset(var.lock_scopes),
    toset(local.requested_scopes)
  )) : []

  locks = {
    for scope in local.locked_scopes :
    scope => {
      name = "lock-${var.resource_group_names[scope]}"
      notes = join(" ", [
        "Managed by Terraform.",
        "Applied because the environment profile sets enable_resource_locks.",
        "Remove the lock through Terraform, not the portal — a portal removal is reverted on the next apply."
      ])
    }
  }
}
