################################################################################
# Unit tests for the firewall module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing. That matters more here than elsewhere: this module has never been
# applied and cannot be, because an Azure Firewall is roughly $900/month
# against a $200 credit. These tests are the ONLY evidence the module behaves,
# and they are evidence about its logic, not about Azure.
#
# Every precondition under test guards a configuration Azure ACCEPTS or a
# failure whose error names the wrong thing.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "afw-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-net"
  location            = "centralus"
  tags                = { environment = "test" }

  subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallSubnet"
  public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip-afw"

  network_rule_collections = {
    "core-egress" = {
      priority = 200
      action   = "Allow"
      rules = {
        "dns" = {
          protocols             = ["UDP"]
          source_addresses      = ["10.10.0.0/16"]
          destination_addresses = ["168.63.129.16"]
          destination_ports     = ["53"]
        }
      }
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_standard_firewall_with_rules" {
  command = plan

  assert {
    condition     = output.rule_collection_count == 1
    error_message = "One network rule collection was supplied."
  }

  assert {
    condition     = output.rule_count == 1
    error_message = "One rule was supplied."
  }

  assert {
    condition     = output.threat_intelligence_enforces == true
    error_message = "The default threat_intelligence_mode is Deny, which blocks."
  }
}

################################################################################
# Placement
#
# Each of these fails the apply with an error naming the FIREWALL rather than
# the subnet or the address that is actually wrong.
################################################################################

run "rejects_a_subnet_that_is_not_named_AzureFirewallSubnet" {
  command = plan

  variables {
    subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-firewall"
  }

  expect_failures = [azurerm_firewall.this]
}

run "rejects_a_management_subnet_with_the_wrong_name" {
  command = plan

  variables {
    management_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-mgmt"
    management_public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip-mgmt"
  }

  expect_failures = [azurerm_firewall.this]
}

run "rejects_basic_tier_without_a_management_subnet" {
  command = plan

  # Unlike Standard and Premium, Basic ALWAYS needs one.
  variables {
    sku_tier = "Basic"
  }

  expect_failures = [azurerm_firewall.this]
}

run "rejects_a_management_subnet_with_no_public_ip" {
  command = plan

  variables {
    management_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallManagementSubnet"
  }

  expect_failures = [azurerm_firewall.this]
}

run "accepts_basic_tier_with_a_complete_management_plane" {
  command = plan

  variables {
    sku_tier                = "Basic"
    management_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallManagementSubnet"
    management_public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip-mgmt"
  }

  assert {
    condition     = strcontains(output.security_summary, "Basic tier")
    error_message = "The summary should state the deployed tier."
  }
}

################################################################################
# Coverage
#
# A firewall with no rules denies everything. As an egress next hop that is a
# total outage, and the firewall reports healthy throughout.
################################################################################

run "rejects_a_firewall_with_no_rules_at_all" {
  command = plan

  variables {
    network_rule_collections = {}
  }

  expect_failures = [azurerm_firewall.this]
}

run "allows_no_rules_when_acknowledged" {
  command = plan

  variables {
    network_rule_collections = {}
    acknowledge_no_rules     = true
  }

  assert {
    condition     = output.rule_collection_count == 0
    error_message = "No collections were supplied."
  }

  assert {
    condition     = strcontains(output.security_summary, "blackholes all outbound traffic")
    error_message = "A firewall with no rules must say so in plain language, not merely be permitted."
  }
}

################################################################################
# THE ORDERING TRAP
#
# The most valuable test here. Azure evaluates ALL network rules before ANY
# application rule, and the type order cannot be changed by priority — so a
# broad network Allow makes every FQDN rule beneath it unreachable while both
# sets remain visible and correct-looking.
################################################################################

run "rejects_a_broad_network_allow_that_shadows_application_rules" {
  command = plan

  variables {
    network_rule_collections = {
      "too-broad" = {
        priority = 200
        action   = "Allow"
        rules = {
          "all-web" = {
            protocols             = ["TCP"]
            source_addresses      = ["10.10.0.0/16"]
            destination_addresses = ["*"]
            destination_ports     = ["443"]
          }
        }
      }
    }

    application_rule_collections = {
      "fqdn-allowlist" = {
        priority = 300
        action   = "Allow"
        rules = {
          "microsoft" = {
            protocols         = { https = { type = "Https", port = 443 } }
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["*.microsoft.com"]
          }
        }
      }
    }
  }

  expect_failures = [azurerm_firewall_policy_rule_collection_group.this]
}

run "allows_the_shadowing_when_acknowledged" {
  command = plan

  variables {
    acknowledge_broad_network_allow = true

    network_rule_collections = {
      "too-broad" = {
        priority = 200
        action   = "Allow"
        rules = {
          "all-web" = {
            protocols             = ["TCP"]
            source_addresses      = ["10.10.0.0/16"]
            destination_addresses = ["*"]
            destination_ports     = ["443"]
          }
        }
      }
    }

    application_rule_collections = {
      "fqdn-allowlist" = {
        priority = 300
        action   = "Allow"
        rules = {
          "microsoft" = {
            protocols         = { https = { type = "Https", port = 443 } }
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["*.microsoft.com"]
          }
        }
      }
    }
  }

  assert {
    condition     = strcontains(output.security_summary, "shadow the application rules")
    error_message = "Acknowledging the shadowing must not hide it — the summary still has to say the application rules are unreachable."
  }
}

# A narrow network rule does not shadow anything, so the same pair is fine.
run "accepts_a_narrow_network_rule_alongside_application_rules" {
  command = plan

  variables {
    network_rule_collections = {
      "dns-only" = {
        priority = 200
        action   = "Allow"
        rules = {
          "dns" = {
            protocols             = ["UDP"]
            source_addresses      = ["10.10.0.0/16"]
            destination_addresses = ["168.63.129.16"]
            destination_ports     = ["53"]
          }
        }
      }
    }

    application_rule_collections = {
      "fqdn-allowlist" = {
        priority = 300
        action   = "Allow"
        rules = {
          "microsoft" = {
            protocols         = { https = { type = "Https", port = 443 } }
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["*.microsoft.com"]
          }
        }
      }
    }
  }

  assert {
    condition     = output.rule_collection_count == 2
    error_message = "Both collections should deploy."
  }

  assert {
    condition     = !strcontains(output.security_summary, "shadow the application rules")
    error_message = "A narrow network rule must not be reported as shadowing."
  }
}

################################################################################
# FQDNs in network rules need the DNS proxy
################################################################################

run "rejects_fqdn_network_rules_without_the_dns_proxy" {
  command = plan

  variables {
    network_rule_collections = {
      "fqdn-network" = {
        priority = 200
        action   = "Allow"
        rules = {
          "ntp" = {
            protocols         = ["UDP"]
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["time.windows.com"]
            destination_ports = ["123"]
          }
        }
      }
    }
  }

  expect_failures = [azurerm_firewall_policy_rule_collection_group.this]
}

run "accepts_fqdn_network_rules_with_the_dns_proxy" {
  command = plan

  variables {
    dns_proxy_enabled = true

    network_rule_collections = {
      "fqdn-network" = {
        priority = 200
        action   = "Allow"
        rules = {
          "ntp" = {
            protocols         = ["UDP"]
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["time.windows.com"]
            destination_ports = ["123"]
          }
        }
      }
    }
  }

  assert {
    condition     = strcontains(output.security_summary, "DNS proxy on")
    error_message = "The proxy state should be reported."
  }
}

################################################################################
# Premium-only capabilities
#
# Naming a capability the deployed tier cannot provide is worse than omitting
# it: a reader concludes the traffic is inspected.
################################################################################

run "rejects_idps_on_a_standard_firewall" {
  command = plan

  variables {
    sku_tier                 = "Standard"
    intrusion_detection_mode = "Deny"
  }

  expect_failures = [azurerm_firewall_policy.this]
}

run "accepts_idps_on_a_premium_firewall" {
  command = plan

  variables {
    sku_tier                 = "Premium"
    intrusion_detection_mode = "Deny"
  }

  assert {
    condition     = output.intrusion_detection_enforces == true
    error_message = "IDPS in Deny mode on Premium blocks signature matches."
  }
}

run "reports_idps_in_alert_mode_as_not_enforcing" {
  command = plan

  variables {
    sku_tier                 = "Premium"
    intrusion_detection_mode = "Alert"
  }

  assert {
    condition     = output.intrusion_detection_enforces == false
    error_message = "Alert mode logs signature matches and allows them through."
  }

  assert {
    condition     = strcontains(output.security_summary, "it does not block")
    error_message = "Alert mode must be reported as not blocking, since it reads as enabled."
  }
}

run "rejects_tls_termination_on_a_standard_firewall" {
  command = plan

  variables {
    sku_tier = "Standard"

    application_rule_collections = {
      "inspected" = {
        priority = 300
        action   = "Allow"
        rules = {
          "microsoft" = {
            protocols         = { https = { type = "Https", port = 443 } }
            source_addresses  = ["10.10.0.0/16"]
            destination_fqdns = ["*.microsoft.com"]
            terminate_tls     = true
          }
        }
      }
    }
  }

  expect_failures = [azurerm_firewall_policy.this]
}

################################################################################
# Threat intelligence
################################################################################

run "reports_alert_mode_threat_intelligence_as_not_blocking" {
  command = plan

  variables {
    threat_intelligence_mode = "Alert"
  }

  assert {
    condition     = output.threat_intelligence_enforces == false
    error_message = "Alert mode logs and permits; it does not block."
  }

  assert {
    condition     = strcontains(output.security_summary, "threat intelligence is \"Alert\"")
    error_message = "The summary must name the mode, because Alert reports as enabled while blocking nothing."
  }
}

################################################################################
# Priorities
################################################################################

run "rejects_duplicate_priorities_within_a_type" {
  command = plan

  # Azure rejects this with an error naming neither collection.
  variables {
    network_rule_collections = {
      "first" = {
        priority = 200
        action   = "Allow"
        rules = {
          "dns" = {
            protocols             = ["UDP"]
            source_addresses      = ["10.10.0.0/16"]
            destination_addresses = ["168.63.129.16"]
            destination_ports     = ["53"]
          }
        }
      }
      "second" = {
        priority = 200
        action   = "Allow"
        rules = {
          "ntp" = {
            protocols             = ["UDP"]
            source_addresses      = ["10.10.0.0/16"]
            destination_addresses = ["10.0.0.0/8"]
            destination_ports     = ["123"]
          }
        }
      }
    }
  }

  expect_failures = [azurerm_firewall_policy_rule_collection_group.this]
}

################################################################################
# Availability and cost posture
################################################################################

run "reports_a_single_zone_as_not_redundant" {
  command = plan

  variables {
    zones = ["1"]
  }

  assert {
    condition     = output.is_zone_redundant == false
    error_message = "One zone is a zonal deployment with no redundancy."
  }

  assert {
    condition     = strcontains(output.security_summary, "NOT zone redundant")
    error_message = "A single zone reads like zone-awareness and must be reported as not redundant."
  }
}

run "reports_zone_redundancy_and_its_cost" {
  command = plan

  variables {
    zones = ["1", "2", "3"]
  }

  assert {
    condition     = output.is_zone_redundant == true
    error_message = "Three zones is zone redundant."
  }

  assert {
    condition     = strcontains(output.security_summary, "cross-zone data transfer is billed")
    error_message = "Zones are free; the traffic crossing them is not, and that should not be discovered on a bill."
  }
}

run "prices_premium_above_standard" {
  command = plan

  variables {
    sku_tier = "Premium"
  }

  assert {
    condition     = output.indicative_monthly_cost_usd > 1200
    error_message = "Premium is roughly $1,278/month for deployment hours alone."
  }
}
