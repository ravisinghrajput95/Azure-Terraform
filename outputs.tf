##################################################
# Bastion Virtual Machine
##################################################

output "vm_id" {
  description = "Bastion Virtual Machine ID"
  value       = module.virtual_machine.vm_id
}

output "public_ip" {
  description = "Bastion Public IP Address"
  value       = module.virtual_machine.public_ip
}

output "ssh_command" {
  description = "SSH Command for the bastion"
  value       = module.virtual_machine.ssh_command
}

##################################################
# AKS
##################################################

output "aks_cluster_name" {
  description = "AKS Cluster Name"
  value       = module.aks.cluster_name
}

output "aks_node_resource_group" {
  description = "Auto-generated Resource Group holding the AKS nodes"
  value       = module.aks.node_resource_group
}

output "aks_kube_config" {
  description = "Raw kubeconfig for the AKS cluster"
  value       = module.aks.kube_config
  sensitive   = true
}
