################################################################################
# Unit tests for the route-table module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# ARCHITECTURE.md §2 names route tables as the fastest way to cause a total
# environment outage: they apply in seconds and there is no health check. The
# two failures guarded here are both accepted by Azure and both take down a
# service that has nothing obviously wrong with it.
################################################################################

mock_provider "azurerm" {}

variables {
  resource_group_name = "rg-cloudcart-test-cus-net"
  location            = "centralus"
  tags                = { environment = "test" }

  route_tables = {
    workload = {
      subnets = {
        snet-aks = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
      }
      routes = {
        default-to-firewall = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = "10.10.0.4"
        }
      }
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_route_table" {
  command = plan

  assert {
    condition     = output.route_count == 1
    error_message = "The route must be created."
  }

  assert {
    condition     = contains(output.tables_with_default_route, "workload")
    error_message = "A table carrying 0.0.0.0/0 must be reported as carrying a default route."
  }
}

################################################################################
# The default route on a subnet that cannot take one
#
# Application Gateway v2 needs direct outbound access to its control plane, and
# Bastion needs direct outbound connectivity. Forcing either through a firewall
# with a 0.0.0.0/0 route does not fail the apply — the gateway goes unhealthy,
# or Bastion sessions drop, minutes later and for no visible reason.
################################################################################

run "rejects_a_default_route_on_bastion_subnet" {
  command = plan

  variables {
    route_tables = {
      workload = {
        subnets = {
          AzureBastionSubnet = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureBastionSubnet"
        }
        routes = {
          default-to-firewall = {
            address_prefix         = "0.0.0.0/0"
            next_hop_type          = "VirtualAppliance"
            next_hop_in_ip_address = "10.10.0.4"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_subnet_route_table_association.this]
}

run "rejects_a_default_route_on_a_caller_named_subnet" {
  command = plan

  # The Application Gateway subnet name varies per environment, so it cannot be
  # in the module's default list. The check has to honour additions from the
  # caller or it protects only the Azure-reserved names.
  variables {
    subnets_forbidding_default_route = ["snet-agw"]
    route_tables = {
      workload = {
        subnets = {
          snet-agw = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-agw"
        }
        routes = {
          default-to-firewall = {
            address_prefix         = "0.0.0.0/0"
            next_hop_type          = "VirtualAppliance"
            next_hop_in_ip_address = "10.10.0.4"
          }
        }
      }
    }
  }

  expect_failures = [azurerm_subnet_route_table_association.this]
}

run "accepts_a_forbidden_subnet_on_a_table_with_no_default_route" {
  command = plan

  # AzureBastionSubnet may carry a route table. What it must not carry is a
  # 0.0.0.0/0 route. Refusing the association outright would reject a valid
  # configuration.
  variables {
    route_tables = {
      specific = {
        subnets = {
          AzureBastionSubnet = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureBastionSubnet"
        }
        routes = {
          to-onprem = {
            address_prefix         = "192.168.0.0/16"
            next_hop_type          = "VirtualAppliance"
            next_hop_in_ip_address = "10.10.0.4"
          }
        }
      }
    }
  }

  assert {
    condition     = length(output.tables_with_default_route) == 0
    error_message = "A table with no 0.0.0.0/0 route must not be reported as carrying a default route."
  }
}

################################################################################
# Duplicate subnet claims
#
# Azure permits at most one route table per subnet. A second association
# replaces the first, so the routes in force are whichever applied last.
################################################################################

run "rejects_two_tables_claiming_one_subnet" {
  command = plan

  variables {
    route_tables = {
      first = {
        subnets = {
          snet-aks = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        }
        routes = {}
      }
      second = {
        subnets = {
          snet-aks = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        }
        routes = {}
      }
    }
  }

  expect_failures = [azurerm_route_table.this]
}

################################################################################
# A table with no routes is still meaningful
################################################################################

run "accepts_a_table_with_no_routes" {
  command = plan

  # Disabling BGP propagation is itself a control, so an empty table is a
  # legitimate configuration rather than an oversight — but it is reported, in
  # case it was one.
  variables {
    route_tables = {
      empty = {
        bgp_route_propagation_enabled = false
        subnets                       = {}
        routes                        = {}
      }
    }
  }

  assert {
    condition     = contains(output.tables_without_routes, "empty")
    error_message = "A table with no routes must be reported, since it is indistinguishable from a forgotten one."
  }

  assert {
    condition     = output.route_count == 0
    error_message = "An empty table creates no routes."
  }
}

################################################################################
# Next-hop containment
#
# The failure that motivated this: stage's test file pinned prod's firewall
# address and prod's pinned stage's, exactly transposed. Nothing objected. Azure
# accepts a next hop outside the VNet, because that is how a peered appliance is
# named, so the plan was clean and the "a default route exists" assertion passed
# while every workload packet was being handed to an address that does not exist
# in that network.
#
# The baseline variables above pair 10.10.0.4 with no address space, so each of
# these runs supplies both halves explicitly.
################################################################################

run "accepts_a_next_hop_inside_the_vnet" {
  command = plan

  variables {
    vnet_address_space = ["10.10.0.0/16"]
  }

  assert {
    condition     = output.next_hop_containment_checked
    error_message = "With an address space supplied the check must actually run. False here means it was skipped, which is the state this output exists to distinguish from a pass."
  }

  assert {
    condition     = output.virtual_appliance_next_hops["workload/default-to-firewall"] == "10.10.0.4"
    error_message = "The next hop must be reported so it can be read against the address plan."
  }
}

# The transposition, reproduced: a next hop from a sibling environment's range.
run "rejects_a_next_hop_from_another_vnet" {
  command = plan

  variables {
    vnet_address_space = ["10.10.0.0/16"]

    route_tables = {
      workload = {
        subnets = {
          snet-aks = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-aks"
        }
        routes = {
          default-to-firewall = {
            address_prefix = "0.0.0.0/0"
            next_hop_type  = "VirtualAppliance"
            # stage's range, on an environment addressed 10.10.0.0/16.
            next_hop_in_ip_address = "10.40.0.4"
          }
        }
      }
    }
  }

  expect_failures = [
    azurerm_route.this,
  ]
}

# Boundary case: the containment test masks the address with the PREFIX's own
# length, so it has to respect that length rather than comparing leading octets.
# 10.10.5.4 is inside 10.10.0.0/16 and outside 10.10.0.0/24, and a check that
# compared the first two octets would wave it through.
run "rejects_a_next_hop_outside_a_narrower_prefix" {
  command = plan

  variables {
    vnet_address_space = ["10.10.0.0/24"]

    route_tables = {
      workload = {
        subnets = {}
        routes = {
          default-to-firewall = {
            address_prefix         = "0.0.0.0/0"
            next_hop_type          = "VirtualAppliance"
            next_hop_in_ip_address = "10.10.5.4"
          }
        }
      }
    }
  }

  expect_failures = [
    azurerm_route.this,
  ]
}

run "accepts_a_next_hop_in_any_of_several_address_spaces" {
  command = plan

  # A VNet may carry more than one prefix, and the next hop needs to be inside
  # only one of them.
  variables {
    vnet_address_space = ["192.168.0.0/16", "10.10.0.0/16"]
  }

  assert {
    condition     = output.next_hop_containment_checked
    error_message = "Multiple address spaces must still arm the check."
  }
}

# The escape hatch, and the reason the module reports whether it ran. A
# hub-and-spoke deployment legitimately points at an appliance in a peered VNet,
# so an empty address space is permitted — but it must be visible as a check
# that did not happen rather than one that passed.
run "an_empty_address_space_skips_the_check_and_says_so" {
  command = plan

  variables {
    vnet_address_space = []
  }

  assert {
    condition     = !output.next_hop_containment_checked
    error_message = "An empty address space must report the check as NOT performed. Reporting true here would claim verification that never happened."
  }

  assert {
    condition     = length(output.virtual_appliance_next_hops) == 1
    error_message = "The next hops must still be reported when the check is skipped — that list is the only way to review them by hand."
  }
}

# Non-VirtualAppliance routes carry no next-hop address at all, so there is
# nothing to contain and the check must not invent a violation.
run "routes_without_an_appliance_next_hop_are_not_checked" {
  command = plan

  variables {
    vnet_address_space = ["10.10.0.0/16"]

    route_tables = {
      workload = {
        subnets = {}
        routes = {
          keep-vnet-local = {
            address_prefix = "10.10.0.0/16"
            next_hop_type  = "VnetLocal"
          }
        }
      }
    }
  }

  assert {
    condition     = length(output.virtual_appliance_next_hops) == 0
    error_message = "A VnetLocal route has no next-hop address, so it must not appear as one."
  }
}
