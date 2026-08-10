##################################################
# Cluster
##################################################

output "cluster_id" {
  description = "AKS Cluster ID"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.id
}

output "cluster_name" {
  description = "AKS Cluster Name"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.name
}

output "node_resource_group" {
  description = "Auto-generated Resource Group holding the cluster nodes"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.node_resource_group
}

##################################################
# Managed Identity
##################################################

output "principal_id" {
  description = "System Assigned Managed Identity Principal ID"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.identity[0].principal_id
}

##################################################
# Credentials
##################################################

output "client_certificate" {
  description = "Kubernetes Client Certificate"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.kube_config[0].client_certificate
  sensitive   = true
}

output "kube_config" {
  description = "Raw kubeconfig for the cluster"
  value       = azurerm_kubernetes_cluster.cloudcart_aks.kube_config_raw
  sensitive   = true
}
