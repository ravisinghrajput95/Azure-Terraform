##################################################
# Azure Authentication
##################################################

variable "client_id" {
  description = "Azure Service Principal Client ID"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "Azure Service Principal Client Secret"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

##################################################
# Resource Group
##################################################

variable "resource_group_name" {
  description = "Azure Resource Group Name"
  type        = string
  default     = "cloudcart"
}

##################################################
# Tags
##################################################

variable "tags" {
  description = "Tags applied to all resources"

  type = map(string)

  default = {
    environment = "staging"
    managedBy   = "Terraform"
  }
}

##################################################
# SSH
##################################################

variable "ssh_public_key" {
  description = "SSH public key in OpenSSH format"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs permitted to reach the bastion on port 22. Empty means no inbound SSH rule is created."
  type        = list(string)
  default     = []
}
