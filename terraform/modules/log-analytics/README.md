# Module: `log-analytics`

The telemetry sink every other module reports into. Built in Phase 1 because a
diagnostic setting cannot be created before its destination exists.

---

## Usage

```hcl
module "log_analytics" {
  source = "../../modules/log-analytics"

  name                = module.naming.names.log_analytics_workspace
  resource_group_name = module.resource_group.names["mon"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  retention_in_days = module.profile.profile.log_retention_days
  daily_quota_gb    = module.profile.profile.log_daily_quota_gb
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | From `naming.names.log_analytics_workspace`. |
| `resource_group_name` | `string` | — | The `mon` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `sku` | `string` | `PerGB2018` | Legacy tiers are unavailable for new workspaces. |
| `retention_in_days` | `number` | `30` | 30–730. First 31 days included. |
| `daily_quota_gb` | `number` | `-1` | `-1` uncapped, else ≥ 0.023. |
| `internet_ingestion_enabled` | `bool` | `true` | Needs AMPLS to disable. |
| `internet_query_enabled` | `bool` | `true` | Needs AMPLS to disable. |
| `local_authentication_enabled` | `bool` | `true` | False forces Entra ID auth. |
| `allow_resource_only_permissions` | `bool` | `true` | Supports least privilege. |
| `enable_system_assigned_identity` | `bool` | `true` | Free when unused. |
| `private_link_scope_configured` | `bool` | `false` | Assertion gate for disabling public endpoints. |

## Outputs

`id`, `name`, `workspace_id`, `resource_group_name`, `location`,
`principal_id`, `ingestion_is_capped`, `daily_quota_gb`, `retention_in_days`,
`retention_is_billable`

---

## Design notes

**No `azurerm_log_analytics_solution`.** The "solutions" model — `VMInsights`,
`Security`, `Updates` — belongs to the retired Log Analytics agent era. VM
Insights on Azure Monitor Agent is delivered through Data Collection Rules,
which the `monitor` module owns. Adding a solution here would light up a portal
blade while contributing nothing to the data path.

**`primary_shared_key` is deliberately not exported.** Nothing in this platform
needs it: Azure Monitor Agent authenticates with a managed identity through a
DCR, and `local_authentication_enabled = false` exists precisely to turn the key
off. Exporting it would propagate a long-lived credential into every consuming
module's state and plan output for no benefit. If a legacy component genuinely
requires it, read it deliberately with `terraform state show` rather than making
it ambient.

**`local_authentication_enabled`, not `local_authentication_disabled`.** The
negative form is deprecated and removed in azurerm v5. Note the inversion when
migrating: `disabled = false` becomes `enabled = true`.

**Disabling a public endpoint fails silently without AMPLS.** Setting
`internet_ingestion_enabled = false` with no Azure Monitor Private Link Scope
does not error — it severs the data path. Agents keep running, report healthy,
and no data arrives. The `private_link_scope_configured` gate forces the caller
to assert an AMPLS exists before the plan will proceed.

**`allow_resource_only_permissions` stays true.** It lets an application team
read its own resource's logs without being granted workspace-wide access, which
is the least-privilege position.

---

## Cost

The workspace itself carries **no charge**. Cost comes from two places:

| Driver | Note |
|---|---|
| Ingestion | Billed per GB. The first 5 GB/month is free at billing-account level. |
| Retention beyond 31 days | Billed per GB per month. 30 days is the free choice; `retention_is_billable` reports when a setting crosses the line. |

**The daily cap drops data.** When `daily_quota_gb` is reached, ingestion stops
for the remainder of the UTC day and what was dropped is unrecoverable —
including security signals. Appropriate in dev to protect a free-tier
allowance; the `profile` module forbids it in production.

---

## Deployed state

`dev` — applied and verified in Azure:

```
name          log-cloudcart-dev-eus-001
sku           PerGB2018
retention     30 days
daily cap     0.5 GB
identity      SystemAssigned
state         Succeeded
```
