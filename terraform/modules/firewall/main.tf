################################################################################
# Firewall policy
#
# The policy holds the rules; the firewall holds the addresses. Separating them
# is not decoration — a policy can be shared by several firewalls and inherited
# by child policies, and rules can be changed without touching the resource
# that owns the public IP.
#
# The classic azurerm_firewall_network_rule_collection family is deliberately
# NOT used. Those attach rules directly to the firewall, cannot be shared, and
# are the model Azure moved away from; IDPS and TLS inspection exist only on
# the policy path.
################################################################################

resource "azurerm_firewall_policy" "this" {
  name                = "afwp-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  sku = var.sku_tier

  threat_intelligence_mode = var.threat_intelligence_mode

  private_ip_ranges = length(var.private_ip_ranges) > 0 ? var.private_ip_ranges : null

  dynamic "dns" {
    for_each = var.dns_proxy_enabled || length(var.dns_servers) > 0 ? [1] : []

    content {
      proxy_enabled = var.dns_proxy_enabled
      servers       = length(var.dns_servers) > 0 ? var.dns_servers : null
    }
  }

  # Premium only. A precondition below rejects it on a lower tier rather than
  # letting the configuration claim intrusion prevention it does not have.
  dynamic "intrusion_detection" {
    for_each = var.intrusion_detection_mode != null ? [1] : []

    content {
      mode = var.intrusion_detection_mode
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.idps_without_premium
      error_message = join(" ", [
        "intrusion_detection_mode is set to \"${coalesce(var.intrusion_detection_mode, "null")}\" but sku_tier is \"${var.sku_tier}\".",
        "IDPS is a PREMIUM-only capability.",
        "The configuration names intrusion prevention that the deployed tier cannot provide, which is worse than not configuring it —",
        "a reader concludes the traffic is inspected.",
        "Either set sku_tier = \"Premium\" (roughly $365/month more) or leave intrusion_detection_mode null."
      ])
    }

    precondition {
      condition = !local.tls_inspection_without_premium
      error_message = join(" ", [
        "These application rules set terminate_tls but sku_tier is \"${var.sku_tier}\": ${join(", ", local.tls_terminating_rules)}.",
        "TLS inspection is PREMIUM-only. On a lower tier the traffic passes through uninspected while the rule reads as though it were examined."
      ])
    }
  }
}

################################################################################
# Firewall
#
# AzureFirewallSubnet must be named exactly that and be /26 or larger. The
# public IP must be Standard SKU and Static; Azure rejects Basic or Dynamic
# with an error that does not identify which property is wrong.
################################################################################

resource "azurerm_firewall" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku_name = var.sku_name
  sku_tier = var.sku_tier

  firewall_policy_id = azurerm_firewall_policy.this.id

  zones = length(var.zones) > 0 ? var.zones : null

  ip_configuration {
    name                 = "ipc-${var.name}"
    subnet_id            = var.subnet_id
    public_ip_address_id = var.public_ip_id
  }

  # Required for the Basic tier and for forced tunnelling. The management plane
  # needs its own subnet and its own address; it cannot share the data path.
  dynamic "management_ip_configuration" {
    for_each = local.has_management_plane ? [1] : []

    content {
      name                 = "ipc-mgmt-${var.name}"
      subnet_id            = var.management_subnet_id
      public_ip_address_id = var.management_public_ip_id
    }
  }

  tags = var.tags

  lifecycle {
    ############################################################################
    # Placement. Each of these fails the apply with an error naming the
    # firewall rather than the thing that is actually wrong.
    ############################################################################
    precondition {
      condition = !local.subnet_is_misnamed
      error_message = join(" ", [
        "subnet_id points at a subnet named \"${coalesce(local.subnet_name, "null")}\".",
        "Azure requires the firewall's subnet to be named EXACTLY \"AzureFirewallSubnet\", and to be /26 or larger.",
        "The API rejects any other name with an error that names the FIREWALL, so the failure reads as a firewall problem rather than a subnet one."
      ])
    }

    precondition {
      condition = !local.management_subnet_is_misnamed
      error_message = join(" ", [
        "management_subnet_id points at a subnet named \"${coalesce(local.management_subnet_name, "null")}\".",
        "It must be named EXACTLY \"AzureFirewallManagementSubnet\"."
      ])
    }

    precondition {
      condition = !local.basic_without_management
      error_message = join(" ", [
        "sku_tier is \"Basic\" but no management_subnet_id was supplied.",
        "The Basic tier ALWAYS requires a separate AzureFirewallManagementSubnet and its own public IP — unlike Standard and Premium, where they are needed only for forced tunnelling.",
        "The apply fails without naming the missing subnet."
      ])
    }

    precondition {
      condition = !local.management_subnet_without_ip
      error_message = join(" ", [
        "management_subnet_id is set but management_public_ip_id is null.",
        "The management plane requires its own public IP and cannot share the data-plane address."
      ])
    }

    ############################################################################
    # Coverage
    ############################################################################
    precondition {
      condition = !local.deployed_without_rules
      error_message = join(" ", [
        "No rule collections were supplied, and an Azure Firewall DENIES BY DEFAULT.",
        "Once a route table sends 0.0.0.0/0 here, this firewall blackholes ALL egress:",
        "no DNS, no package repositories, no container registries.",
        "AKS nodes fail to bootstrap and the cluster never converges, while the firewall reports healthy and the portal shows a correctly provisioned resource.",
        "Supply rules, or set acknowledge_no_rules = true if they land in a later apply."
      ])
    }
  }
}

