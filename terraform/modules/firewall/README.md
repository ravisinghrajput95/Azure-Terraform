# firewall

Azure Firewall, its policy, and one rule collection group.

> **NEVER APPLIED, AND NOT APPLICABLE ON THIS SUBSCRIPTION.**
>
> An Azure Firewall costs roughly **$900/month** (Standard) or **$1,278/month**
> (Premium) for deployment hours alone, before data processing, against a $200
> credit. Every claim in this document is a claim about the configuration and
> its tests. None of it has been observed against a running firewall.
>
> This is exactly the "configuration that looked correct and had never run"
> that `docs/ARCHITECTURE.md` §6 says was rejected for `recovery-services`.
> The difference is that a Recovery Services vault is free and could therefore
> be deployed to prove it; a firewall cannot. The honest position is to label
> it rather than to imply parity with the modules that have run.

Written because `stage` and `prod` both set `enable_firewall = true` and
`enable_nat_gateway = false` in the `profile` module — their egress strategy is
this module, and neither environment could be composed without it.

`dev` and `qa` use a NAT Gateway instead (~$35/month), which is why
`ARCHITECTURE.md` §6c says the platform has no egress filtering today.

---

## Everything this module can get wrong is silent, and one thing is worse

A firewall that permits what its configuration appears to forbid still reports
healthy, still shows every rule in the portal, and still passes an inspection
that reads the rules without knowing how they are evaluated.

### The ordering trap — the reason this module has preconditions at all

Azure Firewall evaluates rule collections by **type** first and priority
second, and the type order is fixed:

```
NAT rules  ->  network rules  ->  application rules
```

Priority orders collections *within* a type. It cannot reorder the types. So
this configuration:

```hcl
network_rule_collections = {
  "web-egress" = {
    priority = 200
    rules = { "all" = { protocols = ["TCP"], destination_addresses = ["*"], destination_ports = ["443"] } }
  }
}

application_rule_collections = {
  "fqdn-allowlist" = {
    priority = 300              # LOWER precedence, and it does not matter
    rules = { "ms" = { destination_fqdns = ["*.microsoft.com"] } }
  }
}
```

...permits **all** HTTPS to **anywhere**. The FQDN allow-list is never
consulted, because the network rule matched first. Both rule sets exist, both
display as configured, and the firewall is doing precisely what Azure
documents.

This is the most common way an Azure Firewall ends up as an expensive NAT
device. A precondition rejects the combination; `acknowledge_broad_network_allow`
permits it where it is deliberate, and the `security_summary` output keeps
saying so afterwards rather than going quiet once acknowledged.

### FQDNs in network rules need the DNS proxy

`destination_fqdns` on a **network** rule is resolved by the firewall itself.
With `dns_proxy_enabled = false` there is nothing to resolve it: Azure accepts
the rule, displays it, and it matches no traffic ever.

Application rules resolve FQDNs by a different mechanism and do not need the
proxy — so the same intent expressed as an application rule works, which is
what makes the network-rule version so easy to get wrong.

### A firewall with no rules is a total egress outage

Azure Firewall denies by default. Deploy one, point `0.0.0.0/0` at it from a
route table, ship zero rules, and **everything** outbound stops: DNS, package
repositories, container registries. AKS nodes fail to bootstrap and the cluster
never converges — the same crash-loop shape described in `ARCHITECTURE.md` §6b,
from a different cause.

The firewall reports healthy throughout. Rejected unless
`acknowledge_no_rules = true`.

### Premium-only capabilities named on a cheaper tier

`intrusion_detection_mode` (IDPS) and `terminate_tls` (TLS inspection) exist
only on **Premium**. Naming either on Standard or Basic is worse than omitting
it: a reader of the configuration concludes the traffic is inspected. Both are
rejected.

### Modes that report as enabled and block nothing

| Setting | Deceptive value | What it actually does |
|---|---|---|
| `threat_intelligence_mode` | `"Alert"` | Logs traffic to known-malicious addresses and **lets it through** |
| `intrusion_detection_mode` | `"Alert"` | Logs signature matches and **lets them through** |

Neither is rejected — both are legitimate while tuning — but
`threat_intelligence_enforces` and `intrusion_detection_enforces` are booleans
that say plainly whether anything is being blocked.

### Subnet names Azure will not negotiate

| Subnet | Required name |
|---|---|
| Data plane | `AzureFirewallSubnet`, /26 or larger |
| Management plane | `AzureFirewallManagementSubnet` |

