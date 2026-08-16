################################################################################
# Unit tests for the networking module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# They test the preconditions, not the provider. Asserting that
# azurerm_virtual_network sets an address space would be testing HashiCorp's
# code; asserting that a subnet outside that address space is refused before
# any Azure call is testing ours.
#
# This module is the one every other module binds to, which is why its failures
# are hard to read from where they surface. A subnet that overlaps another, or
# sits outside the VNet, or asks for egress that does not exist, does not
# announce itself as a networking problem — it appears later as a data tier
# that cannot be reached, or a node pool that cannot bootstrap.
################################################################################

mock_provider "azurerm" {}

variables {
  vnet_name           = "vnet-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-net"
  location            = "centralus"
  tags                = { environment = "test" }
  address_space       = ["10.10.0.0/16"]

  subnets = {
    snet-aks = {
      cidr                  = "10.10.16.0/20"
      associate_nat_gateway = true
    }
    snet-pep = {
      cidr                              = "10.10.13.0/24"
      private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
    }
  }

  # Both names default to null and are required once the NAT Gateway is
  # enabled, so a caller that turns egress on without them fails on the
  # resource rather than on a precondition.
  enable_nat_gateway         = true
  nat_gateway_name           = "ng-cloudcart-test-cus-001"
  nat_gateway_public_ip_name = "pip-ng-cloudcart-test-cus-001"
}

################################################################################
# Valid configuration
#
# One coherent case, so that a later failure is attributable to the thing the
# test changed rather than to the baseline being wrong.
################################################################################

run "accepts_a_coherent_network" {
  command = plan

  assert {
    condition     = output.vnet_name == "vnet-cloudcart-test-cus-001"
    error_message = "The VNet name must be passed through unchanged."
  }

  assert {
    condition     = length(output.subnet_ids) == 2
    error_message = "Both subnets must be created."
  }
}

################################################################################
# Subnet coherence
#
# All three of these are accepted by Terraform and rejected by Azure at apply,
# or worse, accepted by both and wrong. Azure cannot resize a subnet that
# contains resources, so a range that overlaps is not a mistake that can be
# corrected in place later.
################################################################################

run "rejects_overlapping_subnets" {
  command = plan

  variables {
    subnets = {
      # 10.10.16.0/20 spans 10.10.16.0 - 10.10.31.255, so a /24 at 10.10.20.0
      # sits inside it. Azure accepts neither, but only at apply.
      snet-aks   = { cidr = "10.10.16.0/20" }
      snet-inner = { cidr = "10.10.20.0/24" }
    }
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "rejects_a_subnet_outside_the_address_space" {
  command = plan

  variables {
    address_space = ["10.10.0.0/16"]
    subnets = {
      # 10.99.x.x is nowhere near the VNet. Terraform is content; the apply
      # fails with a message about the subnet, not about the address space.
      snet-elsewhere = { cidr = "10.99.0.0/24" }
    }
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "accepts_subnets_across_multiple_address_spaces" {
  command = plan

  # The containment check must consider every prefix in address_space, not
  # only the first. Getting this wrong rejects a valid configuration, which is
  # the failure mode that gets a precondition deleted rather than fixed.
  variables {
    address_space = ["10.10.0.0/16", "10.20.0.0/16"]
    subnets = {
      snet-a = { cidr = "10.10.1.0/24" }
      snet-b = { cidr = "10.20.1.0/24" }
    }
  }

  assert {
    condition     = length(output.subnet_ids) == 2
    error_message = "A subnet inside the second address space must be accepted."
  }
}

################################################################################
# Azure-reserved subnet sizes
#
# These names are fixed by Azure and so are their minimum sizes. The service
# deployed into an undersized one fails with an error naming the SERVICE, so
# the failure reads as a Bastion or Firewall problem rather than a /27 that
# should have been a /26.
################################################################################

run "rejects_an_undersized_reserved_subnet" {
  command = plan

  variables {
    subnets = {
      AzureBastionSubnet = { cidr = "10.10.1.0/27" } # requires /26 or larger
    }
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "accepts_a_reserved_subnet_at_its_minimum_size" {
  command = plan

  variables {
    subnets = {
      AzureBastionSubnet = { cidr = "10.10.1.0/26" }
    }
  }

  assert {
    condition     = length(output.subnet_ids) == 1
    error_message = "A reserved subnet at exactly its minimum prefix must be accepted."
  }
}

run "accepts_a_reserved_subnet_larger_than_its_minimum" {
  command = plan

  # A /25 is LARGER than a /26 despite the bigger number, and the comparison
  # is on prefix length, so this is the direction the check is easiest to get
  # backwards.
  variables {
    subnets = {
      AzureBastionSubnet = { cidr = "10.10.1.0/25" }
    }
  }

  assert {
    condition     = length(output.subnet_ids) == 1
    error_message = "A reserved subnet larger than its minimum must be accepted."
  }
}

################################################################################
# NAT Gateway coherence
#
# Both of these produce a subnet with no egress, which is invisible until
# something inside it tries to reach the internet — and then presents as the
# workload failing, not as a routing decision made at build time.
################################################################################

run "rejects_nat_on_a_subnet_that_cannot_take_it" {
  command = plan

  variables {
    subnets = {
      # Bastion manages its own outbound path. Associating a NAT Gateway
      # either fails or breaks the service.
      AzureBastionSubnet = {
        cidr                  = "10.10.1.0/26"
        associate_nat_gateway = true
      }
    }
    enable_nat_gateway = true
  }

  expect_failures = [azurerm_subnet.this]
}

run "rejects_a_nat_request_with_no_nat_gateway" {
  command = plan

  variables {
    subnets = {
      snet-aks = {
        cidr                  = "10.10.16.0/20"
        associate_nat_gateway = true
      }
    }
    # Default outbound access was retired on 2025-09-30, so this subnet would
    # have no internet egress at all rather than falling back to the implicit
    # path.
    enable_nat_gateway = false
  }

  expect_failures = [azurerm_subnet.this]
}

################################################################################
# Egress posture
#
# The module states degraded posture in an output rather than leaving it to be
# inferred, because a subnet with no egress is indistinguishable from one that
# never needed any.
################################################################################

run "reports_subnets_left_without_egress" {
  command = plan

  variables {
    subnets = {
      snet-aks = {
        cidr                  = "10.10.16.0/20"
        associate_nat_gateway = true
      }
      snet-quiet = {
        cidr = "10.10.14.0/24"
      }
    }
    enable_nat_gateway = true
  }

  assert {
    condition     = contains(output.subnets_without_egress, "snet-quiet")
    error_message = "A subnet with neither NAT nor default outbound access must be reported."
  }

  assert {
    condition     = !contains(output.subnets_without_egress, "snet-aks")
    error_message = "A NAT-associated subnet has egress and must not be reported as lacking it."
  }
}

run "reports_every_subnet_when_nat_is_disabled" {
  command = plan

  variables {
    subnets = {
      snet-a = { cidr = "10.10.1.0/24" }
      snet-b = { cidr = "10.10.2.0/24" }
    }
    enable_nat_gateway = false
  }

  assert {
    condition     = length(output.subnets_without_egress) == 2
    error_message = "With no NAT Gateway and no default outbound access, every subnet is without egress."
  }
}
