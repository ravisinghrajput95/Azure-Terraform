##################################################
# Resource Group
##################################################
# Created out-of-band during backend bootstrap, so it is read rather than
# managed here. To bring it under Terraform, replace this with a resource
# block and run:
#   terraform import azurerm_resource_group.main \
#     /subscriptions/<sub-id>/resourceGroups/<name>

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

##################################################
# Network
##################################################

module "network" {

  source              = "Azure/network/azurerm"
  version             = "5.3.0"
  resource_group_name = data.azurerm_resource_group.main.name
  vnet_name           = "cloudcart-vnet"
  address_space       = "10.0.0.0/16"
  subnet_names = [
    "subnet1",
    "subnet2"
  ]

  subnet_prefixes = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]

  use_for_each = true
  tags         = var.tags
}

##################################################
# Bastion Virtual Machine
##################################################

module "virtual_machine" {
  source              = "./modules/virtual_machine"
  prefix              = "cloudcart"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = module.network.vnet_subnets[0]
  ssh_public_key      = var.ssh_public_key
  ssh_allowed_cidrs   = var.ssh_allowed_cidrs
  tags                = var.tags
}

##################################################
# AKS
##################################################

module "aks" {
  source              = "./modules/aks"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = module.network.vnet_subnets[1]
  tags                = var.tags
}
