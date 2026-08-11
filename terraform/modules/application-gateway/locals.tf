################################################################################
# Fixed names
#
# The gateway wires its blocks together by NAME, and those names must match
# exactly across five separate blocks. Deriving them once removes the class of
# error where a rule references a listener that is spelled differently.
################################################################################

locals {
  frontend_ip_name     = "frontend-public"
  gateway_ip_name      = "gateway-ip"
  ssl_certificate_name = "tls-cert"

  is_waf = var.sku_name == "WAF_v2"

  has_certificate = var.ssl_certificate_key_vault_secret_id != null

  # Frontend ports are derived from the listeners rather than declared
  # separately, so a listener can never reference a port that was not created.
  frontend_ports = {
    for port in distinct([for listener in values(var.listeners) : listener.port]) :
    "port-${port}" => port
  }
}

################################################################################
# Cross-reference validation
#
# Every one of these produces an Azure error naming an internal identifier
# rather than the configuration mistake, so they are checked here first.
################################################################################

locals {
  unknown_listeners = sort(distinct([
    for name, rule in var.routing_rules : rule.listener_name
    if !contains(keys(var.listeners), rule.listener_name)
  ]))

  unknown_backend_pools = sort(distinct([
    for name, rule in var.routing_rules : rule.backend_pool_name
    if rule.backend_pool_name != null && !contains(keys(var.backend_pools), rule.backend_pool_name)
  ]))

  unknown_http_settings = sort(distinct([
    for name, rule in var.routing_rules : rule.backend_http_settings_name
    if rule.backend_http_settings_name != null && !contains(keys(var.backend_http_settings), rule.backend_http_settings_name)
  ]))

  unknown_probes = sort(distinct([
    for name, settings in var.backend_http_settings : settings.probe_name
    if settings.probe_name != null && !contains(keys(var.probes), settings.probe_name)
  ]))

  unknown_redirect_targets = sort(distinct([
    for name, redirect in var.redirect_configurations : redirect.target_listener_name
    if !contains(keys(var.listeners), redirect.target_listener_name)
  ]))

  # A rule must route to exactly one destination: a backend or a redirect.
  malformed_rules = sort([
    for name, rule in var.routing_rules : name
    if !(
      (rule.backend_pool_name != null && rule.backend_http_settings_name != null && rule.redirect_configuration_name == null) ||
      (rule.backend_pool_name == null && rule.backend_http_settings_name == null && rule.redirect_configuration_name != null)
    )
  ])

  # v2 requires a unique priority on every rule.
  priority_groups = {
    for name, rule in var.routing_rules : tostring(rule.priority) => name...
  }

  duplicate_priorities = sort([
    for priority, names in local.priority_groups :
    "priority ${priority} used by: ${join(", ", sort(names))}"
    if length(names) > 1
  ])
}

################################################################################
# TLS and health-check quality
################################################################################

locals {
  # An HTTPS listener with no certificate cannot serve anything.
  https_listeners_without_certificate = sort([
    for name, listener in var.listeners : name
    if listener.protocol == "Https" && !local.has_certificate
  ])

  certificate_without_identity = local.has_certificate && var.user_assigned_identity_id == null

  # Backend settings with no probe fall back to Azure's default probe against
  # "/", which returns 404 on most applications — marking every backend
  # unhealthy while the application is fine.
  settings_without_probe = sort([
    for name, settings in var.backend_http_settings : name
    if settings.probe_name == null
  ])
}

################################################################################
# Capacity
################################################################################

locals {
  capacity_inverted = var.min_capacity > var.max_capacity

  # A WAF with request body inspection off is blind to POST payloads, which is
  # where injection attempts usually live.
  waf_blind_to_bodies = local.is_waf && !var.waf_request_body_check_enabled
}