################################################################################
# Rules
#
# ORDER MATTERS AND IS NOT YOURS TO CHOOSE. Azure evaluates rule collections by
# TYPE before priority:
#
#   NAT  ->  network  ->  application
#
# so a broad network Allow shadows every application rule beneath it. That is
# what the first precondition below exists for, and it is the most common way
# an Azure Firewall permits what its configuration appears to forbid.
################################################################################

resource "azurerm_firewall_policy_rule_collection_group" "this" {
  count = local.has_any_rules ? 1 : 0

  name               = "afwrcg-${var.name}"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = var.rule_collection_group_priority

  dynamic "nat_rule_collection" {
    for_each = var.nat_rule_collections

    content {
      name     = nat_rule_collection.key
      priority = nat_rule_collection.value.priority
      action   = "Dnat"

      dynamic "rule" {
        for_each = nat_rule_collection.value.rules

        content {
          name               = rule.key
          description        = rule.value.description
          protocols          = rule.value.protocols
          source_addresses   = length(rule.value.source_addresses) > 0 ? rule.value.source_addresses : null
          source_ip_groups   = length(rule.value.source_ip_groups) > 0 ? rule.value.source_ip_groups : null
          destination_ports  = length(rule.value.destination_ports) > 0 ? rule.value.destination_ports : null
          translated_port    = rule.value.translated_port
          translated_address = rule.value.translated_address
          translated_fqdn    = rule.value.translated_fqdn
        }
      }
    }
  }

  dynamic "network_rule_collection" {
    for_each = var.network_rule_collections

    content {
      name     = network_rule_collection.key
      priority = network_rule_collection.value.priority
      action   = network_rule_collection.value.action

      dynamic "rule" {
        for_each = network_rule_collection.value.rules

        content {
          name                  = rule.key
          description           = rule.value.description
          protocols             = rule.value.protocols
          source_addresses      = length(rule.value.source_addresses) > 0 ? rule.value.source_addresses : null
          source_ip_groups      = length(rule.value.source_ip_groups) > 0 ? rule.value.source_ip_groups : null
          destination_addresses = length(rule.value.destination_addresses) > 0 ? rule.value.destination_addresses : null
          destination_fqdns     = length(rule.value.destination_fqdns) > 0 ? rule.value.destination_fqdns : null
          destination_ip_groups = length(rule.value.destination_ip_groups) > 0 ? rule.value.destination_ip_groups : null
          destination_ports     = rule.value.destination_ports
        }
      }
    }
  }

  dynamic "application_rule_collection" {
    for_each = var.application_rule_collections

    content {
      name     = application_rule_collection.key
      priority = application_rule_collection.value.priority
      action   = application_rule_collection.value.action

      dynamic "rule" {
        for_each = application_rule_collection.value.rules

        content {
          name                  = rule.key
          description           = rule.value.description
          source_addresses      = length(rule.value.source_addresses) > 0 ? rule.value.source_addresses : null
          source_ip_groups      = length(rule.value.source_ip_groups) > 0 ? rule.value.source_ip_groups : null
          destination_fqdns     = length(rule.value.destination_fqdns) > 0 ? rule.value.destination_fqdns : null
          destination_fqdn_tags = length(rule.value.destination_fqdn_tags) > 0 ? rule.value.destination_fqdn_tags : null
          destination_urls      = length(rule.value.destination_urls) > 0 ? rule.value.destination_urls : null
          web_categories        = length(rule.value.web_categories) > 0 ? rule.value.web_categories : null
          terminate_tls         = rule.value.terminate_tls

          dynamic "protocols" {
            for_each = rule.value.protocols

            content {
              type = protocols.value.type
              port = protocols.value.port
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition = !local.network_rules_shadow_application_rules
      error_message = join(" ", [
        "These ALLOW network rules match a wildcard destination on a port the application rules also serve: ${join(", ", local.broad_network_allows)}.",
        "Azure evaluates ALL network rules before ANY application rule, and the type order cannot be changed by priority.",
        "Traffic therefore matches the network rule and leaves WITHOUT FQDN filtering —",
        "every application rule below becomes unreachable while remaining visible and correct-looking in the portal.",
        "This is the most common way an Azure Firewall permits what its configuration appears to forbid.",
        "Narrow the network rule's destination or ports, or set acknowledge_broad_network_allow = true if the shadowing is deliberate."
      ])
    }

    precondition {
      condition = !local.fqdn_network_rules_without_dns_proxy
      error_message = join(" ", [
        "These NETWORK rules use destination_fqdns while dns_proxy_enabled is false: ${join(", ", local.network_rules_using_fqdns)}.",
        "An FQDN in a network rule is resolved by the firewall itself, so without the DNS proxy there is nothing to resolve it.",
        "Azure accepts the rule, displays it as configured, and it matches no traffic.",
        "Set dns_proxy_enabled = true, or express the rule as an APPLICATION rule, which resolves FQDNs differently and does not need the proxy."
      ])
    }

    precondition {
      condition = !local.has_duplicate_priorities
      error_message = join(" ", [
        "Two rule collections of the same type share a priority.",
        "Azure rejects this with an error naming neither collection.",
        "Priorities must be unique within each of the three types; they do not need to be unique across types, because the types are evaluated in a fixed order regardless."
      ])
    }
  }
}
