################################################################################
# Placement
################################################################################

variable "server_name" {
  description = "Logical server name, from naming.sql_server_name. Globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.server_name))
    error_message = "SQL server names must be 1-63 lowercase alphanumerics or hyphens, and must not start or end with a hyphen."
  }
}

variable "database_name" {
  description = "Database name."
  type        = string
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
# Authentication
#
# Entra ID only. This module does not accept a SQL administrator login or
# password at all.
#
# "No hardcoded secrets" is the usual goal. This is stronger: there is NO
# SECRET. No password is generated, so none is written to Terraform state in
# plaintext, none is stored in Key Vault, none is rotated, and none can leak.
# Applications authenticate with their managed identity.
#
# The trade-off is real and worth stating: access is then governed entirely by
# Entra ID group membership, which lives outside this repository. Granting
# database access becomes a directory operation, not a Terraform change.
################################################################################

variable "entra_administrator_login" {
  description = "Display name or UPN of the Entra principal that administers the server. For a group, its display name."
  type        = string
}

variable "entra_administrator_object_id" {
  description = "Object ID of the Entra principal that administers the server. STRONGLY prefer a GROUP over an individual: a user object ID ties production database administration to one person's account, which breaks when they leave and cannot be reviewed as a role."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.entra_administrator_object_id))
    error_message = "entra_administrator_object_id must be a GUID."
  }
}

variable "entra_administrator_is_group" {
  description = "Whether the administrator principal is a group. Recorded so the reachability output can flag the single-user case, which is a governance weakness rather than a technical fault."
  type        = bool
  default     = false
}

variable "azuread_authentication_only" {
  description = "Disable SQL authentication entirely. Should be TRUE. Setting false reintroduces a password that must be generated, stored and rotated — and that lands in Terraform state in plaintext."
  type        = bool
  default     = true
}

################################################################################
# Server
################################################################################

variable "server_version" {
  description = "Logical server version. \"12.0\" is the only value Azure SQL Database accepts; it does not correspond to a SQL Server product version."
  type        = string
  default     = "12.0"
}

variable "minimum_tls_version" {
  description = "Minimum TLS version for connections."
  type        = string
  default     = "1.2"

  validation {
    condition     = contains(["1.2", "1.3"], var.minimum_tls_version)
    error_message = "minimum_tls_version must be \"1.2\" or \"1.3\". Older versions are deprecated and not offered."
  }
}

variable "outbound_network_restriction_enabled" {
  description = "Restrict the server's own outbound connections to approved targets. Relevant when using external data sources or auditing to storage; harmless otherwise."
  type        = bool
  default     = false
}

variable "connection_policy" {
  description = "\"Default\" lets Azure choose Redirect inside the region and Proxy outside. \"Redirect\" is lower latency but requires ports 11000-11999 open to the client. \"Proxy\" uses only 1433 and works everywhere, at a latency cost."
  type        = string
  default     = "Default"

  validation {
    condition     = contains(["Default", "Redirect", "Proxy"], var.connection_policy)
    error_message = "connection_policy must be Default, Redirect or Proxy."
  }
}

################################################################################
# Database
################################################################################

