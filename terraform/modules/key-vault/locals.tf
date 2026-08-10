################################################################################
# Reachability
#
# A vault with no public endpoint and no private endpoint is created
# successfully and is then unreachable by anything, including Terraform. The
# control plane still works, so the apply succeeds and the failure only appears
# the first time a secret is read.
################################################################################

locals {
  has_private_endpoint = var.private_endpoint_subnet_id != null

  is_unreachable = !var.public_network_access_enabled && !local.has_private_endpoint

  # A private endpoint without a DNS zone group resolves to the vault's public
  # address from inside the VNet — which, with public access disabled, fails,
  # and with it enabled silently bypasses the private path.
  private_endpoint_without_dns = local.has_private_endpoint && length(var.private_dns_zone_ids) == 0
}

################################################################################
# Access rules
#
# network_acls is emitted whenever a public endpoint exists. With the endpoint
# disabled the block is redundant, and Azure ignores it.
################################################################################

locals {
  emit_network_acls = var.public_network_access_enabled

  # Default Allow with rules present is the most dangerous misconfiguration
  # here: it reads as "these are the permitted sources" while actually
  # permitting everything.
  acls_are_permissive = var.public_network_access_enabled && var.network_acls_default_action == "Allow"

  # A public endpoint with default Deny and no rules is locked shut. Legitimate
  # when a private endpoint carries all traffic, but usually a mistake — the
  # allowlist was forgotten.
  public_endpoint_with_no_rules = (
    var.public_network_access_enabled
    && var.network_acls_default_action == "Deny"
    && length(var.allowed_ip_rules) == 0
    && length(var.allowed_subnet_ids) == 0
  )
}
