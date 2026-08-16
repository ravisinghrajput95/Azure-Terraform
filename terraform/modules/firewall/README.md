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

### Addresses are created here, and their zones must match

Both public IPs are created by this module, as `bastion` and
`application-gateway` do, because a root module declares no resources of its
own. Standard SKU and Static allocation are fixed rather than offered as
inputs: Azure requires both and rejects anything else with an error that does
not name the offending property, so a variable would only be a way to get it
wrong.

Their zones are set to the firewall's. A zone-redundant firewall in front of a
**zonal** public IP is accepted by Azure and leaves the address as exactly the
single point of failure the zone spread was bought to remove.

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

  subnet_id      = module.networking.subnet_ids["AzureFirewallSubnet"]
  public_ip_name = "pip-afw-${module.naming.base}-001"

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
| `public_ip_name` | — | Created by this module; Standard SKU and Static are fixed, not inputs |
| `management_subnet_id` | `null` | **Required for Basic** and for forced tunnelling |
| `management_public_ip_name` | `null` | Derived from the firewall name when omitted |
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
| `public_ip_address` | The egress address the internet sees for every routed workload |
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
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_firewall.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/firewall) | resource |
| [azurerm_firewall_policy.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/firewall_policy) | resource |
| [azurerm_firewall_policy_rule_collection_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/firewall_policy_rule_collection_group) | resource |
| [azurerm_public_ip.management](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_public_ip.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_acknowledge_broad_network_allow"></a> [acknowledge\_broad\_network\_allow](#input\_acknowledge\_broad\_network\_allow) | Permit a broad Allow network rule to coexist with application rules.<br/><br/>Azure evaluates ALL network rules before ANY application rule. A network<br/>rule allowing 0.0.0.0/0 on 80/443 therefore matches web traffic first, and<br/>every FQDN-filtering application rule beneath it never evaluates. The<br/>application rules remain visible, correct-looking and completely inert.<br/><br/>Set this only where the broad rule is deliberate and the application rules<br/>are understood to be unreachable for those ports. | `bool` | `false` | no |
| <a name="input_acknowledge_no_rules"></a> [acknowledge\_no\_rules](#input\_acknowledge\_no\_rules) | Permit deploying a firewall with NO rule collections at all.<br/><br/>An Azure Firewall denies by default. Once a route table sends 0.0.0.0/0 to<br/>it, a firewall with no rules blackholes ALL egress — no DNS, no package<br/>repositories, no container registries. AKS nodes fail to bootstrap and the<br/>cluster never converges, while the firewall itself reports healthy and the<br/>portal shows a correctly provisioned resource.<br/><br/>Legitimate as a first step when rules land in a later apply. Set it<br/>knowingly. | `bool` | `false` | no |
| <a name="input_application_rule_collections"></a> [application\_rule\_collections](#input\_application\_rule\_collections) | Application (L7 / FQDN) rule collections, keyed by name. Evaluated only for traffic no network rule already matched. | <pre>map(object({<br/>    priority = number<br/>    action   = optional(string, "Allow")<br/>    rules = map(object({<br/>      protocols = map(object({<br/>        type = string<br/>        port = number<br/>      }))<br/>      source_addresses      = optional(list(string), [])<br/>      source_ip_groups      = optional(list(string), [])<br/>      destination_fqdns     = optional(list(string), [])<br/>      destination_fqdn_tags = optional(list(string), [])<br/>      destination_urls      = optional(list(string), [])<br/>      web_categories        = optional(list(string), [])<br/>      terminate_tls         = optional(bool, false)<br/>      description           = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_dns_proxy_enabled"></a> [dns\_proxy\_enabled](#input\_dns\_proxy\_enabled) | Whether the firewall acts as a DNS proxy.<br/><br/>NOT optional if any NETWORK rule uses `destination_fqdns`. An FQDN in a<br/>network rule is resolved by the firewall itself, and without the proxy<br/>there is nothing to resolve it — the rule is accepted, displays correctly,<br/>and matches no traffic. A precondition rejects that combination.<br/><br/>Application rules resolve FQDNs differently and do not need this. | `bool` | `false` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Custom DNS servers the firewall forwards to. Empty uses Azure-provided DNS. | `list(string)` | `[]` | no |
| <a name="input_intrusion_detection_mode"></a> [intrusion\_detection\_mode](#input\_intrusion\_detection\_mode) | IDPS mode. PREMIUM TIER ONLY.<br/><br/>  null    Not configured.<br/>  "Off"   Configured and doing nothing.<br/>  "Alert" Signature matches are logged and ALLOWED THROUGH.<br/>  "Deny"  Signature matches are blocked.<br/><br/>Setting this on a Standard or Basic firewall is rejected by a precondition:<br/>IDPS is a Premium capability, and a configuration that names it on a<br/>cheaper tier reads as intrusion prevention that does not exist. | `string` | `null` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region. Must match the VNet holding AzureFirewallSubnet. | `string` | n/a | yes |
| <a name="input_management_public_ip_name"></a> [management\_public\_ip\_name](#input\_management\_public\_ip\_name) | Name of the management public IP, created by this module whenever management\_subnet\_id is set. Derived from the firewall name when omitted — the management plane needs its own address and cannot share the data-plane IP, so this is not a thing to be able to forget. | `string` | `null` | no |
| <a name="input_management_subnet_id"></a> [management\_subnet\_id](#input\_management\_subnet\_id) | ID of the management subnet, named EXACTLY "AzureFirewallManagementSubnet". REQUIRED for the Basic tier and for forced tunnelling; null otherwise. | `string` | `null` | no |
| <a name="input_name"></a> [name](#input\_name) | Firewall name, from naming.names.firewall. | `string` | n/a | yes |
| <a name="input_nat_rule_collections"></a> [nat\_rule\_collections](#input\_nat\_rule\_collections) | DNAT rule collections, keyed by name. Evaluated before everything else. Inbound publishing only — this platform fronts ingress with Application Gateway instead. | <pre>map(object({<br/>    priority = number<br/>    rules = map(object({<br/>      protocols          = list(string)<br/>      source_addresses   = optional(list(string), [])<br/>      source_ip_groups   = optional(list(string), [])<br/>      destination_ports  = optional(list(string), [])<br/>      translated_port    = number<br/>      translated_address = optional(string)<br/>      translated_fqdn    = optional(string)<br/>      description        = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_network_rule_collections"></a> [network\_rule\_collections](#input\_network\_rule\_collections) | Network (L3/L4) rule collections, keyed by name.<br/><br/>Evaluated BEFORE every application rule, regardless of priority. A broad<br/>Allow here silently disables FQDN filtering below it. | <pre>map(object({<br/>    priority = number<br/>    action   = optional(string, "Allow")<br/>    rules = map(object({<br/>      protocols             = list(string)<br/>      source_addresses      = optional(list(string), [])<br/>      source_ip_groups      = optional(list(string), [])<br/>      destination_addresses = optional(list(string), [])<br/>      destination_fqdns     = optional(list(string), [])<br/>      destination_ip_groups = optional(list(string), [])<br/>      destination_ports     = list(string)<br/>      description           = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_private_ip_ranges"></a> [private\_ip\_ranges](#input\_private\_ip\_ranges) | Address ranges the firewall treats as INTERNAL and therefore does not SNAT.<br/><br/>Azure's default is the RFC1918 ranges. If the estate uses private<br/>addressing outside RFC1918 — 100.64.0.0/10 shared address space is the<br/>common case — traffic to it IS SNATed to the firewall's own address, the<br/>return path goes somewhere else, and the connection hangs rather than<br/>failing cleanly.<br/><br/>Empty leaves the Azure default in place. | `list(string)` | `[]` | no |
| <a name="input_public_ip_name"></a> [public\_ip\_name](#input\_public\_ip\_name) | Name of the firewall's data-plane public IP, which this module creates. Azure requires Standard SKU with Static allocation and rejects anything else with an error that does not name the offending property, so neither is an input. | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "net" lifecycle scope — the firewall is network edge, and must outlive the application stacks that route through it. | `string` | n/a | yes |
| <a name="input_rule_collection_group_priority"></a> [rule\_collection\_group\_priority](#input\_rule\_collection\_group\_priority) | Priority of the rule collection group. Lower evaluates first. Only meaningful when a policy carries several groups. | `number` | `1000` | no |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | Deployment model. AZFW\_VNet is a firewall in your own VNet; AZFW\_Hub is a Virtual WAN secured hub, which this module does not wire. | `string` | `"AZFW_VNet"` | no |
| <a name="input_sku_tier"></a> [sku\_tier](#input\_sku\_tier) | Firewall tier.<br/><br/>  "Basic"     Small-scale. Throughput is capped and it REQUIRES a<br/>              management subnet and a second public IP.<br/>  "Standard"  L3-L7 filtering, FQDN rules, threat intelligence.<br/>  "Premium"   Adds IDPS and TLS inspection. Roughly $365/month more than<br/>              Standard, and the only tier where `intrusion_detection` does<br/>              anything.<br/><br/>This is a cost decision before it is a capability one — see README.md. | `string` | `"Standard"` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | ID of the firewall subnet. Azure requires it to be named EXACTLY "AzureFirewallSubnet" and to be /26 or larger; a precondition checks the name, because the API error names the firewall rather than the subnet. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_threat_intelligence_mode"></a> [threat\_intelligence\_mode](#input\_threat\_intelligence\_mode) | Threat intelligence behaviour.<br/><br/>  "Deny"  Blocks traffic to and from known-malicious addresses.<br/>  "Alert" LOGS it and lets it through. Protection is off; the alerts make<br/>          it look on.<br/>  "Off"   Disabled entirely.<br/><br/>"Alert" is the deceptive value: the feature reports as enabled and blocks<br/>nothing. | `string` | `"Deny"` | no |
| <a name="input_zones"></a> [zones](#input\_zones) | Availability zones for the firewall.<br/><br/>The zones themselves cost nothing. CROSS-ZONE DATA TRANSFER IS BILLED, and<br/>every byte a workload in zone 1 sends through a firewall instance in zone 2<br/>crosses a zone. A zone-redundant firewall is the correct choice for<br/>production and is not free in practice.<br/><br/>A single zone provides no redundancy and is reported as such rather than<br/>reading like a zonal deployment. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_id"></a> [id](#output\_id) | Firewall resource ID. |
| <a name="output_indicative_monthly_cost_usd"></a> [indicative\_monthly\_cost\_usd](#output\_indicative\_monthly\_cost\_usd) | ORDER-OF-MAGNITUDE monthly estimate at approximate US list price for the deployment hours alone. Data processing is roughly $0.016/GB ON TOP of this, and cross-zone transfer is extra again. Not a budget figure — verify against the Azure Pricing Calculator. |
| <a name="output_intrusion_detection_enforces"></a> [intrusion\_detection\_enforces](#output\_intrusion\_detection\_enforces) | True only when IDPS is set to "Deny" on a Premium firewall. "Alert" logs signature matches and allows them. |
| <a name="output_is_zone_redundant"></a> [is\_zone\_redundant](#output\_is\_zone\_redundant) | Whether the firewall spans at least two availability zones. A single zone is a zonal deployment with no redundancy, which reads like zone-awareness and is not. |
| <a name="output_name"></a> [name](#output\_name) | Firewall name. |
| <a name="output_policy_id"></a> [policy\_id](#output\_policy\_id) | Firewall policy resource ID. Attach a child policy or a second firewall to this. |
| <a name="output_private_ip_address"></a> [private\_ip\_address](#output\_private\_ip\_address) | The firewall's private IP. THIS is the value a route table's VirtualAppliance next hop needs — the route-table module takes it as next\_hop\_ip so the two can be applied independently. |
| <a name="output_public_ip_address"></a> [public\_ip\_address](#output\_public\_ip\_address) | The firewall's public egress address. This is the source address the internet sees for every workload routed through it, and the value an external allowlist needs. |
| <a name="output_public_ip_address_id"></a> [public\_ip\_address\_id](#output\_public\_ip\_address\_id) | ID of the data-plane public IP created by this module. |
| <a name="output_rule_collection_count"></a> [rule\_collection\_count](#output\_rule\_collection\_count) | Number of rule collections across all three types. |
| <a name="output_rule_count"></a> [rule\_count](#output\_rule\_count) | Total individual rules. |
| <a name="output_security_summary"></a> [security\_summary](#output\_security\_summary) | Consolidated posture in plain language, so the interacting settings can be reviewed without reading the configuration. |
| <a name="output_threat_intelligence_enforces"></a> [threat\_intelligence\_enforces](#output\_threat\_intelligence\_enforces) | True only when threat\_intelligence\_mode is "Deny". "Alert" logs malicious traffic and lets it through, which is protection that reports as enabled and blocks nothing. |
<!-- END_TF_DOCS -->
