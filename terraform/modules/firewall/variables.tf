################################################################################
# Placement
################################################################################

variable "name" {
  description = "Firewall name, from naming.names.firewall."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"net\" lifecycle scope — the firewall is network edge, and must outlive the application stacks that route through it."
  type        = string
}

variable "location" {
  description = "Azure region. Must match the VNet holding AzureFirewallSubnet."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# SKU
################################################################################

variable "sku_tier" {
  description = <<-EOT
    Firewall tier.

      "Basic"     Small-scale. Throughput is capped and it REQUIRES a
                  management subnet and a second public IP.
      "Standard"  L3-L7 filtering, FQDN rules, threat intelligence.
      "Premium"   Adds IDPS and TLS inspection. Roughly $365/month more than
                  Standard, and the only tier where `intrusion_detection` does
                  anything.

    This is a cost decision before it is a capability one — see README.md.
  EOT
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Basic, Standard or Premium."
  }
}

variable "sku_name" {
  description = "Deployment model. AZFW_VNet is a firewall in your own VNet; AZFW_Hub is a Virtual WAN secured hub, which this module does not wire."
  type        = string
  default     = "AZFW_VNet"

  validation {
    condition     = contains(["AZFW_VNet", "AZFW_Hub"], var.sku_name)
    error_message = "sku_name must be AZFW_VNet or AZFW_Hub."
  }
}

variable "zones" {
  description = <<-EOT
    Availability zones for the firewall.

    The zones themselves cost nothing. CROSS-ZONE DATA TRANSFER IS BILLED, and
    every byte a workload in zone 1 sends through a firewall instance in zone 2
    crosses a zone. A zone-redundant firewall is the correct choice for
    production and is not free in practice.

    A single zone provides no redundancy and is reported as such rather than
    reading like a zonal deployment.
  EOT
  type        = list(string)
  default     = []
}

################################################################################
# Network placement
################################################################################

variable "subnet_id" {
  description = "ID of the firewall subnet. Azure requires it to be named EXACTLY \"AzureFirewallSubnet\" and to be /26 or larger; a precondition checks the name, because the API error names the firewall rather than the subnet."
  type        = string
}

variable "public_ip_name" {
  description = "Name of the firewall's data-plane public IP, which this module creates. Azure requires Standard SKU with Static allocation and rejects anything else with an error that does not name the offending property, so neither is an input."
  type        = string
}

variable "management_subnet_id" {
  description = "ID of the management subnet, named EXACTLY \"AzureFirewallManagementSubnet\". REQUIRED for the Basic tier and for forced tunnelling; null otherwise."
  type        = string
  default     = null
}

variable "management_public_ip_name" {
  description = "Name of the management public IP, created by this module whenever management_subnet_id is set. Derived from the firewall name when omitted — the management plane needs its own address and cannot share the data-plane IP, so this is not a thing to be able to forget."
  type        = string
  default     = null
}

################################################################################
# DNS
################################################################################

variable "dns_proxy_enabled" {
  description = <<-EOT
    Whether the firewall acts as a DNS proxy.

    NOT optional if any NETWORK rule uses `destination_fqdns`. An FQDN in a
    network rule is resolved by the firewall itself, and without the proxy
    there is nothing to resolve it — the rule is accepted, displays correctly,
    and matches no traffic. A precondition rejects that combination.

    Application rules resolve FQDNs differently and do not need this.
  EOT
  type        = bool
  default     = false
}

variable "dns_servers" {
  description = "Custom DNS servers the firewall forwards to. Empty uses Azure-provided DNS."
  type        = list(string)
  default     = []
}

################################################################################
# Threat intelligence and IDPS
################################################################################

variable "threat_intelligence_mode" {
  description = <<-EOT
    Threat intelligence behaviour.

      "Deny"  Blocks traffic to and from known-malicious addresses.
      "Alert" LOGS it and lets it through. Protection is off; the alerts make
              it look on.
      "Off"   Disabled entirely.

    "Alert" is the deceptive value: the feature reports as enabled and blocks
    nothing.
  EOT
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Off", "Alert", "Deny"], var.threat_intelligence_mode)
    error_message = "threat_intelligence_mode must be Off, Alert or Deny."
  }
}

variable "intrusion_detection_mode" {
  description = <<-EOT
    IDPS mode. PREMIUM TIER ONLY.

      null    Not configured.
      "Off"   Configured and doing nothing.
      "Alert" Signature matches are logged and ALLOWED THROUGH.
      "Deny"  Signature matches are blocked.

    Setting this on a Standard or Basic firewall is rejected by a precondition:
    IDPS is a Premium capability, and a configuration that names it on a
    cheaper tier reads as intrusion prevention that does not exist.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.intrusion_detection_mode == null || contains(["Off", "Alert", "Deny"], coalesce(var.intrusion_detection_mode, "Off"))
    error_message = "intrusion_detection_mode must be Off, Alert, Deny or null."
  }
}

