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
| [azurerm_private_dns_zone.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_zones"></a> [additional\_zones](#input\_additional\_zones) | Raw privatelink zone names for services not covered by the service-key table. Use sparingly — a typo here has no error path and results in a private endpoint that silently resolves to a public address. Prefer extending the module's table. | `list(string)` | `[]` | no |
| <a name="input_location_hint"></a> [location\_hint](#input\_location\_hint) | Normalised region name, required only when requesting a service whose privatelink zone embeds a region: sql\_mi, aks and backup. For example SQL Managed Instance uses privatelink.<region>.database.windows.net. Leave null when none of those services are requested. | `string` | `null` | no |
| <a name="input_registration_enabled"></a> [registration\_enabled](#input\_registration\_enabled) | Whether VMs in the linked VNet auto-register their own A records in these<br/>zones.<br/><br/>Left FALSE, and it should stay false for privatelink zones. Two reasons:<br/><br/>  1. A privatelink zone holds records Azure manages on behalf of private<br/>     endpoints. VM records do not belong in it, and a VM registering a name<br/>     that collides with a service record breaks resolution for everyone.<br/><br/>  2. Azure permits at most ONE registration-enabled link per virtual<br/>     network across ALL zones. Spending it on a privatelink zone means it<br/>     is unavailable for a genuine VM-registration zone later. | `bool` | `false` | no |
| <a name="input_resolution_policy"></a> [resolution\_policy](#input\_resolution\_policy) | Behaviour when a name is not found in the zone. "NxDomainRedirect" falls back to public DNS for unmatched names, which is required when a linked VNet also needs to resolve public names in the same suffix. Null uses the Azure default. | `string` | `null` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for the zones. Should be the "net" lifecycle scope: zones outlive the individual data services that register into them. | `string` | n/a | yes |
| <a name="input_services"></a> [services](#input\_services) | Service keys to create privatelink zones for. Valid keys: sql, sql\_mi, blob, file, queue, table, dfs, web\_storage, keyvault, redis, managed\_redis, redis\_enterprise, cosmos\_sql, servicebus, eventhub, acr, aks, app\_service, monitor, automation, signalr, search, appconfig, backup, storage\_sync. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_virtual_network_ids"></a> [virtual\_network\_ids](#input\_virtual\_network\_ids) | Map of link name to virtual network ID. Every zone is linked to every VNet listed. Without a link, a zone exists but is invisible to the VNet's resolver, and private endpoint names resolve publicly. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_link_count"></a> [link\_count](#output\_link\_count) | Total number of virtual network links created — one per zone per VNet. |
| <a name="output_linked_virtual_network_ids"></a> [linked\_virtual\_network\_ids](#output\_linked\_virtual\_network\_ids) | Virtual networks these zones are linked to. A zone with no link is invisible to a VNet's resolver, so its records have no effect there. |
| <a name="output_registration_enabled"></a> [registration\_enabled](#output\_registration\_enabled) | Whether linked VNets auto-register VM records into these zones. Should be false for privatelink zones: Azure permits only one registration-enabled link per VNet across all zones, and VM records do not belong in a zone Azure manages for private endpoints. |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Resource group holding the zones. |
| <a name="output_zone_ids"></a> [zone\_ids](#output\_zone\_ids) | Map of zone name to zone ID, covering both service-derived and additional\_zones entries. |
| <a name="output_zone_ids_by_service"></a> [zone\_ids\_by\_service](#output\_zone\_ids\_by\_service) | Map of requested service key to that service's privatelink zone ID. This is what a private endpoint's private\_dns\_zone\_group consumes. |
| <a name="output_zone_names"></a> [zone\_names](#output\_zone\_names) | All zone names created, deduplicated. Several service keys share a zone — eventhub and servicebus both use privatelink.servicebus.windows.net. |
| <a name="output_zone_names_by_service"></a> [zone\_names\_by\_service](#output\_zone\_names\_by\_service) | Map of requested service key to the privatelink zone name Azure expects for it. |
<!-- END_TF_DOCS -->
