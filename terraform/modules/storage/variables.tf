################################################################################
# Placement
################################################################################

variable "name" {
  description = "Storage account name, from naming.storage_account_name. Globally unique, 3-24 lowercase alphanumerics, no hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account names must be 3-24 lowercase alphanumeric characters. No hyphens, no uppercase."
  }
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"data\" lifecycle scope."
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
# Tier and redundancy
################################################################################

variable "account_tier" {
  description = "\"Standard\" or \"Premium\". Premium is SSD-backed with lower latency and is billed on provisioned capacity rather than consumption — it only makes sense for sustained high-IOPS workloads."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.account_tier)
    error_message = "account_tier must be Standard or Premium."
  }
}

variable "account_replication_type" {
  description = "Redundancy. Pass the profile's storage_replication_type. LRS keeps three copies in one datacentre; ZRS spreads across zones in one region; GZRS adds a paired region. Each step up roughly doubles the storage rate."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "account_kind" {
  description = "\"StorageV2\" is correct for essentially all new accounts. The legacy Storage and BlobStorage kinds lack features and cannot be upgraded in place without migration."
  type        = string
  default     = "StorageV2"

  validation {
    condition     = contains(["StorageV2", "BlockBlobStorage", "FileStorage"], var.account_kind)
    error_message = "account_kind must be StorageV2, BlockBlobStorage or FileStorage. The legacy Storage and BlobStorage kinds are not offered."
  }
}

variable "access_tier" {
  description = "Default blob access tier, \"Hot\" or \"Cool\". Cool has lower storage cost and higher access cost, plus an early-deletion charge before 30 days — it loses money for anything read regularly."
  type        = string
  default     = "Hot"

  validation {
    condition     = contains(["Hot", "Cool"], var.access_tier)
    error_message = "access_tier must be Hot or Cool."
  }
}

################################################################################
# Authentication
#
# Storage account keys are the most frequently leaked Azure credential. They
# are static, never expire, cannot be scoped to a container or an operation,
# and grant complete control of the account to anyone holding one. They appear
# in connection strings, CI variables, appsettings files and support tickets.
#
# Disabling them is the single highest-value control on a storage account, and
# it is why every consumer in this platform authenticates with a managed
# identity instead.
################################################################################

variable "shared_access_key_enabled" {
  description = "Whether the two static account keys may be used. Should be FALSE. Note the consequence: Terraform, the CLI and the portal all fall back to Entra ID for data-plane work, so the caller needs a data-plane RBAC role — being subscription Owner is not sufficient, because Owner grants control-plane rights only."
  type        = bool
  default     = false
}

variable "default_to_oauth_authentication" {
  description = "Make the portal default to Entra ID rather than account keys when browsing data. Cosmetic when keys are disabled, but it stops operators reaching for a key first."
  type        = bool
  default     = true
}

variable "local_user_enabled" {
  description = "Whether SFTP and NFS local users may authenticate. Off unless SFTP is genuinely in use — local users are a second credential system outside Entra ID."
  type        = bool
  default     = false
}

################################################################################
# Transport and data protection
################################################################################

variable "min_tls_version" {
  description = "Minimum TLS version. TLS1_2 is the floor; anything lower is rejected by most compliance regimes and by modern clients anyway."
  type        = string
  default     = "TLS1_2"

  validation {
    condition     = contains(["TLS1_2"], var.min_tls_version)
    error_message = "min_tls_version must be TLS1_2. Older versions are deprecated and this module does not offer them."
  }
}

variable "allow_nested_items_to_be_public" {
  description = "Whether individual containers may be set to public access. FALSE makes anonymous public blob access impossible ACCOUNT-WIDE regardless of per-container settings — a single switch that forecloses the most common storage data-exposure incident."
  type        = bool
  default     = false
}

variable "cross_tenant_replication_enabled" {
  description = "Whether object replication to an account in another Entra tenant is permitted. Off by default: it is an exfiltration path that requires no network access at all."
  type        = bool
  default     = false
}

variable "infrastructure_encryption_enabled" {
  description = "Add a second, independent layer of encryption at rest. Cannot be changed after creation. Required by some regimes; otherwise a modest performance cost for defence in depth."
  type        = bool
  default     = false
}

variable "blob_versioning_enabled" {
  description = "Keep previous versions of overwritten blobs. Pass the profile's storage_enable_versioning. Every version is billed as stored data, so pair it with a lifecycle policy in production."
  type        = bool
  default     = false
}

variable "blob_change_feed_enabled" {
  description = "Record an ordered, immutable log of every blob change. Useful for audit and for downstream event processing; billed as stored data."
  type        = bool
  default     = false
}

variable "blob_delete_retention_days" {
  description = "Days a soft-deleted blob remains recoverable, 1-365. Zero disables soft delete entirely, which makes an accidental delete permanent."
  type        = number
  default     = 7

  validation {
    condition     = var.blob_delete_retention_days >= 0 && var.blob_delete_retention_days <= 365
    error_message = "blob_delete_retention_days must be between 0 and 365."
  }
}

variable "container_delete_retention_days" {
  description = "Days a soft-deleted container remains recoverable, 1-365. Deleting a container removes every blob in it, so this is the more consequential of the two retention settings."
  type        = number
  default     = 7

  validation {
    condition     = var.container_delete_retention_days >= 0 && var.container_delete_retention_days <= 365
    error_message = "container_delete_retention_days must be between 0 and 365."
  }
}

################################################################################
# Network access
################################################################################

variable "public_network_access_enabled" {
  description = "Whether the account keeps a public endpoint. Pass the profile's data_plane_public_access_enabled. When false, only the private endpoint reaches the data plane — including for Terraform."
  type        = bool
  default     = false
}

variable "network_rules_default_action" {
  description = "Action for traffic matching no rule. Must be \"Deny\" for the IP and subnet rules to mean anything."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_rules_default_action)
    error_message = "network_rules_default_action must be Allow or Deny."
  }
}

