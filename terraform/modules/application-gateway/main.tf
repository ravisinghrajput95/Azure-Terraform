################################################################################
# Public IP
#
# Standard SKU, Static allocation — an Application Gateway v2 accepts nothing
# else, and the Basic SKU public IP was retired in September 2025.
################################################################################

resource "azurerm_public_ip" "this" {
  name                = var.public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location

  allocation_method = "Static"
  sku               = "Standard"
  zones             = var.zones

  tags = var.tags
}

################################################################################
# WAF policy
#
# A standalone policy rather than the gateway's inline waf_configuration block.
# The inline form is the older shape: it cannot be shared between gateways,
# cannot be applied per-listener, and its exclusions are harder to review
# because they live inside the gateway resource.
################################################################################

resource "azurerm_web_application_firewall_policy" "this" {
  count = local.is_waf ? 1 : 0

  name                = "waf-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = var.waf_request_body_check_enabled
    max_request_body_size_in_kb = var.waf_max_request_body_size_kb
    file_upload_limit_in_mb     = var.waf_file_upload_limit_mb
  }

  managed_rules {
    # Exclusions are holes in the WAF. Each one should carry a reason in the
    # calling configuration, and disabling a single rule ID is almost always
    # preferable to excluding an entire match variable.
    dynamic "exclusion" {
      for_each = var.waf_exclusions

      content {
        match_variable          = exclusion.value.match_variable
        selector_match_operator = exclusion.value.selector_match_operator
        selector                = exclusion.value.selector
      }
    }

    managed_rule_set {
      type    = var.waf_rule_set_type
      version = var.waf_rule_set_version
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.waf_blind_to_bodies
      error_message = join(" ", [
        "waf_request_body_check_enabled is false.",
        "The WAF would not inspect request bodies at all, which is where injection payloads usually live —",
        "leaving a WAF that appears active and misses the most common attack class."
      ])
    }
  }
}

################################################################################
# Application Gateway
#
# Blocks are wired together by NAME, and the names must match exactly across
# frontend ports, listeners, pools, settings, probes and rules. The locals file
# derives them once and the preconditions below reject every dangling
# reference, because Azure's own errors name an internal identifier rather than
# the configuration mistake.
################################################################################

