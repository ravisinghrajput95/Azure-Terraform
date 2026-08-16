################################################################################
# Unit tests for the load-balancer module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# This module is DEPLOYED NOWHERE. Both load balancers were built and then
# destroyed: AKS provisions and manages its own for a Service of type
# LoadBalancer, so keeping them cost roughly $40/month for nothing
# (ARCHITECTURE.md §6b). The module remains in the repository, unused.
#
# That makes these tests the only thing exercising it. An unused module that
# has never been tested is configuration nobody has checked, waiting for
# whoever needs an internal load balancer next.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "lbi-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-app"
  location            = "centralus"
  tags                = { environment = "test" }

  type      = "internal"
  subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-biz"

  backend_pools = ["default"]
  probes = {
    https = {
      protocol     = "Http"
      port         = 8080
      request_path = "/healthz"
    }
  }
  rules = {
    https = {
      frontend_port     = 443
      backend_port      = 8443
      backend_pool_name = "default"
      probe_name        = "https"
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_internal_load_balancer" {
  command = plan

  assert {
    condition     = output.type == "internal"
    error_message = "The type must be reported as configured."
  }

  assert {
    condition     = length(output.probe_ids) == 1
    error_message = "The probe must be created."
  }
}

################################################################################
# Frontend shape follows the type
#
# An internal load balancer takes a subnet and no public IP; a public one takes
# a public IP and no subnet. Each wrong combination is a different resource
# shape, not a setting.
################################################################################

run "rejects_an_internal_lb_with_no_subnet" {
  command = plan

  variables {
    type      = "internal"
    subnet_id = null
  }

  expect_failures = [azurerm_lb.this]
}

run "rejects_an_internal_lb_given_a_public_ip" {
  command = plan

  variables {
    type           = "internal"
    public_ip_name = "pip-lb-cloudcart-test-cus-001"
  }

  expect_failures = [azurerm_lb.this]
}

# NOT TESTED: a public load balancer with no public_ip_name.
#
# The module has a precondition for it (`!local.public_missing_ip_name`) with a
# clearer message than Terraform's, but it can never fire. azurerm_public_ip is
# created for every public load balancer and its `name` is that same null
# variable, so Terraform rejects the resource with "Missing required argument"
# before preconditions are evaluated. expect_failures cannot express it either:
# it takes checkable objects, and a missing required argument is a schema error.
#
# This is the SECOND module with a precondition shadowed this way — bastion has
# the identical pattern for the identical reason. The configuration is still
# refused before any Azure call in both; what is lost is the better message.

run "rejects_a_public_lb_given_a_subnet" {
  command = plan

  variables {
    type           = "public"
    subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-biz"
    public_ip_name = "pip-lb-cloudcart-test-cus-001"
  }

  expect_failures = [azurerm_lb.this]
}

run "accepts_a_coherent_public_load_balancer" {
  command = plan

  variables {
    type           = "public"
    subnet_id      = null
    public_ip_name = "pip-lb-cloudcart-test-cus-001"
  }

  assert {
    condition     = output.type == "public"
    error_message = "A coherent public load balancer must be accepted."
  }
}

################################################################################
# Rules referencing things that do not exist
#
# A rule naming a probe or pool that was never defined does not fail loudly.
# Terraform resolves it to nothing and the rule is created against a frontend
# with no health check behind it.
################################################################################

run "rejects_a_rule_referencing_an_unknown_probe" {
  command = plan

  variables {
    probes = {
      https = { protocol = "Http", port = 8080, request_path = "/healthz" }
    }
    rules = {
      https = {
        frontend_port     = 443
        backend_port      = 8443
        backend_pool_name = "default"
        probe_name        = "typo"
      }
    }
  }

  expect_failures = [azurerm_lb.this]
}

run "rejects_a_rule_referencing_an_unknown_backend_pool" {
  command = plan

  variables {
    rules = {
      https = {
        frontend_port     = 443
        backend_port      = 8443
        backend_pool_name = "does-not-exist"
        probe_name        = "https"
      }
    }
  }

  expect_failures = [azurerm_lb.this]
}

################################################################################
# Health probe posture
#
# A TCP probe completes a handshake. An application returning 500 to every
# request still accepts connections, so the probe reports healthy while every
# request fails. Reported rather than refused: TCP is correct for a
# non-HTTP backend.
################################################################################

run "reports_tcp_only_probes" {
  command = plan

  variables {
    probes = {
      tcp = { protocol = "Tcp", port = 8443 }
    }
    rules = {
      https = {
        frontend_port     = 443
        backend_port      = 8443
        backend_pool_name = "default"
        probe_name        = "tcp"
      }
    }
  }

  assert {
    condition     = contains(output.tcp_only_probes, "tcp")
    error_message = "A TCP probe cannot see an application failure and must be reported as such."
  }
}

run "reports_how_long_a_dead_instance_keeps_traffic" {
  command = plan

  # interval x threshold is the window in which a dead backend still receives
  # requests. It is arithmetic nobody does under incident pressure.
  variables {
    probes = {
      slow = {
        protocol            = "Http"
        port                = 8080
        request_path        = "/healthz"
        interval_in_seconds = 15
        probe_threshold     = 4
      }
    }
    rules = {
      https = {
        frontend_port     = 443
        backend_port      = 8443
        backend_pool_name = "default"
        probe_name        = "slow"
      }
    }
  }

  assert {
    condition     = output.probe_detection_seconds["slow"] == 60
    error_message = "Detection time must be reported as interval x threshold."
  }
}

################################################################################
# Unused declarations
################################################################################

run "reports_a_backend_pool_no_rule_uses" {
  command = plan

  variables {
    backend_pools = ["default", "spare"]
  }

  assert {
    condition     = contains(output.unused_backend_pools, "spare")
    error_message = "A pool no rule references receives no traffic and must be reported."
  }
}

run "reports_a_probe_no_rule_uses" {
  command = plan

  variables {
    probes = {
      https  = { protocol = "Http", port = 8080, request_path = "/healthz" }
      unused = { protocol = "Http", port = 9090, request_path = "/healthz" }
    }
  }

  assert {
    condition     = contains(output.orphaned_probes, "unused")
    error_message = "A probe no rule references checks nothing and must be reported."
  }
}