################################################################################
# SNAT
################################################################################

variable "private_ip_ranges" {
  description = <<-EOT
    Address ranges the firewall treats as INTERNAL and therefore does not SNAT.

    Azure's default is the RFC1918 ranges. If the estate uses private
    addressing outside RFC1918 — 100.64.0.0/10 shared address space is the
    common case — traffic to it IS SNATed to the firewall's own address, the
    return path goes somewhere else, and the connection hangs rather than
    failing cleanly.

    Empty leaves the Azure default in place.
  EOT
  type        = list(string)
  default     = []
}

################################################################################
# Rules
#
# One policy, one rule collection group. Rule collections are ordered by
# priority WITHIN their type, but the TYPES are ordered by Azure and cannot be
# reordered: NAT, then network, then application. That ordering is the source
# of this module's most important precondition — see locals.tf.
################################################################################

variable "rule_collection_group_priority" {
  description = "Priority of the rule collection group. Lower evaluates first. Only meaningful when a policy carries several groups."
  type        = number
  default     = 1000

  validation {
    condition     = var.rule_collection_group_priority >= 100 && var.rule_collection_group_priority <= 65000
    error_message = "Priority must be between 100 and 65000."
  }
}

variable "network_rule_collections" {
  description = <<-EOT
    Network (L3/L4) rule collections, keyed by name.

    Evaluated BEFORE every application rule, regardless of priority. A broad
    Allow here silently disables FQDN filtering below it.
  EOT
  type = map(object({
    priority = number
    action   = optional(string, "Allow")
    rules = map(object({
      protocols             = list(string)
      source_addresses      = optional(list(string), [])
      source_ip_groups      = optional(list(string), [])
      destination_addresses = optional(list(string), [])
      destination_fqdns     = optional(list(string), [])
      destination_ip_groups = optional(list(string), [])
      destination_ports     = list(string)
      description           = optional(string)
    }))
  }))
  default = {}
}

variable "application_rule_collections" {
  description = "Application (L7 / FQDN) rule collections, keyed by name. Evaluated only for traffic no network rule already matched."
  type = map(object({
    priority = number
    action   = optional(string, "Allow")
    rules = map(object({
      protocols = map(object({
        type = string
        port = number
      }))
      source_addresses      = optional(list(string), [])
      source_ip_groups      = optional(list(string), [])
      destination_fqdns     = optional(list(string), [])
      destination_fqdn_tags = optional(list(string), [])
      destination_urls      = optional(list(string), [])
      web_categories        = optional(list(string), [])
      terminate_tls         = optional(bool, false)
      description           = optional(string)
    }))
  }))
  default = {}
}

variable "nat_rule_collections" {
  description = "DNAT rule collections, keyed by name. Evaluated before everything else. Inbound publishing only — this platform fronts ingress with Application Gateway instead."
  type = map(object({
    priority = number
    rules = map(object({
      protocols          = list(string)
      source_addresses   = optional(list(string), [])
      source_ip_groups   = optional(list(string), [])
      destination_ports  = optional(list(string), [])
      translated_port    = number
      translated_address = optional(string)
      translated_fqdn    = optional(string)
      description        = optional(string)
    }))
  }))
  default = {}
}

################################################################################
# Acknowledgements
#
# Two configurations that are legitimate and dangerous. Each is permitted only
# when the caller says so explicitly, because the failure is severe and the
# configuration looks complete.
################################################################################

variable "acknowledge_no_rules" {
  description = <<-EOT
    Permit deploying a firewall with NO rule collections at all.

    An Azure Firewall denies by default. Once a route table sends 0.0.0.0/0 to
    it, a firewall with no rules blackholes ALL egress — no DNS, no package
    repositories, no container registries. AKS nodes fail to bootstrap and the
    cluster never converges, while the firewall itself reports healthy and the
    portal shows a correctly provisioned resource.

    Legitimate as a first step when rules land in a later apply. Set it
    knowingly.
  EOT
  type        = bool
  default     = false
}

variable "acknowledge_broad_network_allow" {
  description = <<-EOT
    Permit a broad Allow network rule to coexist with application rules.

    Azure evaluates ALL network rules before ANY application rule. A network
    rule allowing 0.0.0.0/0 on 80/443 therefore matches web traffic first, and
    every FQDN-filtering application rule beneath it never evaluates. The
    application rules remain visible, correct-looking and completely inert.

    Set this only where the broad rule is deliberate and the application rules
    are understood to be unreachable for those ports.
  EOT
  type        = bool
  default     = false
}
