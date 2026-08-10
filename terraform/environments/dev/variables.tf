################################################################################
# Subscription
################################################################################

variable "subscription_id" {
  description = "Target Azure subscription ID. Required explicitly by azurerm 4.x — it no longer falls back to the CLI's active subscription silently, which prevents applying to whichever subscription happened to be selected."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

################################################################################
# Identity of this deployment
################################################################################

variable "workload" {
  description = "Workload identifier, used by both naming and tags."
  type        = string
  default     = "cloudcart"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

################################################################################
# Governance
#
# No defaults. These are the tags cost reporting and incident response query
# on; a default would guarantee a share of the estate reads \"unknown\".
################################################################################

variable "owner" {
  description = "Email of the team accountable for this environment."
  type        = string
}

variable "cost_center" {
  description = "Chargeback code."
  type        = string
}

variable "criticality" {
  description = "Business criticality: low, medium, high or mission-critical."
  type        = string
  default     = "low"
}

variable "data_classification" {
  description = "Data sensitivity: public, internal, confidential or restricted."
  type        = string
  default     = "internal"
}

################################################################################
# Capacity
################################################################################

variable "subscription_vcpu_quota" {
  description = "Total regional vCPU quota, from `az vm list-usage --location <region>`. The profile module asserts the peak compute footprint fits inside it. On this subscription (FreeTrial, spending limit on) the limit is 4 and cannot be raised without upgrading to Pay-As-You-Go."
  type        = number
  default     = 4
}

################################################################################
# Profile overrides
################################################################################

variable "profile_overrides" {
  description = "Overrides applied on top of the dev profile. Left empty, the free-tier-safe defaults apply. See modules/profile/README.md for the full attribute list."
  type        = any
  default     = {}
}

################################################################################
# Firewall
################################################################################

variable "firewall_private_ip" {
  description = "Private IP of the Azure Firewall, used as the VirtualAppliance next hop for the workload route table. Only consumed when the profile's egress_strategy is \"firewall\"; dev uses a NAT Gateway and leaves this null. Taken as a variable rather than read from the firewall module so that route tables can be applied before, or independently of, the firewall."
  type        = string
  default     = null
}

################################################################################
# Data-plane access
################################################################################

variable "deployer_ip_addresses" {
  description = "Public IPv4 addresses permitted to reach the Key Vault and Storage data planes. Required in dev, where secrets must be manageable from an operator machine outside the VNet — a private endpoint is only reachable from inside it, so with no allowlist Terraform itself could not write a secret. Azure rejects /31 and /32 suffixes here; supply bare addresses."
  type        = list(string)
  default     = []
}
