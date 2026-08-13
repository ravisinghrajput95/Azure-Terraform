################################################################################
# Recovery Services vault
#
# Lives in the monitoring resource group, deliberately outside the app group.
# A vault must outlive the resources it protects: putting it beside them means
# a `terraform destroy` of the app stack takes the backups with it, which is
# the one moment they matter.
#
# NOTE ON soft_delete_enabled: the provider deprecates that argument and offers
# no replacement in this major version, so it is deliberately NOT set. Azure's
# default — soft delete ON — is also the correct posture, and setting a
# deprecated argument to restate a default buys nothing.
#
# Its consequence is worth knowing: with soft delete on, a vault holding
# protected items cannot be deleted until those items are purged, which takes
# 14 days. This module creates no protected items, so the vault stays freely
# destroyable — that matters on a credit-limited subscription where
# `terraform destroy` is the primary cost control.
################################################################################

resource "azurerm_recovery_services_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  storage_mode_type            = var.storage_mode_type
  cross_region_restore_enabled = var.cross_region_restore_enabled
  immutability                 = var.immutability

  public_network_access_enabled = var.public_network_access_enabled

  dynamic "identity" {
    for_each = var.system_assigned_identity_enabled ? [1] : []

    content {
      type = "SystemAssigned"
    }
  }

  # Azure Backup's own notification path. Distinct from the monitor module's
  # action group, and the only one that reports a backup which silently
  # stopped running rather than failed loudly.
  monitoring {
    alerts_for_all_job_failures_enabled            = var.alerts_for_all_job_failures_enabled
    alerts_for_critical_operation_failures_enabled = var.alerts_for_critical_operation_failures_enabled
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = !local.cross_region_restore_without_geo
      error_message = join(" ", [
        "cross_region_restore_enabled is true but storage_mode_type is \"${var.storage_mode_type}\".",
        "Cross-region restore reads from the geo-replicated copy of the backup data, and without GeoRedundant storage no such copy exists.",
        "Azure's own error names only one of the two settings involved."
      ])
    }

    precondition {
      condition = !local.immutability_locked_unacknowledged
      error_message = join(" ", [
        "immutability is \"Locked\" but immutability_lock_acknowledged is false.",
        "Locking is IRREVERSIBLE: once locked, recovery points cannot be deleted or their retention shortened by anyone —",
        "not a subscription owner, not Microsoft support — for the full retention of every recovery point already taken.",
        "It is the correct posture against ransomware and the wrong one anywhere a mistake needs undoing.",
        "Set immutability_lock_acknowledged to confirm, so this cannot be chosen by editing a single word."
      ])
    }
  }
}

################################################################################
# VM backup policies
#
# Policies cost nothing. Azure bills per protected instance and for the storage
# its recovery points consume, so a vault holding policies and protecting
# nothing is free.
#
# for_each is over a statically-known map from variables, never over another
# resource's attributes — the latter works on an incremental apply and breaks
# on a cold one.
################################################################################

resource "azurerm_backup_policy_vm" "this" {
  for_each = var.vm_backup_policies

  name                = each.key
  resource_group_name = var.resource_group_name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  timezone            = each.value.timezone

  instant_restore_retention_days = each.value.instant_restore_retention_days

  backup {
    frequency = each.value.frequency
    time      = each.value.time
    weekdays  = each.value.frequency == "Weekly" ? each.value.weekdays : null
  }

  dynamic "retention_daily" {
    for_each = each.value.retention_daily != null ? [each.value.retention_daily] : []

    content {
      count = retention_daily.value
    }
  }

  dynamic "retention_weekly" {
    for_each = each.value.retention_weekly != null ? [each.value.retention_weekly] : []

    content {
      count    = retention_weekly.value.count
      weekdays = retention_weekly.value.weekdays
    }
  }

  dynamic "retention_monthly" {
    for_each = each.value.retention_monthly != null ? [each.value.retention_monthly] : []

    content {
      count    = retention_monthly.value.count
      weekdays = retention_monthly.value.weekdays
      weeks    = retention_monthly.value.weeks
    }
  }

  dynamic "retention_yearly" {
    for_each = each.value.retention_yearly != null ? [each.value.retention_yearly] : []

    content {
      count    = retention_yearly.value.count
      months   = retention_yearly.value.months
      weekdays = retention_yearly.value.weekdays
      weeks    = retention_yearly.value.weeks
    }
  }

  lifecycle {
    ############################################################################
    # Retention alignment.
    #
    # The only completely silent failure in this module: Azure accepts the
    # policy, reports it as valid, and shows a retention duration in the portal
    # that never materialises.
    ############################################################################
    precondition {
      condition = length(local.weekly_retention_misalignments) == 0
      error_message = join(" ", [
        "Retention rule(s) name a weekday the backup schedule never runs on: ${join("; ", local.weekly_retention_misalignments)}.",
        "That retention tier selects a recovery point which will never exist, so it retains NOTHING.",
        "Azure accepts the policy, shows it as valid, and displays a retention duration in the portal that never materialises —",
        "the gap appears only when someone tries to restore from a point that was never kept."
      ])
    }

    precondition {
      condition = length(local.weekly_without_weekdays) == 0
      error_message = join(" ", [
        "Weekly policy/policies have no weekdays: ${join(", ", local.weekly_without_weekdays)}.",
        "A weekly schedule with no weekday never runs, so the policy protects nothing at all."
      ])
    }

    ############################################################################
    # Schedule and retention shape. Azure rejects each of these, but its
    # messages name the API field rather than the Terraform argument.
    ############################################################################
    precondition {
      condition     = length(local.daily_without_daily_retention) == 0
      error_message = "Daily policy/policies have no retention_daily: ${join(", ", local.daily_without_daily_retention)}. A daily schedule must retain daily recovery points."
    }

    precondition {
      condition     = length(local.daily_retention_too_short) == 0
      error_message = "Daily retention below the Azure minimum of 7 days: ${join(", ", local.daily_retention_too_short)}."
    }

    precondition {
      condition     = length(local.weekly_with_daily_retention) == 0
      error_message = "Weekly policy/policies carry retention_daily: ${join(", ", local.weekly_with_daily_retention)}. A weekly schedule produces no daily recovery point to retain."
    }

    precondition {
      condition     = length(local.instant_restore_out_of_range) == 0
      error_message = "instant_restore_retention_days outside the permitted 1-5 range: ${join(", ", local.instant_restore_out_of_range)}."
    }
  }
}

################################################################################
# File share backup policies
################################################################################

resource "azurerm_backup_policy_file_share" "this" {
  for_each = var.file_share_backup_policies

  name                = each.key
  resource_group_name = var.resource_group_name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  timezone            = each.value.timezone

  backup {
    frequency = each.value.frequency
    time      = each.value.time
  }

  dynamic "retention_daily" {
    for_each = each.value.retention_daily != null ? [each.value.retention_daily] : []

    content {
      count = retention_daily.value
    }
  }

  dynamic "retention_weekly" {
    for_each = each.value.retention_weekly != null ? [each.value.retention_weekly] : []

    content {
      count    = retention_weekly.value.count
      weekdays = retention_weekly.value.weekdays
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.weekly_retention_misalignments) == 0
      error_message = "Retention rule(s) name a weekday the backup schedule never runs on: ${join("; ", local.weekly_retention_misalignments)}. That tier retains nothing, and Azure reports the policy as valid."
    }
  }
}