resource "azurerm_application_gateway" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  zones         = var.zones
  http2_enabled = var.http2_enabled

  firewall_policy_id = local.is_waf ? azurerm_web_application_firewall_policy.this[0].id : null

  sku {
    name = var.sku_name
    tier = var.sku_name
  }

  # v2 autoscales. A fixed capacity is possible but wastes money at trough and
  # sheds traffic at peak.
  autoscale_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  gateway_ip_configuration {
    name      = local.gateway_ip_name
    subnet_id = var.subnet_id
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_name
    public_ip_address_id = azurerm_public_ip.this.id
  }

  dynamic "frontend_port" {
    for_each = local.frontend_ports

    content {
      name = frontend_port.key
      port = frontend_port.value
    }
  }

  ################################################################################
  # TLS
  #
  # The certificate is referenced from Key Vault, never embedded. A PFX in
  # configuration ends up in Terraform state, and rotating it becomes a
  # redeploy rather than a vault operation.
  ################################################################################

  dynamic "identity" {
    for_each = var.user_assigned_identity_id != null ? [1] : []

    content {
      type         = "UserAssigned"
      identity_ids = [var.user_assigned_identity_id]
    }
  }

  dynamic "ssl_certificate" {
    for_each = local.has_certificate ? [1] : []

    content {
      name                = local.ssl_certificate_name
      key_vault_secret_id = var.ssl_certificate_key_vault_secret_id
    }
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = var.ssl_policy_name
  }

  ################################################################################
  # Backends
  ################################################################################

  dynamic "backend_address_pool" {
    for_each = var.backend_pools

    content {
      name         = backend_address_pool.key
      fqdns        = backend_address_pool.value.fqdns
      ip_addresses = backend_address_pool.value.ip_addresses
    }
  }

  dynamic "probe" {
    for_each = var.probes

    content {
      name                                      = probe.key
      protocol                                  = probe.value.protocol
      path                                      = probe.value.path
      interval                                  = probe.value.interval
      timeout                                   = probe.value.timeout
      unhealthy_threshold                       = probe.value.unhealthy_threshold
      host                                      = probe.value.host
      pick_host_name_from_backend_http_settings = probe.value.pick_host_name_from_backend_http_settings

      match {
        status_code = probe.value.match_status_codes
      }
    }
  }

  dynamic "backend_http_settings" {
    for_each = var.backend_http_settings

    content {
      name                                = backend_http_settings.key
      port                                = backend_http_settings.value.port
      protocol                            = backend_http_settings.value.protocol
      cookie_based_affinity               = backend_http_settings.value.cookie_based_affinity
      request_timeout                     = backend_http_settings.value.request_timeout
      probe_name                          = backend_http_settings.value.probe_name
      host_name                           = backend_http_settings.value.host_name
      pick_host_name_from_backend_address = backend_http_settings.value.pick_host_name_from_backend_address
    }
  }

  ################################################################################
  # Frontend routing
  ################################################################################

  dynamic "http_listener" {
    for_each = var.listeners

    content {
      name                           = http_listener.key
      frontend_ip_configuration_name = local.frontend_ip_name
      frontend_port_name             = "port-${http_listener.value.port}"
      protocol                       = http_listener.value.protocol
      host_name                      = http_listener.value.host_name
      ssl_certificate_name           = http_listener.value.protocol == "Https" ? local.ssl_certificate_name : null
    }
  }

  dynamic "redirect_configuration" {
    for_each = var.redirect_configurations

    content {
      name                 = redirect_configuration.key
      redirect_type        = redirect_configuration.value.redirect_type
      target_listener_name = redirect_configuration.value.target_listener_name
      include_path         = redirect_configuration.value.include_path
      include_query_string = redirect_configuration.value.include_query_string
    }
  }

  dynamic "request_routing_rule" {
    for_each = var.routing_rules

    content {
      name                        = request_routing_rule.key
      rule_type                   = "Basic"
      priority                    = request_routing_rule.value.priority
      http_listener_name          = request_routing_rule.value.listener_name
      backend_address_pool_name   = request_routing_rule.value.backend_pool_name
      backend_http_settings_name  = request_routing_rule.value.backend_http_settings_name
      redirect_configuration_name = request_routing_rule.value.redirect_configuration_name
    }
  }

  tags = var.tags

  lifecycle {
    ############################################################################
    # Dangling references. Azure reports these as an internal identifier not
    # being found, which does not point at the mistake.
    ############################################################################
    precondition {
      condition     = length(local.unknown_listeners) == 0
      error_message = "Routing rules reference listeners that do not exist: ${join(", ", local.unknown_listeners)}."
    }

    precondition {
      condition     = length(local.unknown_backend_pools) == 0
      error_message = "Routing rules reference backend pools that do not exist: ${join(", ", local.unknown_backend_pools)}."
    }

    precondition {
      condition     = length(local.unknown_http_settings) == 0
      error_message = "Routing rules reference backend HTTP settings that do not exist: ${join(", ", local.unknown_http_settings)}."
    }

    precondition {
      condition     = length(local.unknown_probes) == 0
      error_message = "Backend HTTP settings reference probes that do not exist: ${join(", ", local.unknown_probes)}."
    }

    precondition {
      condition     = length(local.unknown_redirect_targets) == 0
      error_message = "Redirect configurations target listeners that do not exist: ${join(", ", local.unknown_redirect_targets)}."
    }

    precondition {
      condition = length(local.malformed_rules) == 0
      error_message = join(" ", [
        "These routing rules do not route to exactly one destination:",
        "${join(", ", local.malformed_rules)}.",
        "A rule must set EITHER backend_pool_name and backend_http_settings_name together, OR redirect_configuration_name alone."
      ])
    }

    precondition {
      condition = length(local.duplicate_priorities) == 0
      error_message = join("\n", concat(
        ["Routing rule priorities must be unique on a v2 gateway:"],
        local.duplicate_priorities
      ))
    }

    ############################################################################
    # TLS
    ############################################################################
    precondition {
      condition = length(local.https_listeners_without_certificate) == 0
      error_message = join(" ", [
        "These listeners use HTTPS but no certificate was supplied:",
        "${join(", ", local.https_listeners_without_certificate)}.",
        "Set ssl_certificate_key_vault_secret_id."
      ])
    }

    precondition {
      condition = !local.certificate_without_identity
      error_message = join(" ", [
        "ssl_certificate_key_vault_secret_id is set but user_assigned_identity_id is null.",
        "The gateway reads its certificate from Key Vault using a managed identity;",
        "without one it cannot fetch the certificate and provisioning fails.",
        "The identity also needs Key Vault Secrets User on the vault."
      ])
    }

    ############################################################################
    # Capacity
    ############################################################################
    precondition {
      condition     = !local.capacity_inverted
      error_message = "min_capacity (${var.min_capacity}) exceeds max_capacity (${var.max_capacity})."
    }
  }
}
