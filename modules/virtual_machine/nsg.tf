##################################################
# Network Security Group
##################################################

resource "azurerm_network_security_group" "bastion" {
  name                = local.nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name

  ################################################
  # SSH
  ################################################
  # Only emitted when ssh_allowed_cidrs is non-empty. Leaving it empty means
  # no inbound SSH rule at all, which is the safe default.

  dynamic "security_rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []

    content {
      name                       = "Allow-SSH"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.ssh_allowed_cidrs
      destination_address_prefix = "*"
    }
  }

  tags = var.tags
}
