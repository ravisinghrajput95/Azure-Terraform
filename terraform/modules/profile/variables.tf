################################################################################
# Environment selection
################################################################################

variable "environment" {
  description = "Environment whose profile to select. This is the ONLY place, alongside naming and tags, where an environment name appears. No downstream module may branch on it — they receive explicit capability flags instead. See README.md."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

################################################################################
# Overrides
#
# Every attribute is optional. Unset attributes fall through to the profile
# default. This is the escape hatch for the case the built-in profiles do not
# anticipate — raising dev's instance count after a quota increase, or dropping
# prod's firewall to Standard.
#
# It is typed rather than map(any) so that a typo in an attribute name fails at
# plan time instead of being silently ignored.
################################################################################

variable "overrides" {
  description = "Per-value overrides applied on top of the selected environment profile. Any attribute left unset keeps the profile default."
  type = object({
    # Egress
    enable_firewall    = optional(bool)
    firewall_sku_tier  = optional(string)
    enable_nat_gateway = optional(bool)

    # Ingress
    enable_application_gateway       = optional(bool)
    application_gateway_sku          = optional(string)
    waf_mode                         = optional(string)
    application_gateway_zones        = optional(list(string))
    application_gateway_min_capacity = optional(number)
    application_gateway_max_capacity = optional(number)
    enable_public_load_balancer      = optional(bool)

    # Operator access
    enable_bastion = optional(bool)
    bastion_sku    = optional(string)

    # Kubernetes
    aks_sku_tier             = optional(string)
    aks_private_cluster      = optional(bool)
    aks_network_policy       = optional(string)
    enable_user_node_pool    = optional(bool)
    user_node_pool_min_count = optional(number)
    user_node_pool_max_count = optional(number)

    # Compute
    vm_size                 = optional(string)
    instance_count          = optional(number)
    enable_autoscale        = optional(bool)
    autoscale_min_instances = optional(number)
    autoscale_max_instances = optional(number)
    compute_zones           = optional(list(string))
    use_spot_instances      = optional(bool)
    os_disk_type            = optional(string)
    os_disk_size_gb         = optional(number)

    # Data
    sql_sku_name                   = optional(string)
    sql_zone_redundant             = optional(bool)
    sql_backup_retention_days      = optional(number)
    sql_enable_long_term_retention = optional(bool)
    enable_redis                   = optional(bool)
    redis_sku_name                 = optional(string)
    redis_high_availability        = optional(bool)
    storage_replication_type       = optional(string)
    storage_enable_versioning      = optional(bool)

    # Security
    data_plane_public_access_enabled     = optional(bool)
    key_vault_purge_protection           = optional(bool)
    key_vault_soft_delete_retention_days = optional(number)
    enable_resource_locks                = optional(bool)
    enable_ddos_protection               = optional(bool)
    enable_defender                      = optional(bool)

    # Observability
    log_retention_days    = optional(number)
    log_daily_quota_gb    = optional(number)
    enable_vm_insights    = optional(bool)
    enable_alerts         = optional(bool)
    enable_backup         = optional(bool)
    backup_retention_days = optional(number)
  })
  default = {}
}

################################################################################
# Quota awareness
#
# A free or trial subscription typically allows 4 total regional vCPUs and zero
# for most non-burstable families. An autoscale rule whose maximum exceeds the
# quota does not fail at apply — it fails silently at 3am when load arrives and
# Azure refuses to allocate. Supplying the quota here turns that into a plan
# error.
################################################################################

variable "subscription_vcpu_quota" {
  description = "Total regional vCPU quota for the target region, from `az vm list-usage`. When set, the profile asserts that the maximum autoscale footprint fits within it. Leave null to skip the check."
  type        = number
  default     = null

  validation {
    condition     = var.subscription_vcpu_quota == null || var.subscription_vcpu_quota > 0
    error_message = "subscription_vcpu_quota must be a positive number, or null to disable the check."
  }
}

variable "compute_tier_count" {
  description = "Number of independently-scaling compute groups sharing the regional vCPU quota. One for an AKS cluster, whose node pools draw from the same quota; higher only where separate scale sets scale independently of each other. Used by both the vCPU quota assertion and the cost estimate, so an inflated value double-counts both."
  type        = number
  default     = 1

  validation {
    condition     = var.compute_tier_count >= 1
    error_message = "compute_tier_count must be at least 1."
  }
}

################################################################################
# Guardrails
################################################################################

variable "enforce_production_guardrails" {
  description = "When true and environment is prod, assert that backup, alerting, Key Vault purge protection and resource locks are enabled, and that SQL retains backups for at least 35 days. Prevents an override from silently producing an unprotected production environment. Disable only with a deliberate, documented reason."
  type        = bool
  default     = true
}
