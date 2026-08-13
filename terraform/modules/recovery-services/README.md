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
