################################################################################
# Placement
################################################################################

variable "resource_group_name" {
  description = "Resource group for the network security groups. Should be the \"net\" lifecycle scope."
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

################################################################################
# Network security groups and rules
################################################################################

variable "network_security_groups" {
  description = <<-EOT
    Map of NSG name to its configuration.

      subnet_id  Subnet to associate the NSG with. Azure permits at most ONE
                 NSG per subnet, so two entries pointing at the same subnet is
                 a configuration error, not a merge.

      rules      Map of rule name to rule. Keyed by name so that adding a rule
                 does not re-index the others in plan output — which matters
                 when the diff being reviewed is a firewall change.

    Ports and addresses each accept a singular or a plural form. Supplying both
    forms for the same field is rejected: Azure ignores one of them silently,
    and which one it ignores is not obvious.
  EOT

  type = map(object({
    subnet_id        = optional(string)
    attach_to_subnet = optional(bool, true)

    rules = map(object({
      priority    = number
      direction   = string
      access      = string
      protocol    = string
      description = optional(string)

      source_port_range  = optional(string, "*")
      source_port_ranges = optional(list(string))

      destination_port_range  = optional(string)
      destination_port_ranges = optional(list(string))

      source_address_prefix   = optional(string)
      source_address_prefixes = optional(list(string))

      destination_address_prefix   = optional(string, "*")
      destination_address_prefixes = optional(list(string))
    }))
  }))

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) : rule.priority >= 100 && rule.priority <= 4096
      ]
    ]))
    error_message = "Rule priorities must be between 100 and 4096. Priorities 65000-65500 are reserved for Azure's built-in default rules and cannot be used."
  }

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) : contains(["Inbound", "Outbound"], rule.direction)
      ]
    ]))
    error_message = "Rule direction must be Inbound or Outbound."
  }

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) : contains(["Allow", "Deny"], rule.access)
      ]
    ]))
    error_message = "Rule access must be Allow or Deny."
  }

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) : contains(["Tcp", "Udp", "Icmp", "Esp", "Ah", "*"], rule.protocol)
      ]
    ]))
    error_message = "Rule protocol must be one of: Tcp, Udp, Icmp, Esp, Ah, *."
  }

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) :
        (rule.destination_port_range != null) != (rule.destination_port_ranges != null)
      ]
    ]))
    error_message = "Each rule must set exactly one of destination_port_range or destination_port_ranges, never both and never neither."
  }

  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) :
        (rule.source_address_prefix != null) != (rule.source_address_prefixes != null)
      ]
    ]))
    error_message = "Each rule must set exactly one of source_address_prefix or source_address_prefixes."
  }

  # Azure caps rule descriptions at 140 characters. Exceeding it fails at apply
  # with an error naming the rule but not the limit, after the plan has already
  # been approved.
  validation {
    condition = alltrue(flatten([
      for nsg in values(var.network_security_groups) : [
        for rule in values(nsg.rules) :
        # try(), not coalesce(rule.description, ""). coalesce returns the first
        # non-null, NON-EMPTY argument, so coalesce(null, "") has nothing valid
        # to return and fails outright — and because `||` does not reliably
        # short-circuit, that ran for every rule whose description was null.
        # description is optional, so this rejected the ordinary case: on
        # Terraform 1.9.8, which CI pins, any rule without a description made
        # the whole module fail to evaluate.
        rule.description == null || try(length(rule.description), 0) <= 140
      ]
    ]))
    error_message = "Security rule descriptions are limited to 140 characters by Azure."
  }
}

################################################################################
# Default-deny enforcement
#
# Azure's built-in rule AllowVnetInBound (priority 65000) permits ALL traffic
# from any VNet address to any VNet address, on every port. An NSG containing
# only Allow rules therefore provides NO isolation between tiers — the built-in
# rule catches everything the explicit rules did not, and every subnet can
# reach every other subnet.
#
# A three-tier architecture without an explicit inbound deny is a diagram, not
# a boundary. This is enforced rather than documented.
################################################################################

variable "require_explicit_inbound_deny" {
  description = "Require every NSG to carry an explicit inbound Deny rule. Azure's built-in AllowVnetInBound rule at priority 65000 permits all intra-VNet traffic, so without a lower-priority deny an NSG with only Allow rules enforces nothing between tiers. Disable only for an NSG deliberately intended to be permissive."
  type        = bool
  default     = true
}
