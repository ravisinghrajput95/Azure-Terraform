################################################################################
# Placement
################################################################################

variable "name" {
  description = "Application Gateway name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"app\" lifecycle scope."
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

variable "subnet_id" {
  description = <<-EOT
    Dedicated Application Gateway subnet.

    Two constraints that are not negotiable:

      - The subnet must contain NOTHING else. Azure rejects a gateway in a
        subnet holding other resource types.
      - Its NSG must allow inbound GatewayManager on 65200-65535. Without it
        the gateway provisions and then reports permanently unhealthy, and the
        error names the gateway rather than the missing rule.

    A 0.0.0.0/0 route to a firewall on this subnet also breaks it — AppGW v2
    requires direct control-plane access. The route-table module rejects that
    combination.
  EOT
  type        = string
}

################################################################################
# SKU and capacity
################################################################################

variable "sku_name" {
  description = "\"Standard_v2\" or \"WAF_v2\". Only v2 SKUs are offered: v1 is retired, and only v2 supports autoscaling, zone redundancy and Key Vault certificate references."
  type        = string
  default     = "WAF_v2"

  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.sku_name)
    error_message = "sku_name must be Standard_v2 or WAF_v2. The v1 SKUs are retired."
  }
}

variable "min_capacity" {
  description = "Minimum autoscale capacity units. Each unit handles roughly 10 Mbps of throughput and 50 connections per second. Zero is permitted but means a cold start on first request."
  type        = number
  default     = 2

  validation {
    condition     = var.min_capacity >= 0 && var.min_capacity <= 125
    error_message = "min_capacity must be between 0 and 125."
  }
}

variable "max_capacity" {
  description = "Maximum autoscale capacity units. This is the ceiling on ingress throughput — a gateway at max capacity queues and then sheds traffic while the backend sits idle, which reads as an application problem."
  type        = number
  default     = 10

  validation {
    condition     = var.max_capacity >= 2 && var.max_capacity <= 125
    error_message = "max_capacity must be between 2 and 125."
  }
}

variable "zones" {
  description = "Availability zones. Empty means the gateway is regional and a zone outage takes ingress with it. v2 SKUs support zones at no extra charge, so an empty list in production is almost always an oversight."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for zone in var.zones : contains(["1", "2", "3"], zone)])
    error_message = "zones must contain only \"1\", \"2\" or \"3\"."
  }
}

variable "public_ip_name" {
  description = "Name for the gateway's public IP."
  type        = string
}

variable "http2_enabled" {
  description = "Enable HTTP/2 for client connections. Note the gateway always speaks HTTP/1.1 to the backend regardless."
  type        = bool
  default     = true
}

################################################################################
# TLS
################################################################################

variable "ssl_certificate_key_vault_secret_id" {
  description = "Key Vault secret ID of the TLS certificate. Referencing the vault rather than embedding a PFX means the certificate is never in Terraform state and rotation is a vault operation, not a redeploy. Requires user_assigned_identity_id with Key Vault Secrets User on the vault."
  type        = string
  default     = null
}

variable "user_assigned_identity_id" {
  description = "User-assigned identity the gateway uses to read its certificate from Key Vault. Required whenever ssl_certificate_key_vault_secret_id is set."
  type        = string
  default     = null
}

variable "ssl_policy_name" {
  description = "Predefined SSL policy. AppGwSslPolicy20220101 requires TLS 1.2 minimum and a modern cipher set. The older policies permit TLS 1.0 and 1.1, which most compliance regimes reject."
  type        = string
  default     = "AppGwSslPolicy20220101"
}

################################################################################
# WAF
################################################################################

variable "waf_mode" {
  description = "\"Detection\" logs what would have been blocked; \"Prevention\" blocks it. Run Detection first in a lower environment and tune the exclusions — going straight to Prevention blocks legitimate traffic and teaches the team to distrust the WAF."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be Detection or Prevention."
  }
}

