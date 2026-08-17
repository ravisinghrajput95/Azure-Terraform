# Module: `nsg`

Network security groups, their rules, and subnet associations. Enforces that
every NSG carries an explicit inbound deny, because without one an NSG in Azure
enforces nothing.

---

## The default-deny problem

Azure's built-in rule **`AllowVnetInBound` at priority 65000 permits all
traffic between any two VNet addresses, on every port.** It cannot be removed.

An NSG containing only `Allow` rules therefore provides **no isolation between
tiers** — the built-in rule catches everything the explicit rules did not, and
every subnet can reach every other subnet freely. The NSG looks configured, the
architecture diagram shows three tiers, and the boundary does not exist.

This module rejects such an NSG at plan time. `require_explicit_inbound_deny`
defaults to true, and a qualifying rule must be an inbound `Deny` with
`protocol = "*"`, source `*`, destination `*`, ports `*` — a narrower deny
blocks something specific while leaving the built-in allow catching the rest.

---

## Usage

```hcl
module "nsg" {
  source = "../../modules/nsg"

  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  network_security_groups = {
    "nsg-app-dev-eus" = {
      subnet_id = module.networking.subnet_ids["snet-app-dev-eus"]
      rules = {
        "Allow-HTTPS-Ingress" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          destination_port_range     = "443"
          source_address_prefix      = "Internet"
          destination_address_prefix = "*"
        }
        "Deny-All-Inbound" = {
          priority                   = 4096
          direction                  = "Inbound"
          access                     = "Deny"
          protocol                   = "*"
          destination_port_range     = "*"
          source_address_prefix      = "*"
          destination_address_prefix = "*"
        }
      }
    }
  }
}
```

Attach diagnostics to every NSG with `for_each` over the `ids` output:

```hcl
module "diagnostics_nsg" {
  source   = "../../modules/diagnostics"
  for_each = module.nsg.ids

  target_resource_id         = each.value
  log_analytics_workspace_id = module.log_analytics.id
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — | The `net` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `network_security_groups` | `map(object)` | — | NSG name → `{ subnet_id, rules }`. |
| `require_explicit_inbound_deny` | `bool` | `true` | See above. |

## Outputs

`ids`, `names`, `associated_subnet_ids`, `unassociated_nsgs`, `rule_count`,
`rules_by_nsg`, `nsgs_with_explicit_inbound_deny`

---

## Design notes

**Rules are separate `azurerm_network_security_rule` resources; the NSG's
`security_rule` argument is deliberately unset.** That argument is
Optional+Computed in the provider schema, so omitting it means Terraform does
not manage rules on the NSG resource at all, leaving the separate resources as
sole owner. Setting both is the NSG equivalent of the inline-subnet trap: each
apply removes what the other form created and the plan never comes clean.

The practical benefit is reviewability. Each rule appears as its own line in
plan output, so a firewall change reads as "one rule added" rather than a diff
of an opaque set.

**`for_each` keys on rule name, never index.** Inserting a rule in the middle
of an indexed list re-indexes everything after it, and the diff shows a dozen
unrelated changes — unreviewable when what is being reviewed is a security
change.

**`rules_by_nsg` is sorted in Azure's evaluation order** — direction, then
ascending priority — not alphabetically. Priority is zero-padded in the sort
key because `sort()` is lexicographic; without padding, priority 1000 sorts
before 200.

**It carries each rule's reach, not just its verdict.** Source and destination
prefixes and destination ports are included, because an entry reporting only
"Allow, Tcp, 443" reads identically whether the source is one subnet or the
whole internet — and it is the source that decides whether a tier boundary is
real. Azure accepts each of those as either a singular `..._prefix` or a plural
`..._prefixes`, and the two forms express the same policy, so both are
collapsed into one list. Without that, diffing an environment written one way
against an environment written the other reports a policy change where there is
none.

**Associations depend on the rules existing first.** Attaching an NSG whose
rules have not yet been created would briefly apply an effective default-deny
to live traffic.

---

## Preconditions

| Check | Failure it prevents |
|---|---|
| Explicit inbound deny per NSG | An NSG that appears to isolate tiers and does not |
| Unique priority per NSG per direction | Azure rejects duplicates but names only one of the conflicting rules |
| One NSG per subnet | Two NSGs claiming a subnet is not a merge — the last to apply silently replaces the other |
| Exactly one of `*_port_range` / `*_port_ranges` | Azure ignores one form silently, and which one is not obvious |
| Exactly one of `source_address_prefix` / `_prefixes` | Same |
| Description ≤ 140 characters | Fails at apply, after the plan was approved |
| Priority 100–4096 | 65000–65500 are reserved for built-in rules |

---

## Two rules that are not optional

**`AzureLoadBalancer` inbound must be allowed.** Health probes originate from
that service tag, not from the load balancer's frontend address. Blocking it
marks every backend instance unhealthy and takes the whole tier out of
rotation — a failure that looks like an application problem.

**The Azure Bastion rule set is mandated, not chosen.** Bastion will not deploy
into a subnet whose NSG lacks its required inbound rules (443 from `Internet`,
`GatewayManager` and `AzureLoadBalancer`; 8080/5701 from `VirtualNetwork`) and
outbound rules (22/3389 to `VirtualNetwork`, 443 to `AzureCloud`, 8080/5701
internal, 80 to `Internet` for CRL checks). The error names Bastion rather than
the missing rule.

---

## Cost

NSGs and their rules are free. NSG **flow logs** are not — they bill for
storage and, with Traffic Analytics, for Log Analytics ingestion. Flow logs are
a separate resource and are not created here.

---

## Deployed state

`dev` — applied and verified in Azure, all six attached:

```
nsg-app-dev-eus        4 rules  -> snet-app-dev-eus
nsg-biz-dev-eus        4 rules  -> snet-biz-dev-eus
nsg-pep-dev-eus        2 rules  -> snet-pep-dev-eus
nsg-db-dev-eus         2 rules  -> snet-db-dev-eus
nsg-mgmt-dev-eus       2 rules  -> snet-mgmt-dev-eus
nsg-bastion-dev-eus    9 rules  -> AzureBastionSubnet
```

Business tier effective policy, confirming the tier boundary is real:

```
 100  Allow-App-Tier     Allow  10.10.4.0/22       8443
 110  Allow-LB-Probe     Allow  AzureLoadBalancer  *
 120  Allow-SSH-Admin    Allow  10.10.0.128/26     22
