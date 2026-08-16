# Module: `diagnostics`

Shared helper that attaches a diagnostic setting to any Azure resource,
discovering which log and metric categories that resource type supports rather
than being told.

Every module from Phase 2 onward routes through this one. It is how "no
duplicate code" is achieved for the cross-cutting concern.

---

## Why this is a module and not a copy-pasted block

Every Azure resource type exposes a different set of diagnostic categories, and
those sets change as Azure adds capabilities. Hardcoding category names per
resource type is the common approach and the common source of breakage:

- A category name that was valid last year fails the apply today.
- A category Azure added since is silently never collected — you discover the
  gap during an incident, when the data you need does not exist.
- Twenty modules each carrying their own list means twenty places to fix.

Reading `azurerm_monitor_diagnostic_categories` at plan time means the
configuration is correct for whatever the resource actually supports, now.

---

## Usage

```hcl
module "diagnostics_vnet" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.networking.vnet_id
  log_analytics_workspace_id = module.log_analytics.id
}
```

Excluding a high-volume category requires explicit mode, because a category
group is all-or-nothing:

```hcl
module "diagnostics_firewall" {
  source = "../../modules/diagnostics"

  target_resource_id         = module.firewall.id
  log_analytics_workspace_id = module.log_analytics.id

  log_selection           = "explicit"
  excluded_log_categories = ["AzureFirewallApplicationRule"]
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `target_resource_id` | `string` | — | Any ARM resource ID. |
| `name` | `string` | `"diag-to-law"` | Unique per target, not globally. |
| `log_analytics_workspace_id` | `string` | — | From `log-analytics`. |
| `log_analytics_destination_type` | `string` | `null` | `Dedicated`, `AzureDiagnostics`, or null to let Azure choose. |
| `storage_account_id` | `string` | `null` | Optional archive destination. |
| `log_selection` | `string` | `"all"` | `all`, `explicit` or `none`. |
| `excluded_log_categories` | `list(string)` | `[]` | Requires `explicit`. |
| `enable_metrics` | `bool` | `true` | |
| `excluded_metric_categories` | `list(string)` | `[]` | |

## Outputs

`id`, `name`, `target_resource_id`, `available_log_categories`,
`available_log_groups`, `available_metrics`, `collected_log_categories`,
`collected_metrics`, `uses_category_group`

---

## Design notes

**`enabled_log` and `enabled_metric`, never `log` or `metric`.** The `metric`
block is flagged deprecated in the azurerm 4.x schema and is removed in v5.
The `retention_policy` sub-block those blocks carried no longer exists at all —
retention now belongs to the destination: workspace retention settings, or a
storage account lifecycle policy.

**`log_selection = "all"` prefers the `allLogs` category group.** Categories
Azure adds later are then collected automatically, with no code change and no
silent gap. The module falls back to enumerating individual categories when a
resource type has no `allLogs` group, rather than assuming one exists.

**`log_analytics_destination_type` defaults to null.** `Dedicated` routes logs
to resource-specific tables, which are typed and cheaper to query, and is the
better choice where supported — but not every resource type supports it, and
forcing it fails the apply. A generic helper cannot assume; the caller can
override per resource.

**`for_each` keys on the category name, not an index.** Keying on an index
would mean a category being added upstream re-indexes the rest, and Terraform
would plan to replace unrelated entries.

**Four preconditions, each covering a silent failure:**

| Precondition | Silent failure it prevents |
|---|---|
| At least one log or metric enabled | Azure returns an opaque `BadRequest` with no hint that the cause is a resource type exposing no categories |
| Excluded log categories must exist | A typo means the category keeps being collected — surfaces as an unexplained ingestion bill, not an error |
| Excluded metric categories must exist | Same |
| Exclusions require `explicit` mode | Exclusions against a category group are silently ignored, since a group is all-or-nothing |

**`uses_category_group` is an output** so a caller can distinguish "collecting
everything via the group" from "collecting nothing", which
`collected_log_categories = []` alone cannot express.

---

## Cost

The diagnostic setting itself is free. Cost is entirely the ingestion it
generates into Log Analytics, billed per GB.

The usual cause of an unexpected workspace bill is one very high-volume
category — Azure Firewall application rule logs and Application Gateway access
logs are the common offenders. That is what `log_selection = "explicit"` plus
`excluded_log_categories` is for.

---

## Deployed state

`dev` — applied and verified in Azure against the Log Analytics workspace
itself, so that workspace access and query activity are audited:

```
name        diag-to-law
target      log-cloudcart-dev-eus-001
logs        allLogs      enabled
            audit        not enabled (subsumed by allLogs)
