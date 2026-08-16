################################################################################
# Unit tests for the bastion module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# Bastion's SKUs are not a price ladder with the same shape at each rung. They
# attach differently — Developer takes a VNet ID and no subnet, everything else
# takes a dedicated AzureBastionSubnet and a public IP — and each tier silently
# ignores features it does not implement. A feature named on a SKU that does
# not support it is accepted, shows as configured, and does nothing, which is
# how an operator ends up believing a session is being recorded when it is not.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "bas-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-net"
  location            = "centralus"
  tags                = { environment = "test" }

  sku            = "Standard"
  subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureBastionSubnet"
  public_ip_name = "pip-bas-cloudcart-test-cus-001"
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_standard_bastion" {
  command = plan

  assert {
    condition     = output.uses_dedicated_subnet == true
    error_message = "Standard attaches to AzureBastionSubnet and must report that it does."
  }

  assert {
    condition     = output.sku == "Standard"
    error_message = "The SKU must be reported as configured."
  }
}

################################################################################
# How the SKU attaches
#
# Developer is a shared regional instance bound to the VNet itself. It does not
# use AzureBastionSubnet, which is also why it does not work across peered
# VNets. Every other SKU is the opposite: dedicated subnet, no VNet ID.
################################################################################

run "accepts_developer_attached_by_vnet" {
  command = plan

  variables {
    sku                = "Developer"
    virtual_network_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
    subnet_id          = null
    public_ip_name     = null
  }

  assert {
    condition     = output.uses_dedicated_subnet == false
    error_message = "Developer does not use a dedicated subnet."
  }

  assert {
    condition     = strcontains(output.capability_notes, "does not work across peered VNets")
    error_message = "Developer's peering limitation must be stated, not left to be discovered."
  }
}

run "rejects_developer_given_a_subnet" {
  command = plan

  variables {
    sku                = "Developer"
    virtual_network_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
    subnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureBastionSubnet"
    public_ip_name     = null
  }

  expect_failures = [azurerm_bastion_host.this]
}

run "rejects_a_dedicated_sku_given_a_vnet_id" {
  command = plan

  variables {
    sku                = "Standard"
    virtual_network_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
    subnet_id          = null
    public_ip_name     = "pip-bas-cloudcart-test-cus-001"
  }

  expect_failures = [azurerm_bastion_host.this]
}

# NOT TESTED, and the reason is a finding rather than an omission.
#
# main.tf carries a precondition for a dedicated-subnet SKU with no public IP:
#
#   condition     = !local.uses_dedicated_subnet || var.public_ip_name != null
#   error_message = "The <sku> SKU requires a public IP; set public_ip_name."
#
# That precondition can never fire. azurerm_public_ip has count = 1 for every
# dedicated-subnet SKU and its `name` is that same variable, so when it is null
# Terraform rejects the resource first with "Missing required argument" and the
# plan stops before any precondition is evaluated.
#
# It cannot be written as a test either: expect_failures only accepts checkable
# objects — preconditions, postconditions, variable validation — and a missing
# required argument is a schema error, not a check.
#
# The configuration IS still refused before any Azure call, so nothing unsafe
# reaches Azure. What is lost is only the better message. Left in place rather
# than deleted, because it documents the requirement at the point it applies,
# and recorded here so the gap is not mistaken for coverage.

################################################################################
# Features the SKU does not implement
#
# All of these are ACCEPTED by Azure on the wrong tier and simply do nothing.
################################################################################

run "rejects_advanced_features_on_basic" {
  command = plan

  variables {
    sku               = "Basic"
    tunneling_enabled = true
  }

  expect_failures = [azurerm_bastion_host.this]
}

run "rejects_file_copy_on_basic" {
  command = plan

  variables {
    sku               = "Basic"
    file_copy_enabled = true
  }

  expect_failures = [azurerm_bastion_host.this]
}

run "rejects_session_recording_below_premium" {
  command = plan

  variables {
    sku                       = "Standard"
    session_recording_enabled = true
  }

  expect_failures = [azurerm_bastion_host.this]
}

run "accepts_session_recording_on_premium" {
  command = plan

  variables {
    sku                       = "Premium"
    session_recording_enabled = true
    shareable_link_enabled    = false
  }

  assert {
    condition     = output.sku == "Premium"
    error_message = "Premium must accept session recording."
  }
}

run "rejects_kerberos_on_developer" {
  command = plan

  variables {
    sku                = "Developer"
    virtual_network_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet"
    subnet_id          = null
    public_ip_name     = null
    kerberos_enabled   = true
  }

  expect_failures = [azurerm_bastion_host.this]
}

################################################################################
# Mutually exclusive features
#
# Session recording and shareable links cannot both be on. A shareable link is
# an unauthenticated URL, which is exactly what a recorded session cannot be.
################################################################################

run "rejects_session_recording_with_shareable_links" {
  command = plan

  variables {
    sku                       = "Premium"
    session_recording_enabled = true
    shareable_link_enabled    = true
  }

  expect_failures = [azurerm_bastion_host.this]
}

################################################################################
# Zones
################################################################################

run "rejects_zones_on_a_sku_that_has_none" {
  command = plan

  variables {
    sku   = "Basic"
    zones = ["1", "2", "3"]
  }

  expect_failures = [azurerm_bastion_host.this]
}

run "accepts_zones_on_standard" {
  command = plan

  variables {
    sku   = "Standard"
    zones = ["1", "2", "3"]
  }

  assert {
    condition     = output.sku == "Standard"
    error_message = "Standard supports zones and must accept them."
  }
}