variable "network_rules_bypass" {
  description = "Trusted paths exempt from the rules. \"AzureServices\" is normally required — without it, diagnostic settings writing to this account, and Azure Backup, are blocked."
  type        = list(string)
  default     = ["AzureServices"]

  validation {
    condition = alltrue([
      for entry in var.network_rules_bypass : contains(["AzureServices", "Logging", "Metrics", "None"], entry)
    ])
    error_message = "network_rules_bypass entries must be from: AzureServices, Logging, Metrics, None."
  }
}

variable "allowed_ip_rules" {
  description = "Public IPv4 addresses or CIDRs permitted to reach the data plane. Azure rejects /31 and /32 suffixes here; supply bare addresses. Private ranges are also rejected — they are meaningless on a public endpoint."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for rule in var.allowed_ip_rules : !can(regex("/3[12]$", rule))])
    error_message = "Azure rejects /31 and /32 CIDR suffixes in storage network rules. Supply a bare IPv4 address for a single host."
  }

  validation {
    condition = alltrue([
      for rule in var.allowed_ip_rules :
      !can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", rule))
    ])
    error_message = "Private RFC1918 addresses are rejected by Azure in storage network rules — a public endpoint never sees them. Use allowed_subnet_ids or the private endpoint instead."
  }
}

variable "allowed_subnet_ids" {
  description = "Subnet IDs permitted via service endpoint. Requires Microsoft.Storage service endpoints on those subnets. Distinct from the private endpoint path."
  type        = list(string)
  default     = []
}

################################################################################
# Private endpoint
#
# One endpoint per SUB-RESOURCE. blob, file, queue, table and dfs are separate
# endpoints with separate private DNS zones — an endpoint for blob does not
# make file resolve privately. This module creates endpoints only for the
# sub-resources explicitly requested.
################################################################################

variable "create_private_endpoints" {
  description = "Whether to create private endpoints. A STATIC boolean: deriving it from `private_endpoint_subnet_id != null` makes for_each depend on a value unknown until apply, breaking any plan from an empty state."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for private endpoints. Null skips creation, which is only safe while the public endpoint remains enabled."
  type        = string
  default     = null
}

variable "private_endpoint_subresources" {
  description = "Sub-resources to create private endpoints for: blob, file, queue, table, dfs, web. Each needs its own DNS zone in private_dns_zone_ids_by_subresource."
  type        = list(string)
  default     = ["blob"]

  validation {
    condition = alltrue([
      for sub in var.private_endpoint_subresources :
      contains(["blob", "file", "queue", "table", "dfs", "web"], sub)
    ])
    error_message = "private_endpoint_subresources entries must be from: blob, file, queue, table, dfs, web."
  }
}

variable "private_dns_zone_ids_by_subresource" {
  description = "Map of sub-resource name to its private DNS zone IDs, e.g. { blob = [\"/subscriptions/.../privatelink.blob.core.windows.net\"] }. Without the zone the endpoint registers no A record and the account resolves to its public address from inside the VNet."
  type        = map(list(string))
  default     = {}
}

variable "private_endpoint_name_prefix" {
  description = "Prefix for private endpoint names; the sub-resource is appended, e.g. \"pep-st-cloudcart-dev-eus\" becomes \"pep-st-cloudcart-dev-eus-blob\"."
  type        = string
  default     = null
}

################################################################################
# Access and containers
################################################################################

variable "role_assignments" {
  description = "Map of assignment key to { principal_id, role_definition_name }. Scoped to this account. With shared keys disabled these grants are the ONLY way to reach data — note that Owner and Contributor are control-plane roles and do NOT confer data access."
  type = map(object({
    principal_id         = string
    role_definition_name = string
    principal_type       = optional(string, "ServicePrincipal")
    description          = optional(string)
  }))
  default = {}
}

variable "containers" {
  description = "Map of container name to { access_type }. access_type must be \"private\" unless allow_nested_items_to_be_public is true, which it should not be."
  type = map(object({
    access_type = optional(string, "private")
    metadata    = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for container in values(var.containers) :
      contains(["private", "blob", "container"], container.access_type)
    ])
    error_message = "Container access_type must be private, blob or container. Use \"private\" unless anonymous access is genuinely intended."
  }
}

variable "rbac_propagation_delay_seconds" {
  description = "Seconds to wait after data-plane role assignments before creating containers. With shared keys disabled, container creation authenticates as the caller's Entra principal, so the role must be effective first — and Azure exposes no API to wait on. Set 0 to disable."
  type        = number
  default     = 45

  validation {
    condition     = var.rbac_propagation_delay_seconds >= 0 && var.rbac_propagation_delay_seconds <= 600
    error_message = "rbac_propagation_delay_seconds must be between 0 and 600."
  }
}
