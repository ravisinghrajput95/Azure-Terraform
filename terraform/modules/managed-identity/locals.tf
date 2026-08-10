################################################################################
# Role assignment validation
#
# A role assignment naming an identity key that does not exist would raise an
# index error deep inside the resource, naming a map lookup rather than the
# configuration mistake.
################################################################################

locals {
  unknown_identity_keys = sort(distinct([
    for key, assignment in var.role_assignments : assignment.identity_key
    if !contains(keys(var.identities), assignment.identity_key)
  ]))
}

################################################################################
# Propagation gate
#
# When a delay is configured, dependent resources should depend on the
# time_sleep rather than on the identities directly. The `ready` output carries
# that dependency: consuming it in a downstream module means the module cannot
# start until the wait has elapsed.
################################################################################

locals {
  wait_enabled = var.propagation_delay_seconds > 0
}
