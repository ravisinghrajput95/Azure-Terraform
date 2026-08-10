##################################################
# Virtual Machine
##################################################

output "vm_id" {
  description = "Linux Virtual Machine ID"
  value       = azurerm_linux_virtual_machine.bastion.id
}

output "vm_name" {
  description = "Linux Virtual Machine Name"
  value       = azurerm_linux_virtual_machine.bastion.name
}

##################################################
# Network
##################################################

output "nic_id" {
  description = "Network Interface ID"
  value       = azurerm_network_interface.bastion.id
}

output "private_ip" {
  description = "Private IP Address"
  value       = azurerm_network_interface.bastion.private_ip_address
}

output "public_ip_id" {
  description = "Public IP Resource ID"
  value       = azurerm_public_ip.bastion.id
}

output "public_ip" {
  description = "Public IP Address"
  value       = azurerm_public_ip.bastion.ip_address
}

##################################################
# Network Security Group
##################################################

output "nsg_id" {
  description = "Network Security Group ID"
  value       = azurerm_network_security_group.bastion.id
}

##################################################
# Managed Identity
##################################################

output "principal_id" {
  description = "System Assigned Managed Identity Principal ID"
  value       = azurerm_linux_virtual_machine.bastion.identity[0].principal_id
}

##################################################
# SSH
##################################################

output "ssh_command" {
  description = "SSH Command"

  value = format(
    "ssh %s@%s",
    var.admin_username,
    azurerm_public_ip.bastion.ip_address
  )
}
