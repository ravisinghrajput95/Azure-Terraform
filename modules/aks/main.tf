##################################################
# Kubernetes Cluster
##################################################

resource "azurerm_kubernetes_cluster" "cloudcart_aks" {
  name                = "cloudcart-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "cloudcartaks"

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.vm_size
    vnet_subnet_id = var.subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}