4096  Deny-All-Inbound   Deny   *                  *
```

The ingress source is absent from that list by design. Skipping a tier is a
lateral movement path.

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
| [azurerm_network_security_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_security_rule.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule) | resource |
| [azurerm_subnet_network_security_group_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_network_security_groups"></a> [network\_security\_groups](#input\_network\_security\_groups) | Map of NSG name to its configuration.<br/><br/>  subnet\_id  Subnet to associate the NSG with. Azure permits at most ONE<br/>             NSG per subnet, so two entries pointing at the same subnet is<br/>             a configuration error, not a merge.<br/><br/>  rules      Map of rule name to rule. Keyed by name so that adding a rule<br/>             does not re-index the others in plan output — which matters<br/>             when the diff being reviewed is a firewall change.<br/><br/>Ports and addresses each accept a singular or a plural form. Supplying both<br/>forms for the same field is rejected: Azure ignores one of them silently,<br/>and which one it ignores is not obvious. | <pre>map(object({<br/>    subnet_id        = optional(string)<br/>    attach_to_subnet = optional(bool, true)<br/><br/>    rules = map(object({<br/>      priority    = number<br/>      direction   = string<br/>      access      = string<br/>      protocol    = string<br/>      description = optional(string)<br/><br/>      source_port_range  = optional(string, "*")<br/>      source_port_ranges = optional(list(string))<br/><br/>      destination_port_range  = optional(string)<br/>      destination_port_ranges = optional(list(string))<br/><br/>      source_address_prefix   = optional(string)<br/>      source_address_prefixes = optional(list(string))<br/><br/>      destination_address_prefix   = optional(string, "*")<br/>      destination_address_prefixes = optional(list(string))<br/>    }))<br/>  }))</pre> | n/a | yes |
| <a name="input_require_explicit_inbound_deny"></a> [require\_explicit\_inbound\_deny](#input\_require\_explicit\_inbound\_deny) | Require every NSG to carry an explicit inbound Deny rule. Azure's built-in AllowVnetInBound rule at priority 65000 permits all intra-VNet traffic, so without a lower-priority deny an NSG with only Allow rules enforces nothing between tiers. Disable only for an NSG deliberately intended to be permissive. | `bool` | `true` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for the network security groups. Should be the "net" lifecycle scope. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_associated_subnet_ids"></a> [associated\_subnet\_ids](#output\_associated\_subnet\_ids) | Map of NSG name to the subnet it protects. An NSG absent from this map exists but is attached to nothing, so its rules are inert. |
| <a name="output_ids"></a> [ids](#output\_ids) | Map of NSG name to ARM resource ID. Feed this to the diagnostics module with for\_each to attach flow diagnostics to every NSG. |
| <a name="output_names"></a> [names](#output\_names) | Map of NSG name to name, for callers that need the map shape. |
| <a name="output_nsgs_with_explicit_inbound_deny"></a> [nsgs\_with\_explicit\_inbound\_deny](#output\_nsgs\_with\_explicit\_inbound\_deny) | NSGs carrying an explicit inbound deny-all rule. Any NSG missing from this list relies on Azure's built-in AllowVnetInBound at priority 65000, which permits all intra-VNet traffic and therefore enforces no tier isolation. |
| <a name="output_rule_count"></a> [rule\_count](#output\_rule\_count) | Total number of security rules managed by this module. |
| <a name="output_rules_by_nsg"></a> [rules\_by\_nsg](#output\_rules\_by\_nsg) | Map of NSG name to its rules in Azure's evaluation order — direction, then ascending priority. A single artefact for reviewing effective policy or diffing it between environments. Each rule carries its source and destination prefixes and destination ports as lists, with the singular and plural forms of each collapsed into one, so a rule's reach can be read without knowing which form declared it. |
| <a name="output_unassociated_nsgs"></a> [unassociated\_nsgs](#output\_unassociated\_nsgs) | NSGs that were created but attached to no subnet. Their rules have no effect. Usually this is a staged configuration, occasionally it is a subnet reference that silently evaluated to null. |
<!-- END_TF_DOCS -->
