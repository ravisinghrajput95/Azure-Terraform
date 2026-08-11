################################################################################
# Frontend shape
################################################################################

locals {
  is_internal = var.type == "internal"
  is_public   = var.type == "public"

  frontend_name = "frontend"

  # An internal LB needs a subnet; a public one needs a public IP. Supplying
  # the wrong one is rejected at plan time rather than by Azure mid-apply.
  internal_missing_subnet = local.is_internal && var.subnet_id == null
  public_with_subnet      = local.is_public && var.subnet_id != null
  public_missing_ip_name  = local.is_public && var.public_ip_name == null
  internal_with_ip_name   = local.is_internal && var.public_ip_name != null
}

################################################################################
# Rule and probe consistency
#
# A rule naming a probe or pool that does not exist would raise an index error
# naming a map lookup rather than the configuration mistake.
################################################################################

locals {
  unknown_probes = sort(distinct([
    for name, rule in var.rules : rule.probe_name
    if !contains(keys(var.probes), rule.probe_name)
  ]))

  unknown_pools = sort(distinct([
    for name, rule in var.rules : rule.backend_pool_name
    if !contains(var.backend_pools, rule.backend_pool_name)
  ]))

  # A probe nothing references is inert. Usually a rename that missed one side.
  referenced_probes = distinct([for rule in values(var.rules) : rule.probe_name])

  orphaned_probes = sort([
    for name in keys(var.probes) : name
    if !contains(local.referenced_probes, name)
  ])

  # A pool with no rule receives no traffic. The vm module may still attach a
  # scale set to it, which then sits healthy and idle.
  referenced_pools = distinct([for rule in values(var.rules) : rule.backend_pool_name])

  unused_pools = sort([
    for name in var.backend_pools : name
    if !contains(local.referenced_pools, name)
  ])
}

################################################################################
# Health check quality
#
# Surfaced rather than blocked: a TCP probe is occasionally the only option,
# but it should be a conscious choice. A hung process keeps accepting TCP
# connections, so a TCP probe reports healthy while every request times out.
################################################################################

locals {
  tcp_only_probes = sort([
    for name, probe in var.probes : name
    if probe.protocol == "Tcp"
  ])

  # How long a dead instance keeps receiving traffic.
  probe_detection_seconds = {
    for name, probe in var.probes :
    name => probe.interval_in_seconds * probe.probe_threshold
  }
}