variable "waf_rule_set_type" {
  description = "\"OWASP\" is the classic CRS. \"Microsoft_DefaultRuleSet\" is Microsoft's managed set, which includes the OWASP rules plus Microsoft threat intelligence."
  type        = string
  default     = "OWASP"

  validation {
    condition     = contains(["OWASP", "Microsoft_DefaultRuleSet"], var.waf_rule_set_type)
    error_message = "waf_rule_set_type must be OWASP or Microsoft_DefaultRuleSet."
  }
}

variable "waf_rule_set_version" {
  description = "Rule set version. OWASP 3.2 is the current CRS; Microsoft_DefaultRuleSet uses 2.1."
  type        = string
  default     = "3.2"
}

variable "waf_request_body_check_enabled" {
  description = "Inspect request bodies. Disabling it makes the WAF blind to anything in a POST body, which is where injection payloads usually are."
  type        = bool
  default     = true
}

variable "waf_max_request_body_size_kb" {
  description = "Maximum request body the WAF will inspect, in KB. Bodies larger than this are passed through UNINSPECTED unless blocked outright, so raising it widens coverage and raising it too far costs latency."
  type        = number
  default     = 128
}

variable "waf_file_upload_limit_mb" {
  description = "Maximum file upload size in MB."
  type        = number
  default     = 100
}

variable "waf_exclusions" {
  description = "Rule exclusions, each { match_variable, selector_match_operator, selector }. Every exclusion is a hole in the WAF — record why in the configuration, and prefer disabling one rule ID over excluding a whole variable."
  type = list(object({
    match_variable          = string
    selector_match_operator = string
    selector                = string
  }))
  default = []
}

################################################################################
# Routing
################################################################################

variable "backend_pools" {
  description = "Map of pool name to { fqdns, ip_addresses }. Leave both empty for a pool a scale set attaches itself to."
  type = map(object({
    fqdns        = optional(list(string), [])
    ip_addresses = optional(list(string), [])
  }))
  default = { default = {} }
}

variable "backend_http_settings" {
  description = "Map of settings name to configuration. `probe_name` binds a health probe; without one the gateway uses a default probe against \"/\", which returns 404 on most applications and marks every backend unhealthy."
  type = map(object({
    port                                = number
    protocol                            = optional(string, "Https")
    cookie_based_affinity               = optional(string, "Disabled")
    request_timeout                     = optional(number, 30)
    probe_name                          = optional(string)
    host_name                           = optional(string)
    pick_host_name_from_backend_address = optional(bool, false)
  }))
  default = {}
}

variable "probes" {
  description = "Map of probe name to configuration. An Application Gateway probe checks the APPLICATION, unlike a layer 4 load balancer probe — `match_status_codes` is what makes it meaningful."
  type = map(object({
    protocol                                  = optional(string, "Https")
    path                                      = string
    interval                                  = optional(number, 30)
    timeout                                   = optional(number, 30)
    unhealthy_threshold                       = optional(number, 3)
    host                                      = optional(string)
    pick_host_name_from_backend_http_settings = optional(bool, true)
    match_status_codes                        = optional(list(string), ["200-399"])
  }))
  default = {}
}

variable "listeners" {
  description = "Map of listener name to { port, protocol, host_name, ssl_certificate_name }. An HTTPS listener requires a certificate."
  type = map(object({
    port                 = number
    protocol             = optional(string, "Https")
    host_name            = optional(string)
    ssl_certificate_name = optional(string)
  }))
  default = {}
}

variable "routing_rules" {
  description = "Map of rule name to configuration. Each binds a listener to either a backend (pool plus settings) or a redirect. Priority is required on v2 SKUs and must be unique."
  type = map(object({
    priority                    = number
    listener_name               = string
    backend_pool_name           = optional(string)
    backend_http_settings_name  = optional(string)
    redirect_configuration_name = optional(string)
  }))
  default = {}
}

variable "redirect_configurations" {
  description = "Map of redirect name to { target_listener_name, redirect_type }. The usual use is forcing HTTP to HTTPS, which is a routing rule rather than a setting."
  type = map(object({
    target_listener_name = string
    redirect_type        = optional(string, "Permanent")
    include_path         = optional(bool, true)
    include_query_string = optional(bool, true)
  }))
  default = {}
}