A wrong name is rejected with an error naming the **firewall**, which sends
people to read the firewall configuration for a subnet problem. Both names are
checked at plan time by parsing the subnet ID, so the failure arrives before
any Azure call.

The management subnet is **always** required for the Basic tier — not only for
forced tunnelling, which is the case people remember.

---

## Policy, not classic rules

This module uses `azurerm_firewall_policy` plus
`azurerm_firewall_policy_rule_collection_group`, never the classic
`azurerm_firewall_network_rule_collection` family. Classic rules attach
directly to the firewall, cannot be shared or inherited, and — decisively —
IDPS and TLS inspection exist only on the policy path.

---

## Usage

```hcl
module "firewall" {
  source = "../../modules/firewall"

  name                = module.naming.names.firewall
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_tier = module.profile.profile.firewall_sku_tier
  zones    = module.profile.profile.compute_zones

  subnet_id    = module.networking.subnet_ids["AzureFirewallSubnet"]
  public_ip_id = module.public_ip.ids["firewall"]

  # Required because the network rules below use FQDNs.
  dns_proxy_enabled = true

  network_rule_collections = {
    "platform-egress" = {
      priority = 200
      rules = {
        "dns" = {
          protocols             = ["UDP"]
          source_addresses      = ["10.40.0.0/16"]
          destination_addresses = ["168.63.129.16"]
          destination_ports     = ["53"]
        }
      }
    }
  }

  application_rule_collections = {
    "aks-required" = {
      priority = 300
      rules = {
        "aks-control-plane" = {
          protocols         = { https = { type = "Https", port = 443 } }
          source_addresses  = ["10.40.16.0/20"]
          destination_fqdns = ["*.hcp.centralus.azmk8s.io", "mcr.microsoft.com", "*.data.mcr.microsoft.com"]
        }
      }
    }
  }
}
```

Note what the network collection does **not** contain: a broad `443` allow.
Adding one would make `aks-required` unreachable, and the module would reject
it.

The route table then points at `module.firewall.private_ip_address`. The
`route-table` module takes it as a variable rather than reading the firewall
resource, so the two can be applied independently — see `ARCHITECTURE.md` §1.1.

## Key inputs

| Name | Default | Description |
|---|---|---|
| `sku_tier` | `"Standard"` | `Basic` needs a management subnet; `Premium` is the only tier with IDPS and TLS inspection |
| `subnet_id` | — | Must resolve to a subnet named `AzureFirewallSubnet` |
| `public_ip_id` | — | Standard SKU, Static allocation |
| `management_subnet_id` | `null` | **Required for Basic** and for forced tunnelling |
| `zones` | `[]` | Free; cross-zone data transfer is not |
| `dns_proxy_enabled` | `false` | **Required** if any network rule uses FQDNs |
| `threat_intelligence_mode` | `"Deny"` | `"Alert"` logs and permits |
| `intrusion_detection_mode` | `null` | Premium only |
| `private_ip_ranges` | `[]` | Ranges NOT to SNAT; defaults to RFC1918 |
| `acknowledge_no_rules` | `false` | Permits a deny-everything firewall |
| `acknowledge_broad_network_allow` | `false` | Permits network rules that shadow application rules |

## Key outputs

| Name | Description |
|---|---|
| `private_ip_address` | The route table's `VirtualAppliance` next hop |
| `policy_id` | For child policies or a second firewall |
| `security_summary` | Posture in plain language, including every degraded state |
| `threat_intelligence_enforces` | False when threat intel is Off or Alert |
| `intrusion_detection_enforces` | False unless IDPS is Deny **and** the tier is Premium |
| `is_zone_redundant` | False for one zone, which reads like zone-awareness |
| `indicative_monthly_cost_usd` | Deployment hours only — data processing is extra |

---

## Cost

| Tier | Deployment | Plus |
|---|---|---|
| Basic | ~$288/month | ~$0.016/GB processed |
| Standard | ~$913/month | ~$0.016/GB processed |
| Premium | ~$1,278/month | ~$0.016/GB processed |

Zone redundancy adds cross-zone data transfer on top of all three. These are
order-of-magnitude planning figures — verify against the Azure Pricing
Calculator.

The firewall is the single most expensive component in this platform by an
order of magnitude, which is the whole reason `dev` and `qa` use a NAT Gateway
and `stage` and `prod` have never been deployed.

---

## Tests

`terraform test` with `mock_provider`: 22 runs, no credentials, nothing
created. They test the preconditions and the posture outputs — the module's own
logic — not the provider's ability to create a firewall.

Given this module has never run against Azure, they are the only evidence it
behaves, and they cannot tell you that Azure accepts what it produces.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
