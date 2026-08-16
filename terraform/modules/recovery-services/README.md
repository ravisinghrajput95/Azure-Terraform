# recovery-services

Recovery Services vault and backup policies.

Module 21 of 22, and the last to be built. Lives in the `mon` resource group,
deliberately outside the `app` group: a vault must **outlive the resources it
protects**. Placing it beside them means a `terraform destroy` of the app stack
takes the backups with it, at exactly the moment they matter.

---

## What this module protects, and what it does not

Its original purpose was backing up the app and business tier VM Scale Sets.
Those never existed — compute became AKS (see `ARCHITECTURE.md` §6b) — so the
honest position is that in this platform there is currently **very little left
for a Recovery Services vault to protect**:

| Candidate | Status |
|---|---|
| VM Scale Sets | Gone. Compute is AKS. |
| Azure SQL | Already covered by native short-term and long-term retention in the `sql` module. A vault would duplicate it. |
| Storage account | Blob-only, no file shares. Already has versioning and soft delete. |
| AKS cluster and volumes | Needs Azure Backup for AKS, which is `Microsoft.DataProtection` and a **Backup vault**, not this resource type — plus an in-cluster extension. |

So the module deploys a vault and its policies, and **creates no protected
items at all**. That is deliberate in two ways:

1. There is nothing in dev to bind them to.
2. Binding a workload to a policy is a property of *that workload*, not of the
   vault. Doing it here would make the vault's lifecycle depend on the app
   stack it exists to outlive.

The vault and its policies are **free**. Azure bills per protected instance
plus the storage its recovery points consume, and there are none of either.

`backup_posture_summary` states this in plain language, because a vault that
protects nothing looks identical whether that was the intent or an omission.

---

## The silent failure: retention that retains nothing

On a **Weekly** schedule the backup runs only on the weekdays named in
`backup.weekdays`. A retention rule naming any *other* weekday selects a
recovery point that will never exist — so that retention tier keeps
**nothing**.

```hcl
backup {
  frequency = "Weekly"
  weekdays  = ["Sunday"]       # a recovery point exists only on Sunday
}

retention_weekly {
  count    = 4
  weekdays = ["Wednesday"]     # ...and this keeps four of nothing
}
```

Azure **accepts** this policy, reports it as valid, and displays a four-week
retention duration in the portal. The gap appears only when someone tries to
restore from a point that was never kept — which is to say, during an
incident, after the data is already gone.

The module rejects it at plan time, and applies the same check to
`retention_monthly` and `retention_yearly`. On a **Daily** schedule a backup
runs every day, so every weekday is available and the misalignment cannot
occur; the checks apply to weekly schedules only.

### Other guards

| Guard | What it prevents |
|---|---|
| Weekly schedule has weekdays | A policy that never runs at all |
| Daily schedule has `retention_daily` | Azure rejection naming the API field |
| `retention_daily >= 7` | Below the Azure minimum for VM policies |
| Weekly schedule has no `retention_daily` | No daily recovery point exists to retain |
| `instant_restore_retention_days` in 1–5 | Outside the permitted range |
| `cross_region_restore` requires GeoRedundant | Restore from a copy that does not exist |
| `immutability = "Locked"` needs acknowledgement | An irreversible choice made by editing one word |

---

## Two settings that cannot be undone

**`immutability = "Locked"`** is irreversible. Once locked, recovery points
cannot be deleted or their retention shortened by anyone — not a subscription
owner, not Microsoft support — for the full retention of every recovery point
already taken. It is the correct posture against ransomware and the wrong one
anywhere a mistake needs undoing. It therefore requires
`immutability_lock_acknowledged = true`.

**`storage_mode_type`** cannot be changed once any item is protected. Azure
rejects the update, and the only remedy is a new vault, which means abandoning
the existing recovery points. The default here is `LocallyRedundant`;
**Azure's** default is `GeoRedundant`, which costs materially more, so leaving
it unset in a cost-sensitive environment is an expensive silence.

---

## A deprecated argument that is deliberately absent

`soft_delete_enabled` is deprecated on `azurerm_recovery_services_vault` in
azurerm 4.x, and this provider version offers **no replacement argument**. It
is therefore not set: Azure's default (soft delete ON) is also the correct
posture, and restating a default through a deprecated argument buys nothing.

Its consequence is worth knowing. With soft delete on, a vault holding
protected items cannot be deleted until those items are purged, which takes 14
days — the same shape of trap as Key Vault purge protection, which `profile`
deliberately disables in dev for exactly this reason. Because this module
creates no protected items, the vault stays freely destroyable, which matters
where `terraform destroy` is the primary cost control.

---

## Usage

