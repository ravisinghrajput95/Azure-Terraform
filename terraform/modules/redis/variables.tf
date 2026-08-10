################################################################################
# Placement
################################################################################

variable "name" {
  description = "Cache name, from naming.redis_name. Globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$", var.name))
    error_message = "Managed Redis names must be 1-63 alphanumerics or hyphens, and must not start or end with a hyphen."
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
# SKU
#
# This module targets AZURE MANAGED REDIS (Microsoft.Cache/redisEnterprise),
# not the classic Azure Cache for Redis.
#
# Classic Azure Cache for Redis is RETIRING: the API now rejects creation
# outright with "Azure Cache for Redis is retiring, create Azure Managed Redis
# instance instead". The classic Basic/Standard/Premium tiers and their C and P
# families are therefore unavailable for new deployments.
#
# Managed Redis families:
#
#   Balanced_B*          General purpose, balanced memory and vCPU. B0 is the
#                        smallest and cheapest entry point.
#   MemoryOptimized_M*   Higher memory per vCPU, for large working sets.
#   ComputeOptimized_X*  Higher vCPU per GB, for throughput-bound workloads.
#   FlashOptimized_A*    NVMe-backed, for very large caches at lower cost per GB.
################################################################################

variable "sku_name" {
  description = "Managed Redis SKU, e.g. \"Balanced_B0\", \"Balanced_B1\", \"MemoryOptimized_M10\", \"ComputeOptimized_X3\", \"FlashOptimized_A250\". Pass the profile's redis_sku_name."
  type        = string
  default     = "Balanced_B0"

  validation {
    condition     = can(regex("^(Balanced|MemoryOptimized|ComputeOptimized|FlashOptimized)_[A-Z][0-9]+$", var.sku_name))
    error_message = "sku_name must be <Family>_<Size>, where family is Balanced, MemoryOptimized, ComputeOptimized or FlashOptimized — e.g. \"Balanced_B0\"."
  }
}

################################################################################
# Availability
#
# High availability replicates across nodes and is what carries the SLA. It is
# ON by default here, and disabling it is a deliberate cost decision that
# removes the SLA entirely: a node fault then loses the whole cache with no
# replica to fail over to.
#
# FlashOptimized does not support disabling HA.
################################################################################

variable "high_availability_enabled" {
  description = "Replicate across nodes. TRUE is the default and carries the SLA. Setting false roughly halves the cost and removes the SLA — a host fault loses the entire cache with nothing to fail over to. Acceptable only where the cache is a pure accelerator and a cold start is survivable."
  type        = bool
  default     = true
}

################################################################################
# Authentication
#
# Managed Redis access keys have the same weaknesses as storage account keys:
# static, never expiring, impossible to scope, and total control of the cache.
# Entra ID authentication replaces them.
################################################################################

variable "access_keys_authentication_enabled" {
  description = "Whether the static access keys may be used. FALSE is the stronger posture — clients then authenticate with a managed identity through a Redis access policy assignment. Any library or sidecar still passing a key stops working the moment this is disabled, so it is a client-side change too."
  type        = bool
  default     = false
}

################################################################################
# Data plane
################################################################################

variable "client_protocol" {
  description = "\"Encrypted\" requires TLS; \"Plaintext\" does not. Always Encrypted — the plaintext protocol carries the access key and every cached value in clear text."
  type        = string
  default     = "Encrypted"

  validation {
    condition     = contains(["Encrypted", "Plaintext"], var.client_protocol)
    error_message = "client_protocol must be \"Encrypted\" or \"Plaintext\". Use Encrypted."
  }
}

variable "clustering_policy" {
  description = "\"OSSCluster\" exposes the standard Redis Cluster API and requires a cluster-aware client. \"EnterpriseCluster\" presents a single endpoint and hides sharding, which is simpler for clients that are not cluster-aware. This changes the client contract, so it is not a transparent choice."
  type        = string
  default     = "EnterpriseCluster"

  validation {
    condition     = contains(["OSSCluster", "EnterpriseCluster"], var.clustering_policy)
    error_message = "clustering_policy must be \"OSSCluster\" or \"EnterpriseCluster\"."
  }
}

variable "eviction_policy" {
  description = "Behaviour when the cache is full. \"VolatileLRU\" evicts only keys carrying a TTL, which is safe when the cache also holds keys that must not vanish. \"AllKeysLRU\" may evict anything. \"NoEviction\" makes writes fail instead of evicting — correct only when the cache is a store rather than a cache."
  type        = string
  default     = "VolatileLRU"

  validation {
    condition = contains([
      "AllKeysLFU", "AllKeysLRU", "AllKeysRandom",
      "VolatileLRU", "VolatileLFU", "VolatileTTL", "VolatileRandom",
      "NoEviction",
    ], var.eviction_policy)
    error_message = "eviction_policy must be a valid Managed Redis eviction policy, e.g. VolatileLRU."
  }
}

variable "port" {
  description = "Data-plane port. Null uses the Azure default of 10000, which differs from classic Redis — clients configured for 6380 will not connect."
  type        = number
  default     = null
}

################################################################################
# Network access
################################################################################

variable "public_network_access_enabled" {
  description = "Whether the cache keeps a public endpoint. Managed Redis has no IP allowlist, so this is a blunt on/off — either the internet can reach the endpoint or only the private endpoint can."
  type        = bool
  default     = false
}

variable "create_private_endpoint" {
  description = "Whether to create a private endpoint. A STATIC boolean, so count resolves at plan time from an empty state."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint."
  type        = string
  default     = null
}

variable "private_endpoint_name" {
  description = "Name for the private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs for privatelink.redis.azure.net. NOTE: Managed Redis uses a DIFFERENT zone from classic Azure Cache for Redis, which used privatelink.redis.cache.windows.net. Supplying the classic zone registers no usable record."
  type        = list(string)
  default     = []
}

################################################################################
# Access policy assignments
#
# The Managed Redis equivalent of a data-plane role assignment: a principal is
# bound to a built-in access policy on the cache. Required for any client
# authenticating with Entra ID, which is every client once access keys are off.
################################################################################

variable "access_policy_assignments" {
  description = "Map of assignment key to { principal_id }. The map key is for addressing in Terraform only — Azure does not name these. Each assignment grants the built-in full data access policy; the resource exposes no policy selector, so nothing narrower is expressible today. With access keys disabled, a principal without an assignment cannot connect at all."
  type = map(object({
    principal_id = string
  }))
  default = {}
}
