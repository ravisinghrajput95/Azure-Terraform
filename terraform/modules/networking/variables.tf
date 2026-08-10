################################################################################
# Virtual network
################################################################################

variable "vnet_name" {
  description = "Virtual network name, from naming.names.virtual_network."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the network. Should be the \"net\" lifecycle scope, so the identity that redeploys the application cannot delete the network edge."
  type        = string
}

variable "location" {
  description = "Azure region, normalised form."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

variable "address_space" {
  description = "VNet address space. One non-overlapping /16 per environment — see docs/NETWORKING.md. Ranges are spaced so a future peering, VPN or ExpressRoute link cannot collide, which is the one networking mistake that cannot be fixed without rebuilding every resource in the subnet."
  type        = list(string)

  validation {
    condition     = length(var.address_space) > 0
    error_message = "address_space must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for cidr in var.address_space : can(cidrhost(cidr, 0))])
    error_message = "Every entry in address_space must be a valid CIDR block, e.g. \"10.10.0.0/16\"."
  }
}

variable "dns_servers" {
  description = "Custom DNS servers for the VNet. Leave empty to use Azure-provided DNS, which is required for private endpoint resolution via private DNS zones. Setting custom servers without forwarding to 168.63.129.16 breaks private endpoint name resolution."
  type        = list(string)
  default     = []
}

################################################################################
# Subnets
################################################################################

variable "subnets" {
  description = <<-EOT
    Map of subnet key to configuration. The key is used for output lookup and
    for_each addressing, so it must be stable — renaming a key destroys and
    recreates the subnet.

    Azure reserves specific subnet NAMES with fixed minimum sizes:
    AzureFirewallSubnet (/26), AzureFirewallManagementSubnet (/26),
    AzureBastionSubnet (/26) and GatewaySubnet (/27, /26 recommended). Those
    names must be exact; the module validates their sizes.

    Fields:
      cidr                              Address prefix, must sit inside address_space
      service_endpoints                 e.g. ["Microsoft.Storage"]
      private_endpoint_network_policies "Disabled", "Enabled",
                                        "NetworkSecurityGroupEnabled" or
                                        "RouteTableEnabled". Must not be
                                        "Disabled" on the private endpoint
                                        subnet if NSG rules are expected to
                                        apply to it.
      associate_nat_gateway             Route this subnet's egress via the NAT
                                        Gateway. Unsupported on
                                        AzureBastionSubnet and
                                        AzureFirewallSubnet.
      default_outbound_access_enabled   Implicit outbound internet access.
                                        Retired by Azure on 30 September 2025;
                                        left false so the platform never relies
                                        on it.
      delegation                        Optional service delegation.
  EOT

  type = map(object({
    cidr                                          = string
    service_endpoints                             = optional(list(string), [])
    private_endpoint_network_policies             = optional(string, "Enabled")
    private_link_service_network_policies_enabled = optional(bool, true)
    associate_nat_gateway                         = optional(bool, false)
    default_outbound_access_enabled               = optional(bool, false)
    delegation = optional(object({
      name         = string
      service_name = string
      actions      = optional(list(string), [])
    }), null)
  }))

  validation {
    condition     = length(var.subnets) > 0
    error_message = "At least one subnet must be defined."
  }

  validation {
    condition     = alltrue([for s in values(var.subnets) : can(cidrhost(s.cidr, 0))])
    error_message = "Every subnet cidr must be a valid CIDR block."
  }

  validation {
    condition = alltrue([
      for s in values(var.subnets) :
      contains(["Disabled", "Enabled", "NetworkSecurityGroupEnabled", "RouteTableEnabled"], s.private_endpoint_network_policies)
    ])
    error_message = "private_endpoint_network_policies must be one of: Disabled, Enabled, NetworkSecurityGroupEnabled, RouteTableEnabled."
  }
}

################################################################################
# NAT Gateway
#
# The egress path when Azure Firewall is not deployed. Not optional decoration:
# Azure retired default outbound access on 30 September 2025, so a subnet with
# no explicit egress resource has no internet connectivity at all — package
# installs, agent enrolment and certificate revocation checks all fail.
################################################################################

variable "enable_nat_gateway" {
  description = "Deploy a NAT Gateway for outbound connectivity. Pass the profile module's enable_nat_gateway. Roughly $33/month plus $0.045/GB processed, against roughly $912/month for Azure Firewall."
  type        = bool
  default     = false
}

variable "nat_gateway_name" {
  description = "NAT Gateway name, from naming.names.nat_gateway."
  type        = string
  default     = null
}

variable "nat_gateway_public_ip_name" {
  description = "Name for the NAT Gateway's public IP."
  type        = string
  default     = null
}

variable "nat_gateway_zones" {
  description = "Availability zone to pin the NAT Gateway to. A NAT Gateway is ZONAL, not zone-redundant — it lives in exactly one zone, and a zone outage takes egress with it. Leave empty for a regional (non-zonal) deployment. For zone-resilient egress, deploy one NAT Gateway per zone with separate subnets, or use Azure Firewall, which is zone-redundant."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.nat_gateway_zones) <= 1
    error_message = "A NAT Gateway can occupy at most one zone. Zone-resilient egress requires one gateway per zone, each associated with subnets in that zone."
  }
}

variable "nat_gateway_idle_timeout_in_minutes" {
  description = "Idle timeout for outbound flows, 4-120 minutes. Raising it holds SNAT ports longer, which reduces port exhaustion for long-lived connections but increases it for high-churn short connections."
  type        = number
  default     = 4

  validation {
    condition     = var.nat_gateway_idle_timeout_in_minutes >= 4 && var.nat_gateway_idle_timeout_in_minutes <= 120
    error_message = "nat_gateway_idle_timeout_in_minutes must be between 4 and 120."
  }
}