```hcl
module "recovery_services" {
  source = "../../modules/recovery-services"

  name                = module.naming.names.recovery_services_vault
  resource_group_name = module.resource_group.names["mon"]
  location            = var.location
  tags                = module.tags.tags

  storage_mode_type = "LocallyRedundant"

  vm_backup_policies = {
    "bp-vm-daily" = {
      frequency       = "Daily"
      time            = "23:00"
      retention_daily = module.profile.profile.backup_retention_days
    }
  }
}
```

Note the module is **not** gated on `profile.enable_backup`. That flag governs
whether workloads are *protected*, and this module never protects anything —
the vault and policies are free and exist so the configuration is deployed and
verifiable wherever the workloads later appear.

## Key inputs

| Name | Default | Description |
|---|---|---|
| `storage_mode_type` | `LocallyRedundant` | Immutable once anything is protected. |
| `cross_region_restore_enabled` | `false` | Requires GeoRedundant. |
| `immutability` | `Disabled` | `Locked` is irreversible. |
| `immutability_lock_acknowledged` | `false` | Required for `Locked`. |
| `vm_backup_policies` | `{}` | Weekday alignment validated. |
| `file_share_backup_policies` | `{}` | Same rules. |
| `alerts_for_all_job_failures_enabled` | `true` | Azure Backup's own notification path. |

## Key outputs

| Name | Description |
|---|---|
| `backup_posture_summary` | Plain language, including states that look healthy and are not |
| `protected_item_count` | Always 0, by design |
| `vm_policy_ids` | For a protected VM to reference |
| `storage_mode_type` | Surfaced because it cannot be changed later |
| `immutability` | Surfaced because `Locked` cannot be reversed |

---

## If this platform later needs real backup

- **AKS cluster and persistent volumes** — `azurerm_data_protection_backup_vault`
  plus `azurerm_data_protection_backup_instance_kubernetes_cluster`, and the
  AKS backup extension installed in the cluster. Note the extension needs
  schedulable capacity, which a single-node cluster at its vCPU quota does not
  have.
- **Blob storage** — `azurerm_data_protection_backup_policy_blob_storage`,
  which overlaps with the versioning and soft delete already configured.
- **VMs or Azure Files**, if either ever exists — this vault and these policies,
  plus `azurerm_backup_protected_vm` or `azurerm_backup_protected_file_share`
  alongside the workload.

