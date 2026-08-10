##################################################
# General
##################################################

variable "location" {
  description = "Azure Region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group Name"
  type        = string
}

##################################################
# Network
##################################################

variable "subnet_id" {
  description = "Subnet ID for the AKS cluster"
  type        = string
}

##################################################
# Node Pool
##################################################

variable "vm_size" {
  description = "Azure VM Size"
  type        = string
  default     = "Standard_D2ds_v7"
}

variable "node_count" {
  description = "Node count for the default node pool"
  type        = number
  default     = 1
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
