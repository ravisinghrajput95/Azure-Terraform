################################################################################
# Placement
################################################################################

variable "name" {
  description = "Load balancer name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"app\" lifecycle scope — a load balancer is deployed with the application, not with the network edge."
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
# Type
#
# One module serves both roles because the resource shape is identical apart
# from the frontend: an internal load balancer takes a subnet and a private
# address, a public one takes a public IP.
#
#   internal   Fronts the business tier. Never reachable from outside the VNet.
#
#   public     Provides ingress where Application Gateway is not deployed —
#              dev, because AppGW has no inexpensive tier. A public load
#              balancer is a layer 4 device: it does NOT terminate TLS, inspect
#              requests, or provide a WAF. It forwards. That difference is the
#              reason test and prod use Application Gateway instead.
################################################################################

variable "type" {
  description = "\"internal\" or \"public\"."
  type        = string

  validation {
    condition     = contains(["internal", "public"], var.type)
    error_message = "type must be \"internal\" or \"public\"."
  }
}

variable "subnet_id" {
  description = "Subnet for the frontend. Required for an internal load balancer, and must be null for a public one."
  type        = string
  default     = null
}

variable "private_ip_address" {
  description = "Static private address for an internal frontend. Null uses dynamic allocation, which is fine — the address is discovered through the private DNS zone or the output, not hardcoded by clients."
  type        = string
  default     = null
}

variable "public_ip_name" {
  description = "Name for the public IP, created by this module for a public load balancer."
  type        = string
  default     = null
}

variable "zones" {
  description = "Availability zones for the frontend. A zone-redundant frontend survives a zone outage; a zonal one does not. Empty means no zone preference, which for a Standard load balancer means zone-redundant by default."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for zone in var.zones : contains(["1", "2", "3"], zone)])
    error_message = "zones must contain only \"1\", \"2\" or \"3\"."
  }
}

################################################################################
# Backend pools, probes and rules
################################################################################

variable "backend_pools" {
  description = "Backend pool names. A scale set attaches itself to these by ID rather than the pool listing its members, so the pool is created empty and populated by the vm module."
  type        = list(string)
  default     = ["default"]

  validation {
    condition     = length(var.backend_pools) > 0
    error_message = "At least one backend pool is required."
  }
}

variable "probes" {
  description = <<-EOT
    Map of probe name to configuration.

    A probe is what decides whether an instance receives traffic. Two things
    are worth getting right:

      protocol      "Http" or "Https" with a request_path checks the
                    APPLICATION. "Tcp" only checks that the port accepts a
                    connection, which a hung process will happily continue to
                    do — so a TCP probe reports healthy while every request
                    times out.

      thresholds    interval_in_seconds x probe_threshold is how long a dead
                    instance keeps receiving traffic. The default 5s x 2 = 10s.
  EOT

  type = map(object({
    protocol            = optional(string, "Tcp")
    port                = number
    request_path        = optional(string)
    interval_in_seconds = optional(number, 5)
    probe_threshold     = optional(number, 2)
  }))
  default = {}

  validation {
    condition = alltrue([
      for probe in values(var.probes) : contains(["Tcp", "Http", "Https"], probe.protocol)
    ])
    error_message = "Probe protocol must be Tcp, Http or Https."
  }

  # Azure rejects an HTTP probe without a path, and ignores a path on a TCP
  # probe — so a TCP probe with a path reads as an application health check
  # and is not one.
  validation {
    condition = alltrue([
      for probe in values(var.probes) :
      contains(["Http", "Https"], probe.protocol) == (probe.request_path != null)
    ])
    error_message = "request_path is required for an Http or Https probe and must be null for a Tcp probe. A path on a TCP probe is silently ignored, which makes the probe look like an application health check when it only tests that the port is open."
  }

  validation {
    condition     = alltrue([for probe in values(var.probes) : probe.interval_in_seconds >= 5])
    error_message = "interval_in_seconds must be at least 5."
  }
}

variable "rules" {
  description = "Map of rule name to configuration. Each rule binds a frontend port to a backend port, a pool and a probe."
  type = map(object({
    protocol                = optional(string, "Tcp")
    frontend_port           = number
    backend_port            = number
    backend_pool_name       = optional(string, "default")
    probe_name              = string
    idle_timeout_in_minutes = optional(number, 4)
    load_distribution       = optional(string, "Default")
    floating_ip_enabled     = optional(bool, false)
    tcp_reset_enabled       = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for rule in values(var.rules) : contains(["Tcp", "Udp", "All"], rule.protocol)])
    error_message = "Rule protocol must be Tcp, Udp or All."
  }

  validation {
    condition = alltrue([
      for rule in values(var.rules) :
      contains(["Default", "SourceIP", "SourceIPProtocol"], rule.load_distribution)
    ])
    error_message = "load_distribution must be Default (five-tuple), SourceIP (two-tuple) or SourceIPProtocol (three-tuple)."
  }
}

################################################################################
# Outbound
################################################################################

variable "disable_outbound_snat" {
  description = <<-EOT
    Whether load balancing rules perform outbound SNAT.

    TRUE here, deliberately. This platform provides egress through a NAT
    Gateway attached to the subnet, and a NAT Gateway takes precedence over
    load balancer outbound SNAT anyway. Leaving LB SNAT enabled creates a
    second, undeclared egress path that is invisible in the route table and
    competes for a much smaller SNAT port allocation — the usual cause of
    intermittent outbound connection failures under load.
  EOT
  type        = bool
  default     = true
}
