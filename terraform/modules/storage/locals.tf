################################################################################
# Reachability
################################################################################

locals {
  has_private_endpoints = var.create_private_endpoints && length(var.private_endpoint_subresources) > 0

  is_unreachable = !var.public_network_access_enabled && !local.has_private_endpoints

  # A private endpoint with no DNS zone registers no A record, so the account
  # hostname resolves to its public address from inside the VNet — failing
  # outright when public access is off, silently bypassing the private path
  # when it is on.
  subresources_missing_dns = sort([
    for sub in var.private_endpoint_subresources : sub
    if length(lookup(var.private_dns_zone_ids_by_subresource, sub, [])) == 0
  ])

  # coalesce rather than the bare variable, and the reason is the linter rather
  # than the deployment.
  #
  # private_endpoint_name_prefix defaults to null, and TFLint evaluates a module
  # with its variable DEFAULTS — including this branch, which is not taken by
  # default. A null inside a string template is an evaluation error, and it does
  # not fail one rule: it aborts the entire azurerm ruleset for this directory
  # with "Failed to check ruleset", so every SKU and name check in the module
  # silently stops running.
  #
  # The fallback is never used at apply. The precondition on
  # azurerm_private_endpoint rejects a null prefix first, and by name — which is
  # a better error than the null-interpolation one this replaces.
  private_endpoint_name_prefix = coalesce(var.private_endpoint_name_prefix, "pep-unset")

  private_endpoints = local.has_private_endpoints ? {
    for sub in var.private_endpoint_subresources : sub => {
      subresource = sub
      name        = "${local.private_endpoint_name_prefix}-${sub}"
      zone_ids    = lookup(var.private_dns_zone_ids_by_subresource, sub, [])
    }
  } : {}
}

################################################################################
# Access rules
################################################################################

locals {
  # Default Allow alongside rules is the dangerous case: it reads as an
  # allowlist while permitting every source not explicitly denied.
  rules_are_permissive = var.public_network_access_enabled && var.network_rules_default_action == "Allow"

  # network_rules is only meaningful when a public endpoint exists.
  emit_network_rules = var.public_network_access_enabled
}

################################################################################
# Data-plane authorisation
#
# With shared access keys disabled, EVERY data-plane operation authenticates
# as an Entra principal — including Terraform creating a container. Control
# plane roles do not help: a subscription Owner with no data role gets 403 on
# a container list.
#
# Detect the specific case of "containers requested, keys disabled, no
# data-plane role granted", which otherwise fails mid-apply with an
# authorisation error that names neither the missing role nor the reason.
################################################################################

locals {
  data_plane_roles = [
    "Storage Blob Data Owner",
    "Storage Blob Data Contributor",
    "Storage Blob Data Reader",
  ]

  has_data_plane_grant = anytrue([
    for assignment in values(var.role_assignments) :
    contains(local.data_plane_roles, assignment.role_definition_name)
  ])

  containers_without_data_plane_grant = (
    length(var.containers) > 0
    && !var.shared_access_key_enabled
    && !local.has_data_plane_grant
  )

  wait_for_rbac = length(var.containers) > 0 && var.rbac_propagation_delay_seconds > 0
}
