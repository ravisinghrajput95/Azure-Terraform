# Module: `private-dns`

Privatelink DNS zones and their virtual network links. Zones are selected by
**service key**, not by name, because a mistyped zone name in Azure has no
error path.

---

## The silent failure this module exists to prevent

A private endpoint's `private_dns_zone_group` looks for a zone whose name
matches exactly what Azure expects for that service. If it finds none:

1. No A record is registered.
2. The client falls back to public DNS.
3. The service resolves to its **public** address from inside the VNet.

The private endpoint exists. The NSG permits it. The architecture diagram is
correct. And traffic leaves the network anyway — with no error, at any layer.

Two ordering and naming rules follow, and both are enforced here:

- **Zones must exist before private endpoints.** This module is Phase 2; its
  consumers are Phase 3 and 4.
- **Zone names must be exact.** Selecting by service key removes the class of
  typo entirely. `additional_zones` accepts raw names for services outside the
  table, and its documentation says to prefer extending the table instead.

---

## Usage

```hcl
module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = module.resource_group.names["net"]
  tags                = module.tags.tags

  services = ["keyvault", "blob", "sql", "redis"]

  virtual_network_ids = {
    (module.networking.vnet_name) = module.networking.vnet_id
  }

  registration_enabled = false
}
```

Consumed by a private endpoint:

```hcl
private_dns_zone_group {
  name                 = "default"
  private_dns_zone_ids = [module.private_dns.zone_ids_by_service["sql"]]
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — | The `net` scope. |
| `tags` | `map(string)` | — | From `tags`. |
| `services` | `list(string)` | `[]` | Service keys — see below. |
| `location_hint` | `string` | `null` | Required only for `sql_mi`, `aks`, `backup`. |
| `additional_zones` | `list(string)` | `[]` | Raw zone names. Use sparingly. |
| `virtual_network_ids` | `map(string)` | — | Link name → VNet ID. |
| `registration_enabled` | `bool` | `false` | Keep false. See below. |
| `resolution_policy` | `string` | `null` | `Default` or `NxDomainRedirect`. |

## Outputs

`zone_ids_by_service`, `zone_names_by_service`, `zone_ids`, `zone_names`,
`resource_group_name`, `linked_virtual_network_ids`, `link_count`,
`registration_enabled`

---

## Service keys

| Category | Keys |
|---|---|
| Databases | `sql`, `sql_mi`†, `cosmos_sql` |
| Storage | `blob`, `file`, `queue`, `table`, `dfs`, `web_storage` |
| Security | `keyvault` |
| Caching | `redis`, `redis_enterprise` |
| Messaging | `servicebus`, `eventhub` |
| Compute | `acr`, `aks`†, `app_service` |
| Management | `monitor`, `automation`, `backup`†, `storage_sync` |
| Other | `search`, `appconfig`, `signalr` |

† Region-scoped: the zone name embeds a region, so `location_hint` is required.
A precondition rejects the combination rather than producing a zone name
containing a literal placeholder.

**Storage needs one zone per sub-resource.** A private endpoint for `blob` does
not make `file` resolve — they are separate zones, and this catches people out
regularly.

**Some keys share a zone.** `servicebus` and `eventhub` both map to
`privatelink.servicebus.windows.net`. Zones are deduplicated by name, so
requesting both does not attempt to create it twice.

---

## Design notes

**`registration_enabled` stays false, for two independent reasons.** Azure
permits at most **one** registration-enabled virtual network link per VNet
across *all* private DNS zones — spending it on a privatelink zone makes it
unavailable for a genuine VM-registration zone later. And a privatelink zone
holds records Azure manages on behalf of private endpoints; a VM registering a
colliding name breaks resolution for everyone. A precondition catches the
multi-zone case, which would otherwise fail at apply partway through creating
the links.

**Zones live in the networking resource group, not data.** They outlive the
individual services that register into them. Destroying the data tier must not
orphan a zone that other services and future endpoints share.

**Region-scoped names are guarded with a placeholder rather than left null.**
Terraform builds the whole service-to-zone map eagerly, even for services that
were not requested, so a null interpolation fails the plan regardless of what
was asked for. The placeholder makes the map evaluable; the precondition
ensures it is never reachable in a valid configuration.

**A zone with no VNet link is invisible.** It exists, holds correct records,
and nothing in the network can see it. `link_count` and
`linked_virtual_network_ids` make that visible.

---

## Cost

Zones are billed per zone per month at a negligible rate — cents — plus a
per-query charge. Four zones with private endpoint traffic is a rounding error
against the NAT Gateway.

---

## Deployed state

`dev` — applied and verified in Azure:

```
privatelink.vaultcore.azure.net        1 link   registration: false
privatelink.blob.core.windows.net      1 link   registration: false
privatelink.database.windows.net       1 link   registration: false
privatelink.redis.cache.windows.net    1 link   registration: false
```

All linked to `vnet-cloudcart-dev-eus-001`, link state `Completed`. Record
counts are 1 each — the zone's own SOA. Service A records appear when the
Phase 3 and 4 private endpoints are created.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
