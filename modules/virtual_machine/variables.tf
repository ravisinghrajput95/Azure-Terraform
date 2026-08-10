##################################################
# General
##################################################

variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

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
  description = "Subnet ID where VM NIC will be deployed"
  type        = string
}

##################################################
# Virtual Machine
##################################################

variable "vm_name" {
  description = "Virtual Machine Name"
  type        = string
  default     = "cloudcart-vm"
}

variable "vm_size" {
  description = "Azure VM Size"
  type        = string
  default     = "Standard_D2ds_v7"
}

variable "admin_username" {
  description = "Linux admin username"
  type        = string
  default     = "azureuser"
}

##################################################
# SSH
##################################################

variable "ssh_public_key" {
  description = "SSH Public Key"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs permitted to reach the bastion on port 22. Empty means no inbound SSH rule is created."
  type        = list(string)
  default     = []
}

##################################################
# Image
##################################################

variable "image_publisher" {
  type    = string
  default = "Canonical"
}

variable "image_offer" {
  type    = string
  default = "ubuntu-24_04-lts"
}

variable "image_sku" {
  type    = string
  default = "server"
}

variable "image_version" {
  type    = string
  default = "latest"
}

##################################################
# Disk
##################################################

variable "os_disk_type" {
  type    = string
  default = "Standard_LRS"
}

##################################################
# Tags
##################################################

variable "tags" {
  type = map(string)

  default = {
    managedBy = "Terraform"
  }
}