variable "sku_name" {
  description = "Service objective, e.g. \"GP_S_Gen5_1\" for serverless, \"GP_Gen5_2\" provisioned, \"BC_Gen5_4\" Business Critical. Pass the profile's sql_sku_name. Serverless (GP_S_) bills per second of compute and pauses when idle."
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "max_size_gb" {
  description = "Maximum database size in GB."
  type        = number
  default     = 32

  validation {
    condition     = var.max_size_gb >= 1 && var.max_size_gb <= 4096
    error_message = "max_size_gb must be between 1 and 4096."
  }
}

variable "zone_redundant" {
  description = "Spread replicas across availability zones. Pass the profile's sql_zone_redundant. Requires Business Critical or Premium — General Purpose serverless does not support it, and Azure rejects the combination."
  type        = bool
  default     = false
}

variable "auto_pause_delay_in_minutes" {
  description = "Minutes of inactivity before a serverless database pauses, or -1 to never pause. Minimum 60. Paused databases bill for storage only, which is what makes serverless near-free in a dev environment used a few hours a day. The cost is a cold-start delay of several seconds on the first connection after a pause."
  type        = number
  default     = 60

  validation {
    condition     = var.auto_pause_delay_in_minutes == -1 || var.auto_pause_delay_in_minutes >= 60
    error_message = "auto_pause_delay_in_minutes must be -1 (never pause) or at least 60."
  }
}

variable "min_capacity" {
  description = "Minimum vCores for a serverless database. Only meaningful for GP_S_ SKUs."
  type        = number
  default     = 0.5
}

variable "storage_account_type" {
  description = "Backup storage redundancy: \"Local\", \"Zone\" or \"Geo\". Geo is the default in Azure and costs meaningfully more; Local is appropriate for dev."
  type        = string
  default     = "Local"

  validation {
    condition     = contains(["Local", "Zone", "Geo", "GeoZone"], var.storage_account_type)
    error_message = "storage_account_type must be Local, Zone, Geo or GeoZone."
  }
}

variable "collation" {
  description = "Database collation. Cannot be changed after creation without recreating the database."
  type        = string
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "geo_backup_enabled" {
  description = <<-EOT
    Geo Backup Policy flag. Only applicable to DataWarehouse SKUs, and IGNORED
    by Azure for every other tier — set it false on a General Purpose database
    and Azure keeps reporting true, producing a diff on every plan forever.

    The module therefore only sends this for DW_ SKUs and leaves it unset
    otherwise. Actual backup redundancy for normal databases is governed by
    storage_account_type, which does take effect.
  EOT
  type        = bool
  default     = false
}

################################################################################
# Backup retention
################################################################################

variable "short_term_retention_days" {
  description = "Point-in-time restore window in days, 1-35. Pass the profile's sql_backup_retention_days. This is the window in which an accidental delete or a bad migration can be undone."
  type        = number
  default     = 7

  validation {
    condition     = var.short_term_retention_days >= 1 && var.short_term_retention_days <= 35
    error_message = "short_term_retention_days must be between 1 and 35."
  }
}

variable "long_term_retention_enabled" {
  description = "Whether to keep weekly, monthly and yearly backups beyond the point-in-time window. Pass the profile's sql_enable_long_term_retention."
  type        = bool
  default     = false
}

variable "long_term_retention" {
  description = "Long-term retention durations in ISO 8601, e.g. { weekly = \"P4W\", monthly = \"P12M\", yearly = \"P5Y\", week_of_year = 1 }. Only applied when long_term_retention_enabled is true."
  type = object({
    weekly       = optional(string, "P4W")
    monthly      = optional(string, "P12M")
    yearly       = optional(string, "P5Y")
    week_of_year = optional(number, 1)
  })
  default = {}
}

################################################################################
# Network access
################################################################################

variable "public_network_access_enabled" {
  description = "Whether the server keeps a public endpoint. Pass the profile's data_plane_public_access_enabled. When false, only the private endpoint reaches the server — including for schema migrations run from a laptop."
  type        = bool
  default     = false
}

variable "allowed_ip_rules" {
  description = "Map of firewall rule name to { start_ip, end_ip }. Only meaningful when the public endpoint is enabled. Note that a rule of 0.0.0.0-0.0.0.0 is Azure's special 'allow all Azure services' entry, not a real address, and this module rejects it."
  type = map(object({
    start_ip = string
    end_ip   = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for rule in values(var.allowed_ip_rules) :
      !(rule.start_ip == "0.0.0.0" && rule.end_ip == "0.0.0.0")
    ])
    error_message = "A 0.0.0.0-0.0.0.0 rule is Azure's 'Allow Azure services' wildcard, which permits every Azure tenant's resources — including other customers'. It is not an address range and is not permitted by this module."
  }
}

variable "create_private_endpoint" {
  description = "Whether to create a private endpoint. A STATIC boolean, for the same reason as the other data modules: a count derived from an unknown subnet ID cannot be resolved at plan time from an empty state."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint. Null skips creation, which is only safe while the public endpoint remains enabled."
  type        = string
  default     = null
}

variable "private_endpoint_name" {
  description = "Name for the private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs for privatelink.database.windows.net. Without these the endpoint registers no A record and the server resolves to its public address from inside the VNet."
  type        = list(string)
  default     = []
}
