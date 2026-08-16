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
