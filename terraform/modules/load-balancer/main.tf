################################################################################
# Public IP
#
# Public load balancer only. Standard SKU and Static allocation are the only
# valid combination — the Basic SKU public IP was retired in September 2025,
# and a Standard load balancer requires a Standard IP regardless.
################################################################################

resource "azurerm_public_ip" "this" {
  count = local.is_public ? 1 : 0

  name                = var.public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location

  allocation_method = "Static"
  sku               = "Standard"
  zones             = var.zones

  tags = var.tags
}

################################################################################
# Load balancer
#
# Standard SKU. Beyond the Basic tier's retirement, Standard differs in a way
# that matters here: it is CLOSED by default. A Basic load balancer permitted
# inbound traffic unless an NSG denied it; a Standard one permits nothing
# unless an NSG allows it. The tier NSGs from module 8 are what make this
# work — without the AzureLoadBalancer probe rule, every backend reports
# unhealthy.
################################################################################

resource "azurerm_lb" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku      = "Standard"
  sku_tier = "Regional"

  frontend_ip_configuration {
    name = local.frontend_name

    # Internal
    subnet_id                     = local.is_internal ? var.subnet_id : null
    private_ip_address            = local.is_internal ? var.private_ip_address : null
    private_ip_address_allocation = local.is_internal ? (var.private_ip_address != null ? "Static" : "Dynamic") : null

    # Public
    public_ip_address_id = local.is_public ? azurerm_public_ip.this[0].id : null

    zones = var.zones
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !local.internal_missing_subnet
      error_message = "An internal load balancer requires subnet_id."
    }

    precondition {
      condition     = !local.public_with_subnet
      error_message = "A public load balancer takes a public IP, not a subnet. subnet_id must be null."
    }

    precondition {
      condition     = !local.public_missing_ip_name
      error_message = "A public load balancer requires public_ip_name so the module can create its frontend address."
    }

    precondition {
      condition     = !local.internal_with_ip_name
      error_message = "An internal load balancer has no public IP. public_ip_name must be null."
    }

    precondition {
      condition     = length(local.unknown_probes) == 0
      error_message = "Rules reference probes that do not exist: ${join(", ", local.unknown_probes)}. Defined probes: ${join(", ", sort(keys(var.probes)))}."
    }

    precondition {
      condition     = length(local.unknown_pools) == 0
      error_message = "Rules reference backend pools that do not exist: ${join(", ", local.unknown_pools)}. Defined pools: ${join(", ", sort(var.backend_pools))}."
    }
  }
}

################################################################################
# Backend pools
#
# Created empty. A scale set attaches ITSELF to a pool by ID, rather than the
# pool enumerating its members — which is what allows instances to come and go
# during a rolling upgrade without a Terraform change.
################################################################################

resource "azurerm_lb_backend_address_pool" "this" {
  for_each = toset(var.backend_pools)

  name            = each.value
  loadbalancer_id = azurerm_lb.this.id
}

################################################################################
# Probes
#
# The probe decides which instances receive traffic, and its thresholds decide
# how long a dead one keeps receiving it. interval x threshold is the detection
# window.
################################################################################

resource "azurerm_lb_probe" "this" {
  for_each = var.probes

  name            = each.key
  loadbalancer_id = azurerm_lb.this.id

  protocol            = each.value.protocol
  port                = each.value.port
  request_path        = each.value.request_path
  interval_in_seconds = each.value.interval_in_seconds
  probe_threshold     = each.value.probe_threshold
}

################################################################################
# Rules
#
# floating_ip_enabled and tcp_reset_enabled are the current argument names;
# enable_floating_ip and enable_tcp_reset are deprecated in azurerm 4.x.
#
# tcp_reset_enabled defaults true here: without it, an idle-timed-out flow is
# dropped silently and the client blocks until its own timeout. With it, the
# client receives a RST and fails fast.
################################################################################

resource "azurerm_lb_rule" "this" {
  for_each = var.rules

  name            = each.key
  loadbalancer_id = azurerm_lb.this.id

  frontend_ip_configuration_name = local.frontend_name
  protocol                       = each.value.protocol
  frontend_port                  = each.value.frontend_port
  backend_port                   = each.value.backend_port

  backend_address_pool_ids = [azurerm_lb_backend_address_pool.this[each.value.backend_pool_name].id]
  probe_id                 = azurerm_lb_probe.this[each.value.probe_name].id

  idle_timeout_in_minutes = each.value.idle_timeout_in_minutes
  load_distribution       = each.value.load_distribution
  floating_ip_enabled     = each.value.floating_ip_enabled
  tcp_reset_enabled       = each.value.tcp_reset_enabled

  # Only meaningful on a public load balancer. Disabling it prevents a second,
  # undeclared egress path competing with the NAT Gateway.
  disable_outbound_snat = local.is_public ? var.disable_outbound_snat : null
}