---

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
| [azurerm_backup_policy_file_share.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/backup_policy_file_share) | resource |
| [azurerm_backup_policy_vm.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/backup_policy_vm) | resource |
| [azurerm_recovery_services_vault.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/recovery_services_vault) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alerts_for_all_job_failures_enabled"></a> [alerts\_for\_all\_job\_failures\_enabled](#input\_alerts\_for\_all\_job\_failures\_enabled) | Built-in vault alerting on backup job failures. Independent of the monitor module's action group — this is Azure Backup's own notification path, and it is the only one that reports a backup that silently stopped running. | `bool` | `true` | no |
| <a name="input_alerts_for_critical_operation_failures_enabled"></a> [alerts\_for\_critical\_operation\_failures\_enabled](#input\_alerts\_for\_critical\_operation\_failures\_enabled) | Built-in vault alerting on critical operations, such as deleting backup data. | `bool` | `true` | no |
| <a name="input_cross_region_restore_enabled"></a> [cross\_region\_restore\_enabled](#input\_cross\_region\_restore\_enabled) | Allow restore into the paired region. Requires storage\_mode\_type = "GeoRedundant" — the combination is rejected by a precondition rather than at apply, because the Azure error names only one of the two settings. | `bool` | `false` | no |
| <a name="input_file_share_backup_policies"></a> [file\_share\_backup\_policies](#input\_file\_share\_backup\_policies) | Azure Files backup policies, keyed by policy name. Same weekday-alignment rules as VM policies. | <pre>map(object({<br/>    frequency = optional(string, "Daily")<br/>    time      = optional(string, "23:00")<br/>    timezone  = optional(string, "UTC")<br/><br/>    retention_daily = optional(number)<br/><br/>    retention_weekly = optional(object({<br/>      count    = number<br/>      weekdays = set(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_immutability"></a> [immutability](#input\_immutability) | Immutability state: "Disabled", "Unlocked" or "Locked".<br/><br/>"Locked" is IRREVERSIBLE. Once locked, recovery points cannot be deleted<br/>or shortened by anyone — including a subscription owner, including<br/>Microsoft support — for the whole of their retention. It is the correct<br/>posture against ransomware and the wrong one anywhere a mistake needs<br/>undoing. Requires explicit acknowledgement. | `string` | `"Disabled"` | no |
| <a name="input_immutability_lock_acknowledged"></a> [immutability\_lock\_acknowledged](#input\_immutability\_lock\_acknowledged) | Explicit acknowledgement that immutability = "Locked" is irreversible. Required only for that value, so the irreversible choice cannot be made by editing one word. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region. A vault can only protect resources in its OWN region, so this must match the workloads it backs up. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Vault name, from naming.recovery\_services\_vault. Unique within the resource group. | `string` | n/a | yes |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether the vault accepts traffic from public networks. Backup traffic from Azure resources does not need this, but disabling it without a private endpoint blocks management operations from an operator machine. | `bool` | `true` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "mon" lifecycle scope — the vault must outlive the resources it protects, so it does not belong in the app group that gets torn down. | `string` | n/a | yes |
| <a name="input_sku"></a> [sku](#input\_sku) | Vault SKU. "Standard" for Recovery Services; "RS0" is the legacy tier and should not be used for new vaults. | `string` | `"Standard"` | no |
| <a name="input_storage_mode_type"></a> [storage\_mode\_type](#input\_storage\_mode\_type) | Backup storage redundancy.<br/><br/>Cannot be changed once ANY item is protected in the vault — Azure rejects<br/>the update, and the only remedy is a new vault, which means losing the<br/>existing recovery points. Choose it deliberately at creation.<br/><br/>GeoRedundant costs materially more than LocallyRedundant and is the Azure<br/>default, so leaving it unset in a cost-sensitive environment is an<br/>expensive silence. | `string` | `"LocallyRedundant"` | no |
| <a name="input_system_assigned_identity_enabled"></a> [system\_assigned\_identity\_enabled](#input\_system\_assigned\_identity\_enabled) | Enable a system-assigned managed identity. Required for customer-managed keys and for cross-subscription restore. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_vm_backup_policies"></a> [vm\_backup\_policies](#input\_vm\_backup\_policies) | Virtual machine backup policies, keyed by policy name.<br/><br/>The retention weekday alignment is the reason this module validates as much<br/>as it does. On a Weekly schedule, a retention rule naming a weekday the<br/>backup does not run on retains NOTHING — Azure accepts the policy, shows it<br/>as valid, and silently keeps no long-term recovery points at all. | <pre>map(object({<br/>    frequency = optional(string, "Daily")<br/>    time      = optional(string, "23:00")<br/>    timezone  = optional(string, "UTC")<br/><br/>    # Required when frequency is "Weekly"; ignored when Daily.<br/>    weekdays = optional(set(string), [])<br/><br/>    instant_restore_retention_days = optional(number, 2)<br/><br/>    retention_daily = optional(number)<br/><br/>    retention_weekly = optional(object({<br/>      count    = number<br/>      weekdays = set(string)<br/>    }))<br/><br/>    retention_monthly = optional(object({<br/>      count    = number<br/>      weekdays = set(string)<br/>      weeks    = set(string)<br/>    }))<br/><br/>    retention_yearly = optional(object({<br/>      count    = number<br/>      months   = set(string)<br/>      weekdays = set(string)<br/>      weeks    = set(string)<br/>    }))<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_backup_posture_summary"></a> [backup\_posture\_summary](#output\_backup\_posture\_summary) | Consolidated posture in plain language, including the states that look healthy and are not. |
| <a name="output_file_share_policy_ids"></a> [file\_share\_policy\_ids](#output\_file\_share\_policy\_ids) | Map of file share policy name to resource ID. |
| <a name="output_id"></a> [id](#output\_id) | Vault resource ID. |
| <a name="output_immutability"></a> [immutability](#output\_immutability) | Immutability state. "Locked" is irreversible and cannot be undone by anyone, at any level. |
| <a name="output_location"></a> [location](#output\_location) | Vault region. A vault protects resources in its OWN region only, so this constrains what it can ever back up. |
| <a name="output_name"></a> [name](#output\_name) | Vault name. Backup protection resources reference the vault by name plus resource group rather than by ID. |
| <a name="output_principal_id"></a> [principal\_id](#output\_principal\_id) | System-assigned identity principal ID, or null when the identity is disabled. Grant this access when the vault must reach a customer-managed key. |
| <a name="output_protected_item_count"></a> [protected\_item\_count](#output\_protected\_item\_count) | Always zero. This module creates policies, never protected items — binding a workload to a policy belongs with that workload, not with a vault whose whole purpose is to outlive it. |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Resource group containing the vault. |
| <a name="output_storage_mode_type"></a> [storage\_mode\_type](#output\_storage\_mode\_type) | Backup storage redundancy. Cannot be changed once any item is protected — the remedy is a new vault, which means losing existing recovery points. |
| <a name="output_vm_policy_ids"></a> [vm\_policy\_ids](#output\_vm\_policy\_ids) | Map of VM policy name to resource ID. A protected VM references one of these. |
<!-- END_TF_DOCS -->
