################################################################################
# Virtual network
#
# The VNet declares address space ONLY. Subnets are separate azurerm_subnet
# resources.
#
# azurerm_virtual_network also accepts an inline `subnet` block. Using both
# forms produces permanent drift: the inline block treats subnets it does not
# list as removable, so each apply deletes the subnets the other form created,
# and the next apply recreates them. It is one of the most common causes of a
# Terraform configuration that never reaches a clean plan.
################################################################################

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  dns_servers         = var.dns_servers

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.overlapping_subnets) == 0
      error_message = join("\n", concat(
        ["Subnet address ranges overlap. Azure cannot resize a subnet that contains resources, so this must be corrected before deployment:"],
        local.overlapping_subnets
      ))
    }

    precondition {
      condition = length(local.subnets_outside_address_space) == 0
      error_message = join("\n", concat(
        ["These subnets fall outside the VNet address space ${join(", ", var.address_space)}:"],
        local.subnets_outside_address_space
      ))
    }

    precondition {
      condition = length(local.undersized_reserved_subnets) == 0
      error_message = join("\n", concat(
        ["Azure-reserved subnets below their minimum size. The service deployed into them will fail with an error naming the service, not the subnet:"],
        local.undersized_reserved_subnets
      ))
    }
  }
}

################################################################################
# Subnets
#
# for_each over the subnet map, keyed by name. With count, removing one subnet
# re-indexes every subnet after it and Terraform plans to destroy and recreate
# unrelated subnets — which fails anyway, because a subnet containing resources
# cannot be deleted.
################################################################################

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.cidr]

  service_endpoints = each.value.service_endpoints

  # Historically NSGs were ignored on subnets holding private endpoints. This
  # setting controls that; leaving it "Disabled" on the private endpoint subnet
  # means the NSG rules written for it are silently never enforced.
  private_endpoint_network_policies = each.value.private_endpoint_network_policies

  private_link_service_network_policies_enabled = each.value.private_link_service_network_policies_enabled

  # Azure retired default outbound access on 30 September 2025. Setting this
  # false explicitly means the platform never silently depends on implicit
  # egress: a subnet either has a NAT Gateway, a firewall route, or no internet
  # access at all — and which one is visible in configuration.
  default_outbound_access_enabled = each.value.default_outbound_access_enabled

  dynamic "delegation" {
    for_each = each.value.delegation != null ? [each.value.delegation] : []

    content {
      name = delegation.value.name

      service_delegation {
        name    = delegation.value.service_name
        actions = delegation.value.actions
      }
    }
  }

  lifecycle {
    precondition {
      condition = length(local.invalid_nat_associations) == 0
      error_message = join(" ", [
        "NAT Gateway association requested on subnets that do not support it:",
        "${join(", ", local.invalid_nat_associations)}.",
        "Azure Bastion and Azure Firewall manage their own outbound path; associating a NAT Gateway either fails or breaks the service."
      ])
    }

    precondition {
      condition = length(local.orphaned_nat_requests) == 0
      error_message = join(" ", [
        "These subnets request NAT Gateway egress but enable_nat_gateway is false:",
        "${join(", ", local.orphaned_nat_requests)}.",
        "Since default outbound access was retired, they would have no internet egress at all."
      ])
    }
  }
}

################################################################################
# NAT Gateway public IP
#
# Standard SKU and Static allocation are the only valid combination here. The
# Basic SKU public IP was retired on 30 September 2025 and cannot be created,
# so the historical "use Basic in dev to save money" option no longer exists.
#
# Each public IP provides 64,512 SNAT ports. A single IP is ample for this
# platform; a public IP prefix would be the answer to port exhaustion at scale.
################################################################################

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = var.nat_gateway_public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location

  allocation_method = "Static"
  sku               = "Standard"
  zones             = var.nat_gateway_zones

  tags = var.tags
}

################################################################################
# NAT Gateway
#
# Provides outbound-only connectivity: it does not accept inbound flows, which
# is exactly what a workload subnet with no public IPs needs.
#
# A NAT Gateway is ZONAL, not zone-redundant. It occupies one zone, and a zone
# outage takes egress with it. Zone-resilient egress needs one gateway per
# zone with subnets pinned accordingly, or Azure Firewall, which is
# zone-redundant. Left regional here — for dev, a zone outage is not the risk
# being managed.
################################################################################

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = var.nat_gateway_name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku_name                = "Standard"
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout_in_minutes
  zones                   = var.nat_gateway_zones

  tags = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

################################################################################
# Subnet associations
#
# A NAT Gateway takes precedence over the subnet's default outbound path but is
# overridden by a UDR pointing at a firewall. That ordering is why the profile
# module treats firewall and NAT Gateway as mutually exclusive: running both
# means paying for a NAT Gateway that never carries traffic.
################################################################################

resource "azurerm_subnet_nat_gateway_association" "this" {
  for_each = local.nat_associated_subnets

  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id

  # The public IP must be attached before subnets are associated, or outbound
  # flows briefly have no SNAT address.
  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}
