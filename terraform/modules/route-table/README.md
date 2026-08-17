# Module: `route-table`

User-defined routes and their subnet associations, with preconditions covering
the two routing mistakes that break services silently.

---

## Why the guardrails matter

A routing change is the fastest way to cause a total environment outage. It
applies in seconds, there is no health check, and the two most common mistakes
**do not fail at apply** — they break the service at runtime, and the resulting
error names the service rather than the route.

| Subnet | Consequence of a `0.0.0.0/0` route |
|---|---|
| `AzureBastionSubnet` | Bastion requires direct outbound connectivity. Fails to provision, or drops sessions once deployed. |
| Application Gateway subnet | AppGW v2 requires direct control-plane access. Health probes fail and the gateway reports permanently unhealthy. |
| `AzureFirewallSubnet` | The firewall is the next hop. Pointing its own subnet at itself is a routing loop. |
| `GatewaySubnet` | Same class of problem for VPN and ExpressRoute gateways. |

The module rejects these combinations at plan time via
`subnets_forbidding_default_route`. Subnet names are extracted from the ARM
resource IDs being associated, so the check works without the caller restating
which subnet is which.

---

## Usage

```hcl
module "route_table" {
  source = "../../modules/route-table"

  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  subnets_forbidding_default_route = concat(
    ["AzureBastionSubnet", "AzureFirewallSubnet", "GatewaySubnet"],
    ["snet-agw-dev-eus"],
  )

  route_tables = {
    "rt-workload-dev-eus" = {
      bgp_route_propagation_enabled = false

      routes = module.profile.egress_strategy == "firewall" ? {
        "Default-To-Firewall" = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = var.firewall_private_ip
        }
      } : {}

      subnet_ids = [
        module.networking.subnet_ids["snet-app-dev-eus"],
        module.networking.subnet_ids["snet-biz-dev-eus"],
      ]
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — | The `net` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `route_tables` | `map(object)` | — | Name → `{ bgp_route_propagation_enabled, routes, subnet_ids }`. |
| `subnets_forbidding_default_route` | `list(string)` | Azure-reserved names | Add the Application Gateway subnet name. |

## Outputs

`ids`, `names`, `associations`, `associated_subnet_names`,
`tables_with_default_route`, `tables_without_routes`,
`bgp_propagation_enabled_tables`, `route_count`

---

## Design notes

**A NAT Gateway is not a UDR next hop.** This is the reason
`module.profile.egress_strategy` is a string rather than a boolean. A NAT
Gateway attaches directly to the subnet; there is no next-hop type for it.
Adding a `0.0.0.0/0` route pointing anywhere would *override* the NAT Gateway
and break egress. So the correct routing configuration for NAT-based egress is
**no routes at all** — a three-way decision, not a toggle.

**An empty route table is still worth creating.** Setting
`bgp_route_propagation_enabled = false` is itself a control. Without it, an
ExpressRoute or VPN gateway attached later can advertise a more specific route
into these subnets, diverting egress away from the intended path — the firewall
is silently circumvented by a network change made elsewhere, with nothing in
this configuration changing. `tables_without_routes` reports empty tables so
they are visible rather than looking like an oversight.

**Routes are separate `azurerm_route` resources; the table's `route` argument
is unset.** Same Optional+Computed pattern as the NSG module: setting both
forms means each apply removes what the other created. Separate resources also
put each route on its own line in plan output, which matters when the diff is a
routing change.

**`next_hop_in_ip_address` is validated as required-iff-`VirtualAppliance`.**
A `VirtualAppliance` route without an address is accepted by Terraform and
rejected by Azure. Any other type *with* an address is accepted by Azure and
the address silently ignored.

**Associations are keyed by subnet ID**, so removing one association does not
re-index and recreate the others. Duplicate claims are detected against the raw
input rather than the keyed map, because a merge keyed by subnet ID would
silently drop the conflict instead of surfacing it.

---

## Cost

Route tables and routes are free.

---

## Deployed state

`dev` — applied and verified in Azure:

```
rt-workload-dev-eus
  routes                 0        (NAT Gateway egress; a default route would override it)
  bgp propagation        disabled
  subnets                5        snet-app, snet-biz, snet-db, snet-pep, snet-mgmt
