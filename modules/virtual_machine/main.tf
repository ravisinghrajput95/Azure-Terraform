##################################################
# Public IP
##################################################

resource "azurerm_public_ip" "bastion" {

  name                = local.public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name

  allocation_method = "Static"

  sku = "Standard"

  tags = var.tags
}

##################################################
# Network Interface
##################################################

resource "azurerm_network_interface" "bastion" {

  name                = local.nic_name
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {

    name = "primary"

    subnet_id = var.subnet_id

    private_ip_address_allocation = "Dynamic"

    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = var.tags
}

##################################################
# Associate NIC with NSG
##################################################

resource "azurerm_network_interface_security_group_association" "bastion" {
  network_interface_id      = azurerm_network_interface.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

##################################################
# Linux Virtual Machine
##################################################

resource "azurerm_linux_virtual_machine" "bastion" {
  name                            = local.vm_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids = [
    azurerm_network_interface.bastion.id
  ]

  ################################################
  # SSH
  ################################################
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  ################################################
  # OS Disk
  ################################################

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
  }

  ################################################
  # Ubuntu 24.04 LTS
  ################################################

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  ################################################
  # Managed Identity
  ################################################

  identity {
    type = "SystemAssigned"
  }

  ################################################
  # Boot Diagnostics
  ################################################

  boot_diagnostics {
  }

  tags = var.tags
}
