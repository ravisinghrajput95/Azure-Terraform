################################################################################
# Vault
################################################################################

output "id" {
  description = "Vault resource ID."
  value       = azurerm_recovery_services_vault.this.id
}

output "name" {
  description = "Vault name. Backup protection resources reference the vault by name plus resource group rather than by ID."
  value       = azurerm_recovery_services_vault.this.name
}

output "resource_group_name" {
  description = "Resource group containing the vault."
  value       = azurerm_recovery_services_vault.this.resource_group_name
}

output "location" {
  description = "Vault region. A vault protects resources in its OWN region only, so this constrains what it can ever back up."
  value       = azurerm_recovery_services_vault.this.location
}

output "principal_id" {
  description = "System-assigned identity principal ID, or null when the identity is disabled. Grant this access when the vault must reach a customer-managed key."
  value       = var.system_assigned_identity_enabled ? one(azurerm_recovery_services_vault.this.identity[*].principal_id) : null
}

################################################################################
# Policies
################################################################################

output "vm_policy_ids" {
  description = "Map of VM policy name to resource ID. A protected VM references one of these."
  value       = { for k, p in azurerm_backup_policy_vm.this : k => p.id }
}

output "file_share_policy_ids" {
  description = "Map of file share policy name to resource ID."
  value       = { for k, p in azurerm_backup_policy_file_share.this : k => p.id }
}

################################################################################
# Posture
#
# Reported rather than assumed. A vault that protects nothing looks identical
# whether that was the intent or an omission.
################################################################################

output "storage_mode_type" {
  description = "Backup storage redundancy. Cannot be changed once any item is protected — the remedy is a new vault, which means losing existing recovery points."
  value       = azurerm_recovery_services_vault.this.storage_mode_type
}

output "immutability" {
  description = "Immutability state. \"Locked\" is irreversible and cannot be undone by anyone, at any level."
  value       = azurerm_recovery_services_vault.this.immutability
}

output "protected_item_count" {
  description = "Always zero. This module creates policies, never protected items — binding a workload to a policy belongs with that workload, not with a vault whose whole purpose is to outlive it."
  value       = 0
}

output "backup_posture_summary" {
  description = "Consolidated posture in plain language, including the states that look healthy and are not."
  value = join(" ", compact([
    "${local.total_policy_count} backup polic(ies) defined (${local.vm_policy_count} VM, ${local.file_share_policy_count} file share), 0 items protected.",
    local.policies_defined_but_nothing_protected ? "Policies exist but nothing is bound to them — correct where there is nothing to back up, indistinguishable from an omission where there is." : "",
    local.total_policy_count == 0 ? "WARNING: the vault holds no policies at all." : "",
    "Storage is ${var.storage_mode_type}${local.storage_is_geo_redundant ? "" : " — no geo-replicated copy, so cross-region restore is unavailable"}.",
    local.immutability_locked ? "Immutability is LOCKED and cannot be reversed." : "",
  ]))
}