```

`AzureBastionSubnet` is deliberately unassociated.

The guardrail was verified by negative test: temporarily associating
`AzureBastionSubnet` with a table carrying a default route fails the plan with
`Resource precondition failed` before any API call is made.

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
| [azurerm_route.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/route) | resource |
| [azurerm_route_table.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/route_table) | resource |
| [azurerm_subnet_route_table_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_route_table_association) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for the route tables. Should be the "net" lifecycle scope. | `string` | n/a | yes |
| <a name="input_route_tables"></a> [route\_tables](#input\_route\_tables) | Map of route table name to its configuration.<br/><br/>  bgp\_route\_propagation\_enabled<br/>      Whether routes learned over BGP from an ExpressRoute or VPN gateway<br/>      are applied to the associated subnets. Defaults to FALSE. Leaving it<br/>      enabled means a gateway added later can advertise a route that<br/>      bypasses the intended egress path — a firewall can be silently<br/>      circumvented by a network change made elsewhere.<br/><br/>  routes<br/>      Map of route name to { address\_prefix, next\_hop\_type,<br/>      next\_hop\_in\_ip\_address }. May be empty: a route table with no routes<br/>      is still meaningful, because disabling BGP propagation is itself a<br/>      control.<br/><br/>  subnets<br/>      Map of subnet NAME to subnet ID. A map keyed by name, not a list of<br/>      IDs, for two reasons: the key set stays known at plan time so<br/>      for\_each resolves from an empty state, and the forbidden-default-route<br/>      check can compare names without parsing them out of IDs that are<br/>      themselves unknown until apply. | <pre>map(object({<br/>    bgp_route_propagation_enabled = optional(bool, false)<br/>    subnets                       = optional(map(string), {})<br/><br/>    routes = optional(map(object({<br/>      address_prefix         = string<br/>      next_hop_type          = string<br/>      next_hop_in_ip_address = optional(string)<br/>    })), {})<br/>  }))</pre> | n/a | yes |
| <a name="input_subnets_forbidding_default_route"></a> [subnets\_forbidding\_default\_route](#input\_subnets\_forbidding\_default\_route) | Subnet NAMES that must never be associated with a route table carrying a 0.0.0.0/0 route. The Azure-reserved names are included by default; add the Application Gateway subnet name, which varies by environment. | `list(string)` | <pre>[<br/>  "AzureBastionSubnet",<br/>  "AzureFirewallSubnet",<br/>  "AzureFirewallManagementSubnet",<br/>  "GatewaySubnet",<br/>  "RouteServerSubnet"<br/>]</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_vnet_address_space"></a> [vnet\_address\_space](#input\_vnet\_address\_space) | Address space of the VNet these route tables serve, as CIDR strings. When set, every VirtualAppliance next hop must fall inside it. Leave empty ONLY when the next hop is deliberately in a peered network — an empty list disables the check, and next\_hop\_containment\_checked then reports false. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_associated_subnet_names"></a> [associated\_subnet\_names](#output\_associated\_subnet\_names) | Map of route table name to the subnet names it is applied to. Names rather than resource IDs, because routing is reviewed by humans. |
| <a name="output_associations"></a> [associations](#output\_associations) | Map of "<table>/<subnet-name>" to its association detail. |
| <a name="output_bgp_propagation_enabled_tables"></a> [bgp\_propagation\_enabled\_tables](#output\_bgp\_propagation\_enabled\_tables) | Route tables where BGP route propagation is left ON. Should normally be empty — a propagated route can be more specific than the configured default and silently divert egress away from the firewall. |
| <a name="output_ids"></a> [ids](#output\_ids) | Map of route table name to ARM resource ID. |
| <a name="output_names"></a> [names](#output\_names) | Map of route table name to name. |
| <a name="output_next_hop_containment_checked"></a> [next\_hop\_containment\_checked](#output\_next\_hop\_containment\_checked) | Whether every VirtualAppliance next hop was verified to be an address inside this VNet. FALSE means the check was SKIPPED because vnet\_address\_space is empty — which is correct only when the appliance is deliberately in a peered network. Azure accepts an out-of-VNet next hop either way, so nothing else will report it. |
| <a name="output_route_count"></a> [route\_count](#output\_route\_count) | Total number of routes managed by this module. |
| <a name="output_tables_with_default_route"></a> [tables\_with\_default\_route](#output\_tables\_with\_default\_route) | Route tables carrying a 0.0.0.0/0 route. Empty means egress is not being forced through a virtual appliance — correct when a NAT Gateway provides egress, since a NAT Gateway attaches to the subnet directly and is not a UDR next hop. |
| <a name="output_tables_without_routes"></a> [tables\_without\_routes](#output\_tables\_without\_routes) | Route tables with no routes at all. Not necessarily an error: an empty table still disables BGP route propagation on its subnets, which prevents a gateway added later from advertising a route that bypasses the intended egress path. |
| <a name="output_virtual_appliance_next_hops"></a> [virtual\_appliance\_next\_hops](#output\_virtual\_appliance\_next\_hops) | Map of "<table>/<route>" to the VirtualAppliance address it points at. Worth reading on any environment whose egress is inspected: this is the list of addresses that must exist and must answer, and a wrong entry here is invisible in every other output. |
<!-- END_TF_DOCS -->
