################################################################################
# CIDR arithmetic
#
# Terraform has no built-in CIDR overlap function, so ranges are converted to
# integers and compared numerically.
#
# This matters more than it looks. Azure accepts overlapping subnet definitions
# in some orders and rejects them in others, and a subnet that overlaps another
# cannot be corrected in place — it must be emptied and rebuilt. Catching it at
# plan time costs milliseconds; catching it after deployment costs a rebuild of
# everything in the subnet.
################################################################################

locals {
  # Dotted quad to integer: 10.10.4.0 -> 168428032
  subnet_bounds = {
    for key, subnet in var.subnets :
    key => {
      cidr   = subnet.cidr
      prefix = tonumber(split("/", subnet.cidr)[1])
      start  = sum([for i, octet in split(".", cidrhost(subnet.cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
      end = sum([
        for i, octet in split(".", cidrhost(subnet.cidr, pow(2, 32 - tonumber(split("/", subnet.cidr)[1])) - 1)) :
        tonumber(octet) * pow(256, 3 - i)
      ])
    }
  }

  vnet_bounds = [
    for cidr in var.address_space : {
      cidr  = cidr
      start = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
      end = sum([
        for i, octet in split(".", cidrhost(cidr, pow(2, 32 - tonumber(split("/", cidr)[1])) - 1)) :
        tonumber(octet) * pow(256, 3 - i)
      ])
    }
  ]

  # Pairs are compared by INDEX into a sorted key list, not by key. Terraform's
  # < operator is numeric only and rejects string operands, so comparing keys
  # directly fails at plan time. Indices also guarantee each unordered pair is
  # considered exactly once.
  subnet_keys = sort(keys(var.subnets))

  overlapping_subnets = sort([
    for pair in setproduct(range(length(local.subnet_keys)), range(length(local.subnet_keys))) :
    format(
      "%s (%s) overlaps %s (%s)",
      local.subnet_keys[pair[0]], local.subnet_bounds[local.subnet_keys[pair[0]]].cidr,
      local.subnet_keys[pair[1]], local.subnet_bounds[local.subnet_keys[pair[1]]].cidr
    )
    if pair[0] < pair[1]
    && local.subnet_bounds[local.subnet_keys[pair[0]]].start <= local.subnet_bounds[local.subnet_keys[pair[1]]].end
    && local.subnet_bounds[local.subnet_keys[pair[1]]].start <= local.subnet_bounds[local.subnet_keys[pair[0]]].end
  ])

  subnets_outside_address_space = sort([
    for key, bounds in local.subnet_bounds :
    "${key} (${bounds.cidr})"
    if !anytrue([for v in local.vnet_bounds : bounds.start >= v.start && bounds.end <= v.end])
  ])
}

################################################################################
# Azure-reserved subnets
#
# These names are fixed by the platform and carry minimum sizes. A smaller
# prefix is accepted at create time by some API versions and then fails when
# the service is deployed into it, which is a confusing failure to diagnose
# because the error names the service, not the subnet.
#
# Remember Azure reserves 5 addresses in every subnet, so a /26 yields 59
# usable addresses, not 64.
################################################################################

locals {
  reserved_subnet_min_prefix = {
    AzureFirewallSubnet           = 26
    AzureFirewallManagementSubnet = 26
    AzureBastionSubnet            = 26
    GatewaySubnet                 = 27
    RouteServerSubnet             = 27
  }

  undersized_reserved_subnets = sort([
    for key, bounds in local.subnet_bounds :
    "${key} is /${bounds.prefix} but requires /${local.reserved_subnet_min_prefix[key]} or larger"
    if contains(keys(local.reserved_subnet_min_prefix), key)
    && bounds.prefix > local.reserved_subnet_min_prefix[key]
  ])

  # NAT Gateway association is not supported on these. Azure Bastion and Azure
  # Firewall each manage their own outbound path; associating a NAT Gateway
  # either fails or silently breaks the service.
  nat_incompatible_subnets = ["AzureBastionSubnet", "AzureFirewallSubnet", "AzureFirewallManagementSubnet", "GatewaySubnet"]

  invalid_nat_associations = sort([
    for key, subnet in var.subnets : key
    if subnet.associate_nat_gateway && contains(local.nat_incompatible_subnets, key)
  ])
}

################################################################################
# NAT Gateway associations
################################################################################

locals {
  nat_associated_subnets = var.enable_nat_gateway ? {
    for key, subnet in var.subnets : key => subnet
    if subnet.associate_nat_gateway
  } : {}

  # Subnets asking for NAT egress when no NAT Gateway is being created would
  # silently have no egress at all, since default outbound access is retired.
  orphaned_nat_requests = sort([
    for key, subnet in var.subnets : key
    if subnet.associate_nat_gateway && !var.enable_nat_gateway
  ])
}
