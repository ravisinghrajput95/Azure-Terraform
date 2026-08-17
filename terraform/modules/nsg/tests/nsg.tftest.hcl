################################################################################
# Unit tests for the nsg module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# Every failure this module guards is a rule set that Azure accepts and applies
# differently from how it reads. Two rules at the same priority is rejected at
# apply with a message naming one of them; two NSGs claiming one subnet is
# accepted, and the second association silently replaces the first, so the
# rules that end up in force are whichever applied last.
################################################################################

mock_provider "azurerm" {}

variables {
  resource_group_name = "rg-cloudcart-test-cus-net"
  location            = "centralus"
  tags                = { environment = "test" }

  network_security_groups = {
    aks = {
      subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
      rules = {
        allow-https-in = {
          priority               = 100
          direction              = "Inbound"
          access                 = "Allow"
          protocol               = "Tcp"
          destination_port_range = "443"
          source_address_prefix  = "10.10.0.0/16"
        }
        # The default-deny. Azure's built-in rules allow intra-VNet traffic, so
        # without an explicit deny at a lower priority than the built-ins, a
        # subnet is open to the whole VNet.
        deny-all-in = {
          priority                   = 4096
          direction                  = "Inbound"
          access                     = "Deny"
          protocol                   = "*"
          source_address_prefix      = "*"
          destination_address_prefix = "*"
          destination_port_range     = "*"
        }
      }
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_rule_set" {
  command = plan

  assert {
    condition     = output.rule_count == 2
    error_message = "Both rules must be created."
  }

  assert {
    condition     = contains(output.nsgs_with_explicit_inbound_deny, "aks")
    error_message = "An NSG carrying a catch-all inbound deny must be reported as having one."
  }
}

################################################################################
# The rule inventory reports reach, not just verdict
#
# rules_by_nsg exists to be diffed between environments. That only works if it
# carries WHO a rule admits: "Allow 443 inbound" reads identically whether the
# source is one subnet or the whole internet.
#
# Azure accepts a source as either source_address_prefix or
# source_address_prefixes, and the two forms describe the same policy. The
# inventory collapses them into one list so a diff between an environment using
# the singular form and one using the plural does not report a policy change
# where there is none.
################################################################################

run "the_inventory_carries_each_rules_reach" {
  command = plan

  variables {
    network_security_groups = {
      aks = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          # Singular source, plural destination ports.
          allow-https-in = {
            priority                = 100
            direction               = "Inbound"
            access                  = "Allow"
            protocol                = "Tcp"
            destination_port_ranges = ["80", "443"]
            source_address_prefix   = "10.10.0.0/16"
          }
          # Plural source, singular destination port — the same policy shape
          # expressed the other way round.
          allow-ssh-in = {
            priority                = 120
            direction               = "Inbound"
            access                  = "Allow"
            protocol                = "Tcp"
            destination_port_range  = "22"
            source_address_prefixes = ["10.10.1.0/24", "10.10.2.0/24"]
          }
          deny-all-in = {
            priority                   = 4096
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
    }
  }

  assert {
    condition     = join(",", output.rules_by_nsg["aks"][0].source_address_prefixes) == "10.10.0.0/16"
    error_message = "A rule declaring a single source prefix must report it as a one-element list."
  }

  assert {
    condition     = join(",", output.rules_by_nsg["aks"][0].destination_port_ranges) == "80,443"
    error_message = "A rule declaring plural destination ports must report all of them."
  }

  assert {
    condition     = join(",", output.rules_by_nsg["aks"][1].source_address_prefixes) == "10.10.1.0/24,10.10.2.0/24"
    error_message = "A rule declaring plural source prefixes must report all of them, in the order given."
  }

  assert {
    condition     = join(",", output.rules_by_nsg["aks"][1].destination_port_ranges) == "22"
    error_message = "A rule declaring a single destination port must report it as a one-element list."
  }

  # Evaluation order, not declaration order: the deny at 4096 sorts last.
  assert {
    condition     = output.rules_by_nsg["aks"][2].name == "deny-all-in"
    error_message = "The inventory must be sorted in Azure's evaluation order, so the fallthrough deny is last."
  }
}

################################################################################
# Priority collisions
#
# Two rules at the same priority in one NSG. Azure refuses the second, and the
# error names a rule rather than the collision.
################################################################################

run "rejects_two_rules_at_the_same_priority" {
  command = plan

  variables {
    network_security_groups = {
      aks = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          allow-https-in = {
            priority               = 100
            direction              = "Inbound"
            access                 = "Allow"
            protocol               = "Tcp"
            destination_port_range = "443"
            source_address_prefix  = "10.10.0.0/16"
          }
          allow-redis-in = {
            priority               = 100 # collides
            direction              = "Inbound"
            access                 = "Allow"
            protocol               = "Tcp"
            destination_port_range = "10000"
            source_address_prefix  = "10.10.16.0/20"
          }
          deny-all-in = {
            priority                   = 4096
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_network_security_group.this]
}

run "accepts_the_same_priority_in_different_nsgs" {
  command = plan

  # Priority is scoped to its own NSG. Treating this as a collision would
  # reject a correct configuration, which is how a precondition gets deleted.
  variables {
    network_security_groups = {
      aks = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          deny-all-in = {
            priority                   = 100
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
      pep = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pep"
        rules = {
          deny-all-in = {
            priority                   = 100
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
    }
  }

  assert {
    condition     = output.rule_count == 2
    error_message = "Identical priorities in separate NSGs must both be accepted."
  }
}

################################################################################
# Subnet association conflicts
#
# A subnet carries at most ONE NSG. Associating a second replaces the first
# without warning, so the rules in force are whichever association applied
# last — and a re-apply can silently swap them.
################################################################################

run "rejects_two_nsgs_claiming_one_subnet" {
  command = plan

  variables {
    network_security_groups = {
      first = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          deny-all-in = {
            priority                   = 4096
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
      second = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          deny-all-in = {
            priority                   = 4096
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "*"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_network_security_group.this]
}

################################################################################
# The explicit inbound deny
#
# Azure's built-in rules permit all intra-VNet inbound traffic. Without a
# catch-all deny below them, an NSG that looks like an allowlist permits every
# other subnet in the VNet — which is the difference between a tier boundary
# and the appearance of one.
################################################################################

run "rejects_an_nsg_with_no_catch_all_inbound_deny" {
  command = plan

  variables {
    network_security_groups = {
      aks = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          allow-https-in = {
            priority               = 100
            direction              = "Inbound"
            access                 = "Allow"
            protocol               = "Tcp"
            destination_port_range = "443"
            source_address_prefix  = "10.10.0.0/16"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_network_security_group.this]
}

run "rejects_a_deny_too_narrow_to_be_a_default_deny" {
  command = plan

  # A deny on one port from one source blocks that, and leaves the built-in
  # allow catching everything else. It reads as a default-deny in a diff and is
  # not one.
  variables {
    network_security_groups = {
      aks = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          deny-ssh-in = {
            priority                   = 4096
            direction                  = "Inbound"
            access                     = "Deny"
            protocol                   = "Tcp"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
            destination_port_range     = "22"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_network_security_group.this]
}

run "allows_the_audit_to_be_switched_off" {
  command = plan

  # The check is a policy choice, not a law of Azure, so it is a variable. An
  # NSG holding only outbound rules legitimately has no inbound deny.
  variables {
    require_explicit_inbound_deny = false
    network_security_groups = {
      egress-only = {
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        rules = {
          allow-https-out = {
            priority               = 100
            direction              = "Outbound"
            access                 = "Allow"
            protocol               = "Tcp"
            destination_port_range = "443"
            source_address_prefix  = "*"
          }
        }
      }
    }
  }

  assert {
    condition     = !contains(output.nsgs_with_explicit_inbound_deny, "egress-only")
    error_message = "An NSG with no catch-all inbound deny must be absent from the list of those that have one, even when the audit is switched off."
  }

  assert {
    condition     = output.rule_count == 1
    error_message = "The outbound-only NSG must still be created."
  }
}
