################################################################################
# Placement
################################################################################

variable "name" {
  description = "Key Vault name, from naming.key_vault_name. Globally unique, 3-24 characters."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault names must be 3-24 characters, alphanumerics and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"sec\" lifecycle scope — the vault is security-team owned and outlives the compute that reads from it."
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

variable "tenant_id" {
  description = "Entra ID tenant the vault belongs to, from data.azurerm_client_config."
  type        = string
}

################################################################################
# SKU
################################################################################

variable "sku_name" {
  description = "\"standard\" or \"premium\". Premium adds HSM-backed keys and costs meaningfully more per key operation. Standard is correct unless a compliance regime specifically requires FIPS 140-2 Level 2 hardware protection."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.sku_name)
    error_message = "sku_name must be \"standard\" or \"premium\"."
  }
}

################################################################################
# Deletion protection
################################################################################

variable "purge_protection_enabled" {
  description = <<-EOT
    Whether a soft-deleted vault can be purged before its retention period
    expires.

    ENABLING THIS IS IRREVERSIBLE. Azure provides no way to turn it off once
    set. With it on, a deleted vault's NAME is unusable until retention
    expires — and because the naming module produces a deterministic name,
    that means the environment cannot be rebuilt for up to 90 days.

    Correct for production, where the risk being managed is permanent loss of
    keys. Wrong for dev, where the destroy/recreate cycle is the primary cost
    control on a credit-limited subscription.
  EOT
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Days a deleted vault is recoverable, 7-90. Also the period its name stays reserved. Short in dev so a rebuild is not blocked; long in production so an accidental deletion is recoverable."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

################################################################################
# Network access
#
# Key Vault secrets are read and written over the DATA plane, which is subject
# to these controls — unlike the control plane, which is not. This distinction
# is the source of most Key Vault access confusion: Terraform can create the
# vault while being unable to put a secret in it.
################################################################################

variable "public_network_access_enabled" {
  description = "Whether the vault keeps a public endpoint. When false, the vault is reachable ONLY from inside the VNet via private endpoint — including by Terraform, which means a runner outside the network cannot manage secrets. Pass the profile's data_plane_public_access_enabled."
  type        = bool
  default     = false
}

variable "network_acls_default_action" {
  description = "Action for traffic matching no rule. Must be \"Deny\" in any environment that matters: \"Allow\" makes the IP and subnet rules decorative, since everything not explicitly denied is permitted."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_acls_default_action)
    error_message = "network_acls_default_action must be \"Allow\" or \"Deny\"."
  }
}

variable "network_acls_bypass" {
  description = "\"AzureServices\" permits trusted Microsoft services to reach the vault regardless of the rules — required for disk encryption, Storage CMK and App Service certificate references. \"None\" is stricter and breaks those integrations."
  type        = string
  default     = "AzureServices"

  validation {
    condition     = contains(["AzureServices", "None"], var.network_acls_bypass)
    error_message = "network_acls_bypass must be \"AzureServices\" or \"None\"."
  }
}

variable "allowed_ip_rules" {
  description = "Public IPv4 addresses or CIDRs permitted to reach the data plane. Only meaningful when public_network_access_enabled is true. Note that Azure rejects /31 and /32 suffixes here — supply a bare address for a single host."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for rule in var.allowed_ip_rules : !can(regex("/3[12]$", rule))])
    error_message = "Azure rejects /31 and /32 CIDR suffixes in Key Vault IP rules. Supply a bare IPv4 address for a single host, e.g. \"203.0.113.4\"."
  }
}

variable "allowed_subnet_ids" {
  description = "Subnet IDs permitted to reach the data plane through a service endpoint. Distinct from the private endpoint path — this is for subnets reaching the PUBLIC endpoint over the Microsoft backbone, and requires Microsoft.KeyVault service endpoints on those subnets."
  type        = list(string)
  default     = []
}

################################################################################
# Private endpoint
################################################################################

variable "create_private_endpoint" {
  description = "Whether to create a private endpoint. A STATIC boolean, deliberately: deriving this from `private_endpoint_subnet_id != null` makes count depend on a value that is unknown until apply, which fails any plan from an empty state — so the module would work incrementally and break for a fresh environment."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the vault's private endpoint. Null skips creation, which is only safe when the public endpoint remains enabled."
  type        = string
  default     = null
}

variable "private_endpoint_name" {
  description = "Name for the private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs for privatelink.vaultcore.azure.net, from the private-dns module. Without these the endpoint exists but registers no A record, and the vault name resolves to its public address from inside the VNet."
  type        = list(string)
  default     = []
}

################################################################################
# Access
#
# RBAC only. The legacy access policy model is not exposed by this module: it
# does not compose with Azure RBAC, is not visible to standard access reviews,
# and grants are invisible to `az role assignment list`.
################################################################################

variable "role_assignments" {
  description = "Map of assignment key to { principal_id, role_definition_name }. Scoped to this vault, so grants die with it rather than outliving it as orphans. Common roles: \"Key Vault Secrets User\" to read, \"Key Vault Secrets Officer\" to manage, \"Key Vault Administrator\" for full data-plane control."
  type = map(object({
    principal_id         = string
    role_definition_name = string
    principal_type       = optional(string, "ServicePrincipal")
    description          = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for assignment in values(var.role_assignments) :
      contains(["ServicePrincipal", "User", "Group"], assignment.principal_type)
    ])
    error_message = "principal_type must be ServicePrincipal, User or Group. Setting it explicitly avoids the Entra ID lookup that fails for a recently created principal."
  }
}

################################################################################
# Platform integrations
#
# All default false. Each grants a platform service implicit read access to the
# vault, and should be switched on only when the corresponding integration is
# genuinely in use.
################################################################################

variable "enabled_for_deployment" {
  description = "Allow virtual machines to retrieve certificates stored as secrets. Needed only for VM certificate provisioning."
  type        = bool
  default     = false
}

variable "enabled_for_disk_encryption" {
  description = "Allow Azure Disk Encryption to retrieve and unwrap keys."
  type        = bool
  default     = false
}

variable "enabled_for_template_deployment" {
  description = "Allow ARM template deployments to reference secrets. Rarely needed alongside Terraform, and it widens the set of principals that can read the vault indirectly."
  type        = bool
  default     = false
}
