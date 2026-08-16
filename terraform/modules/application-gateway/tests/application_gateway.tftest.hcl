################################################################################
# Unit tests for the application-gateway module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing. That matters here more than in most modules: dev does not deploy an
# Application Gateway — it uses a public load balancer, because AppGW has no
# inexpensive tier — so without mocked tests this module would ship having
# never been exercised beyond `terraform validate`.
#
# What these prove is the module's LOGIC: that every cross-reference check and
# every precondition fires on the input it is meant to catch. What they cannot
# prove is that Azure accepts the resulting API call. That distinction is worth
# holding on to.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "agw-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-app"
  location            = "centralus"
  tags                = { environment = "test" }
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-agw"
  public_ip_name      = "pip-agw-cloudcart-test-cus-001"

  ssl_certificate_key_vault_secret_id = "https://kv-example.vault.azure.net/secrets/tls/abc"
  user_assigned_identity_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-agw"

  backend_pools = { app = {} }

  probes = {
    "app-health" = {
      path               = "/healthz"
      match_status_codes = ["200-399"]
    }
  }

  backend_http_settings = {
    "app-https" = {
      port       = 443
      probe_name = "app-health"
    }
  }

  listeners = {
    "https" = { port = 443, protocol = "Https" }
    "http"  = { port = 80, protocol = "Http" }
  }

  redirect_configurations = {
    "to-https" = { target_listener_name = "https" }
  }

  routing_rules = {
    "https-to-app" = {
      priority                   = 100
      listener_name              = "https"
      backend_pool_name          = "app"
      backend_http_settings_name = "app-https"
    }
    "http-redirect" = {
      priority                    = 110
      listener_name               = "http"
      redirect_configuration_name = "to-https"
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_gateway" {
  command = plan

  assert {
    condition     = output.waf_mode == "Prevention"
    error_message = "Default WAF mode should be Prevention."
  }

  assert {
    condition     = output.uses_key_vault_certificate == true
    error_message = "A Key Vault certificate reference should be reported."
  }

  assert {
    condition     = length(output.settings_without_probe) == 0
    error_message = "All backend settings in this fixture bind an explicit probe."
  }
}

run "reports_missing_zone_redundancy" {
  command = plan

  # No zones supplied in the fixture, so a zone outage takes ingress with it.
  assert {
    condition     = output.is_zone_redundant == false
    error_message = "A gateway with no zones must not report itself zone redundant."
  }
}

run "reports_zone_redundancy_when_configured" {
  command = plan

  variables {
    zones = ["1", "2", "3"]
  }

  assert {
    condition     = output.is_zone_redundant == true
    error_message = "Three zones should report zone redundant."
  }
}

run "flags_backend_settings_with_no_probe" {
  command = plan

  # Without an explicit probe the gateway falls back to a default probe against
  # "/", which returns 404 on most applications and marks every backend
  # unhealthy while the application is fine.
  variables {
    backend_http_settings = {
      "app-https" = { port = 443 }
    }
  }

  assert {
    condition     = contains(output.settings_without_probe, "app-https")
    error_message = "Backend settings with no probe must be reported."
  }
}

################################################################################
# Dangling references
#
# Azure reports each of these as an internal identifier not being found, which
# does not point at the mistake.
################################################################################

run "rejects_rule_referencing_unknown_listener" {
  command = plan

  variables {
    routing_rules = {
      "broken" = {
        priority                   = 100
        listener_name              = "does-not-exist"
        backend_pool_name          = "app"
        backend_http_settings_name = "app-https"
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_rule_referencing_unknown_backend_pool" {
  command = plan

  variables {
    routing_rules = {
      "broken" = {
        priority                   = 100
        listener_name              = "https"
        backend_pool_name          = "does-not-exist"
        backend_http_settings_name = "app-https"
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_rule_referencing_unknown_http_settings" {
  command = plan

  # The only one of the four reference checks with no test. A rule naming
  # backend HTTP settings that do not exist resolves to nothing, and the
  # gateway is created with a rule that routes nowhere.
  variables {
    routing_rules = {
      https = {
        listener_name              = "https"
        backend_pool_name          = "app"
        backend_http_settings_name = "does-not-exist"
        priority                   = 100
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_settings_referencing_unknown_probe" {
  command = plan

  variables {
    backend_http_settings = {
      "app-https" = { port = 443, probe_name = "does-not-exist" }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_redirect_to_unknown_listener" {
  command = plan

  variables {
    redirect_configurations = {
      "to-https" = { target_listener_name = "does-not-exist" }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

################################################################################
# Rule shape
################################################################################

run "rejects_rule_with_both_backend_and_redirect" {
  command = plan

  variables {
    routing_rules = {
      "ambiguous" = {
        priority                    = 100
        listener_name               = "https"
        backend_pool_name           = "app"
        backend_http_settings_name  = "app-https"
        redirect_configuration_name = "to-https"
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_rule_with_no_destination" {
  command = plan

  variables {
    routing_rules = {
      "empty" = {
        priority      = 100
        listener_name = "https"
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_duplicate_rule_priorities" {
  command = plan

  variables {
    routing_rules = {
      "first" = {
        priority                   = 100
        listener_name              = "https"
        backend_pool_name          = "app"
        backend_http_settings_name = "app-https"
      }
      "second" = {
        priority                    = 100
        listener_name               = "http"
        redirect_configuration_name = "to-https"
      }
    }
  }

  expect_failures = [azurerm_application_gateway.this]
}

################################################################################
# TLS
################################################################################

run "rejects_https_listener_without_certificate" {
  command = plan

  variables {
    ssl_certificate_key_vault_secret_id = null
    user_assigned_identity_id           = null
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_certificate_without_identity" {
  command = plan

  # The gateway reads its certificate from Key Vault using a managed identity.
  # Without one, provisioning fails after several minutes.
  variables {
    user_assigned_identity_id = null
  }

  expect_failures = [azurerm_application_gateway.this]
}

################################################################################
# Capacity and WAF
################################################################################

run "rejects_inverted_capacity_bounds" {
  command = plan

  variables {
    min_capacity = 10
    max_capacity = 2
  }

  expect_failures = [azurerm_application_gateway.this]
}

run "rejects_waf_with_request_body_inspection_disabled" {
  command = plan

  # A WAF that does not inspect request bodies is blind to the most common
  # injection vector while appearing active.
  variables {
    waf_request_body_check_enabled = false
  }

  expect_failures = [azurerm_web_application_firewall_policy.this]
}

run "rejects_unknown_sku" {
  command = plan

  variables {
    sku_name = "WAF_v1"
  }

  expect_failures = [var.sku_name]
}
