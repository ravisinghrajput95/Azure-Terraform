################################################################################
# Vault coherence
################################################################################

locals {
  # Cross-region restore reads from the geo-replicated copy. Without
  # GeoRedundant storage there is no such copy, and Azure's error names only
  # one of the two settings involved.
  cross_region_restore_without_geo = (
    var.cross_region_restore_enabled && var.storage_mode_type != "GeoRedundant"
  )

  # "Locked" cannot be undone by anyone, at any level, for the full retention
  # of every recovery point already taken.
  immutability_locked                = var.immutability == "Locked"
  immutability_locked_unacknowledged = local.immutability_locked && !var.immutability_lock_acknowledged
  storage_is_geo_redundant           = var.storage_mode_type == "GeoRedundant"
}

################################################################################
# Retention alignment
#
# The module's central check, and the only failure here that is completely
# silent.
#
# On a WEEKLY schedule the backup runs only on the weekdays named in
# `weekdays`. A retention rule naming any other weekday selects a recovery
# point that will never exist, so that retention tier keeps NOTHING. Azure
# accepts the policy, reports it as valid, and shows a retention duration in
# the portal that never materialises.
#
# On a DAILY schedule a backup runs every day, so every weekday is available
# and the alignment cannot fail. The checks below therefore only apply to
# weekly schedules.
################################################################################

locals {
  all_policies = merge(
    { for k, p in var.vm_backup_policies : "vm/${k}" => p },
    { for k, p in var.file_share_backup_policies : "fileshare/${k}" => p },
  )

  weekly_vm_policies = {
    for k, p in var.vm_backup_policies : k => p if p.frequency == "Weekly"
  }

  weekly_file_share_policies = {
    for k, p in var.file_share_backup_policies : k => p if p.frequency == "Weekly"
  }

  # Weekday named by a retention tier but never produced by the schedule.
  weekly_retention_misalignments = sort(concat(
    flatten([
      for k, p in local.weekly_vm_policies : [
        for wd in setsubtract(p.retention_weekly.weekdays, p.weekdays) :
        "vm/${k} retention_weekly wants ${wd}, schedule runs ${join("/", sort(tolist(p.weekdays)))}"
      ] if p.retention_weekly != null
    ]),
    flatten([
      for k, p in local.weekly_vm_policies : [
        for wd in setsubtract(p.retention_monthly.weekdays, p.weekdays) :
        "vm/${k} retention_monthly wants ${wd}, schedule runs ${join("/", sort(tolist(p.weekdays)))}"
      ] if p.retention_monthly != null
    ]),
    flatten([
      for k, p in local.weekly_vm_policies : [
        for wd in setsubtract(p.retention_yearly.weekdays, p.weekdays) :
        "vm/${k} retention_yearly wants ${wd}, schedule runs ${join("/", sort(tolist(p.weekdays)))}"
      ] if p.retention_yearly != null
    ]),
    flatten([
      for k, p in local.weekly_file_share_policies : [
        for wd in setsubtract(p.retention_weekly.weekdays, p.weekdays) :
        "fileshare/${k} retention_weekly wants ${wd}"
      ] if p.retention_weekly != null
    ]),
  ))

  # A weekly schedule with no weekdays never runs at all.
  weekly_without_weekdays = sort([
    for k, p in local.weekly_vm_policies : "vm/${k}"
    if length(p.weekdays) == 0
  ])

  ##############################################################################
  # Schedule and retention shape
  #
  # Azure rejects these, but its messages name the API field rather than the
  # Terraform argument, so they are cheaper to catch here.
  ##############################################################################

  # A daily schedule must retain daily recovery points, and Azure requires at
  # least 7 of them for a VM policy.
  daily_without_daily_retention = sort([
    for k, p in var.vm_backup_policies : "vm/${k}"
    if p.frequency == "Daily" && p.retention_daily == null
  ])

  daily_retention_too_short = sort([
    for k, p in var.vm_backup_policies : "vm/${k} (${p.retention_daily})"
    if p.frequency == "Daily" && p.retention_daily != null && p.retention_daily < 7
  ])

  # A weekly schedule cannot carry daily retention — there is no daily
  # recovery point to retain.
  weekly_with_daily_retention = sort([
    for k, p in var.vm_backup_policies : "vm/${k}"
    if p.frequency == "Weekly" && p.retention_daily != null
  ])

  # Azure caps instant restore at 5 days for the classic policy type.
  instant_restore_out_of_range = sort([
    for k, p in var.vm_backup_policies : "vm/${k} (${p.instant_restore_retention_days})"
    if p.instant_restore_retention_days < 1 || p.instant_restore_retention_days > 5
  ])
}

################################################################################
# Posture reporting
################################################################################

locals {
  vm_policy_count         = length(var.vm_backup_policies)
  file_share_policy_count = length(var.file_share_backup_policies)
  total_policy_count      = local.vm_policy_count + local.file_share_policy_count

  # This module deliberately creates NO protected items. Binding a workload to
  # a policy is a property of that workload, not of the vault, and doing it
  # here would make the vault's lifecycle depend on the app stack it is
  # supposed to outlive.
  #
  # A vault holding policies and protecting nothing is therefore the expected
  # steady state wherever there is nothing to back up — but it is
  # indistinguishable from one whose protection was forgotten, so it is stated
  # in an output rather than left to be inferred.
  policies_defined_but_nothing_protected = local.total_policy_count > 0
}