metrics     AllMetrics   enabled
```

Categories were discovered, not configured.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_monitor_diagnostic_setting.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_categories.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/monitor_diagnostic_categories) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_enable_metrics"></a> [enable\_metrics](#input\_enable\_metrics) | Whether to collect platform metrics. Metrics are low volume relative to logs and are what most alert rules evaluate, so disabling them is rarely the right cost lever. | `bool` | `true` | no |
| <a name="input_excluded_log_categories"></a> [excluded\_log\_categories](#input\_excluded\_log\_categories) | Log categories to omit. Only meaningful with log\_selection = "explicit", because a category group is all-or-nothing. Use for a genuinely high-volume, low-value category — the usual reason a workspace bill grows unexpectedly. | `list(string)` | `[]` | no |
| <a name="input_excluded_metric_categories"></a> [excluded\_metric\_categories](#input\_excluded\_metric\_categories) | Metric categories to omit. Most resource types expose only "AllMetrics". | `list(string)` | `[]` | no |
| <a name="input_log_analytics_destination_type"></a> [log\_analytics\_destination\_type](#input\_log\_analytics\_destination\_type) | "Dedicated" routes logs to resource-specific tables, which are typed, cheaper to query and the modern default. "AzureDiagnostics" routes everything into one legacy wide table. Null lets Azure choose the appropriate mode for the resource type — correct for a generic helper, because not every resource type supports Dedicated and forcing it fails the apply. | `string` | `null` | no |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | Workspace to send diagnostics to, from the log-analytics module's id output. | `string` | n/a | yes |
| <a name="input_log_selection"></a> [log\_selection](#input\_log\_selection) | How log categories are chosen:<br/><br/>  "all"      Use the allLogs category group when the resource supports it,<br/>             so categories Azure adds later are collected automatically<br/>             without a code change. Falls back to enumerating every<br/>             discovered category when the resource has no allLogs group.<br/><br/>  "explicit" Enumerate each discovered category individually. Required if<br/>             excluded\_log\_categories is used, since a category group cannot<br/>             be partially excluded.<br/><br/>  "none"     Collect no logs. Metrics only. | `string` | `"all"` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the diagnostic setting. Diagnostic setting names must be unique per target resource, not globally, so a constant is safe and keeps addresses predictable across the estate. | `string` | `"diag-to-law"` | no |
| <a name="input_storage_account_id"></a> [storage\_account\_id](#input\_storage\_account\_id) | Optional storage account for long-term archive alongside the workspace. Archiving to storage is materially cheaper than extended workspace retention for data that is kept for compliance and rarely queried. | `string` | `null` | no |
| <a name="input_target_resource_id"></a> [target\_resource\_id](#input\_target\_resource\_id) | ARM resource ID of the resource to collect diagnostics from. Any resource type is accepted — the module discovers which log and metric categories that type supports rather than being told. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_available_log_categories"></a> [available\_log\_categories](#output\_available\_log\_categories) | Log categories the target resource type exposes, as discovered at plan time. |
| <a name="output_available_log_groups"></a> [available\_log\_groups](#output\_available\_log\_groups) | Log category groups the target exposes, typically "allLogs" and sometimes "audit". |
| <a name="output_available_metrics"></a> [available\_metrics](#output\_available\_metrics) | Metric categories the target exposes. Most resource types expose only "AllMetrics". |
| <a name="output_collected_log_categories"></a> [collected\_log\_categories](#output\_collected\_log\_categories) | Log categories actually enabled. Empty when the allLogs category group is used instead — check uses\_category\_group to distinguish that from collecting nothing. |
| <a name="output_collected_metrics"></a> [collected\_metrics](#output\_collected\_metrics) | Metric categories actually enabled. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the diagnostic setting. |
| <a name="output_name"></a> [name](#output\_name) | Name of the diagnostic setting. |
| <a name="output_target_resource_id"></a> [target\_resource\_id](#output\_target\_resource\_id) | Resource these diagnostics were attached to. |
| <a name="output_uses_category_group"></a> [uses\_category\_group](#output\_uses\_category\_group) | True when the allLogs category group is used, meaning categories Azure adds in future are collected automatically without a code change. False means categories were enumerated individually and a new one would go uncollected until the next plan. |
<!-- END_TF_DOCS -->
