##################################################
# Naming
##################################################

locals {
  vm_name        = var.vm_name
  nic_name       = "${var.prefix}-nic"
  public_ip_name = "${var.prefix}-pip"
  nsg_name       = "${var.prefix}-nsg"
}
