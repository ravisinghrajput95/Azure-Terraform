################################################################################
# Placement
################################################################################

variable "name" {
  description = "Bastion host name, from naming.names.bastion."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"net\" lifecycle scope — Bastion is network edge, not application."
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
# The SKU changes the SHAPE of the resource, not merely its capabilities:
#
#   Developer   No charge. Deploys as a shared regional instance referenced by
#               virtual_network_id — it does NOT consume AzureBastionSubnet and
#               takes no public IP. Portal-only: no native client, no tunneling,
#               no peered-VNet access. Regional availability is limited.
#
#   Basic       ~$140/month. Requires AzureBastionSubnet and a Standard public
#               IP. Fixed at 2 instances. No tunneling, IP connect, shareable
#               links or file copy.
#
#   Standard    ~$175/month base. Adds scale units, native client tunneling,
#               IP connect, shareable links, file copy, and zone support.
#
#   Premium     Adds session recording and private-only mode.
################################################################################

variable "sku" {
  description = "Bastion SKU. Pass the profile module's bastion_sku. Developer carries no charge but is portal-only and does not use AzureBastionSubnet."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Developer", "Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be one of: Developer, Basic, Standard, Premium."
  }
}

################################################################################
# Network placement
#
# Exactly one of these applies, determined by SKU. Preconditions in main.tf
# enforce the pairing rather than letting Azure reject it after a several
# minute provisioning attempt.
################################################################################

variable "virtual_network_id" {
  description = "Virtual network the Developer SKU attaches to. Required for Developer, and must be null for every other SKU."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "AzureBastionSubnet ID. Required for Basic, Standard and Premium, and must be null for Developer. The subnet must be named exactly AzureBastionSubnet and be /26 or larger."
  type        = string
  default     = null
}

variable "public_ip_name" {
  description = "Name for the Bastion public IP, created by this module for Basic and above. Unused by Developer."
  type        = string
  default     = null
}

variable "zones" {
  description = "Availability zones for the Bastion host. Supported on Standard and Premium only. Empty means regional."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for zone in var.zones : contains(["1", "2", "3"], zone)])
    error_message = "zones must contain only \"1\", \"2\" or \"3\"."
  }
}

################################################################################
# Capacity
################################################################################

variable "scale_units" {
  description = "Instance count, 2-50. Standard and Premium only; Basic is fixed at 2 and Developer is a shared instance. Each unit supports roughly 20 concurrent sessions."
  type        = number
  default     = 2

  validation {
    condition     = var.scale_units >= 2 && var.scale_units <= 50
    error_message = "scale_units must be between 2 and 50."
  }
}

################################################################################
# Features
#
# Each is gated by SKU. Setting a feature the SKU does not support fails at
# apply, several minutes in — the preconditions in main.tf move that to plan
# time.
################################################################################

variable "copy_paste_enabled" {
  description = "Allow clipboard copy and paste in the browser session. Supported on all SKUs. Disabling it is a data-exfiltration control that also makes routine operator work materially slower."
  type        = bool
  default     = true
}

variable "file_copy_enabled" {
  description = "Allow file upload and download through the session. Standard and Premium only."
  type        = bool
  default     = false
}

variable "tunneling_enabled" {
  description = "Allow native client connections via `az network bastion tunnel`, rather than browser only. Standard and Premium only. This is the main practical reason to move off Developer."
  type        = bool
  default     = false
}

variable "ip_connect_enabled" {
  description = "Allow connecting to a target by private IP rather than by resource ID. Standard and Premium only. Convenient, and it widens reachable targets to anything routable from the Bastion subnet."
  type        = bool
  default     = false
}

variable "shareable_link_enabled" {
  description = "Allow generating links that grant session access to users without Azure RBAC on the target. Standard and Premium only. Off by default — it is an authentication bypass by design."
  type        = bool
  default     = false
}

variable "kerberos_enabled" {
  description = "Enable Kerberos authentication for domain-joined targets. Basic and above."
  type        = bool
  default     = false
}

# NOTE: private_only_enabled is NOT exposed as an input. It is computed-only in
# azurerm 4.x — readable but not settable — so it is surfaced as an output
# instead. Setting it requires the Azure API directly or a later provider.

variable "session_recording_enabled" {
  description = "Record sessions for audit. Premium only. Cannot be combined with shareable links."
  type        = bool
  default     = false
}
