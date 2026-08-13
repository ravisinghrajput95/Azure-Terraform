################################################################################
# Backend configuration
#
# These are the values each environment's backend.conf needs. backend.conf is
# gitignored, so this output is how it gets filled in without copying names by
# hand.
################################################################################

output "resource_group_name" {
  description = "Resource group holding the state account."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "State storage account name."
  value       = azurerm_storage_account.tfstate.name
}

output "container_names" {
  description = "Map of environment to its state container."
  value       = { for k, c in azurerm_storage_container.tfstate : k => c.name }
}

output "backend_config" {
  description = "Ready-made backend.conf contents per environment. Write one of these to environments/<env>/backend.conf."
  value = {
    for env, c in azurerm_storage_container.tfstate : env => join("\n", [
      "resource_group_name  = \"${azurerm_resource_group.tfstate.name}\"",
      "storage_account_name = \"${azurerm_storage_account.tfstate.name}\"",
      "container_name       = \"${c.name}\"",
      "key                  = \"cloudcart.${env}.tfstate\"",
      "use_azuread_auth     = true",
      "subscription_id      = \"${var.subscription_id}\"",
    ])
  }
}

################################################################################
# Posture
################################################################################

output "shared_key_access_is_open" {
  description = "True when the account still accepts shared-key authentication. Shared keys are static, non-expiring and unscopable, and grant total control of every state file — so true is a weakness, reported rather than assumed."
  value       = var.shared_access_key_enabled
}

output "state_protection_summary" {
  description = "What actually protects the state files, in plain language."
  value = join(" ", compact([
    "Versioning enabled — an overwritten or truncated state push can be rolled back.",
    var.blob_soft_delete_retention_days > 0 ? "Blob soft delete retains deletions for ${var.blob_soft_delete_retention_days} days." : "WARNING: blob soft delete is DISABLED, so a deleted state file is unrecoverable. Versioning does not cover deletion.",
    var.shared_access_key_enabled ? "WARNING: shared key access is ENABLED. The backends use Entra auth and do not need it; a leaked key grants total control of every environment's state." : "Shared key access disabled; Entra ID only.",
  ]))
}
