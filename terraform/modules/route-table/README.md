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
