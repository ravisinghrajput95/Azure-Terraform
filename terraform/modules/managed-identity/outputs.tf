################################################################################
# Identities
################################################################################

output "ids" {
  description = "Map of tier key to identity ARM resource ID. This is what a scale set's identity block references."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.id }
}

output "principal_ids" {
  description = "Map of tier key to principal (object) ID. This is what role assignments and Key Vault RBAC grants reference — NOT the client ID."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.principal_id }
}

output "client_ids" {
  description = "Map of tier key to client (application) ID. This is what application code presents when requesting a token for a specific user-assigned identity — a VM with more than one assigned identity must name which to use."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.client_id }
}

output "names" {
  description = "Map of tier key to identity name."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.name }
}

output "tenant_id" {
  description = "Tenant the identities belong to. one() over the distinct set doubles as an assertion that every identity shares one tenant — if that were ever untrue, the plan fails rather than silently returning whichever came first."
  value = one(distinct([
    for identity in azurerm_user_assigned_identity.this : identity.tenant_id
  ]))
}

output "identities" {
  description = "Full detail per tier: id, name, principal_id, client_id. For callers needing more than one field."
  value = {
    for key, identity in azurerm_user_assigned_identity.this :
    key => {
      id           = identity.id
      name         = identity.name
      principal_id = identity.principal_id
      client_id    = identity.client_id
    }
  }
}

################################################################################
# Role assignments
################################################################################

output "role_assignment_ids" {
  description = "Map of assignment key to role assignment ID. Empty by default — most access in this platform is granted by the resource owner, scoped to itself, so the grant dies with the resource rather than outliving it."
  value       = { for key, assignment in azurerm_role_assignment.this : key => assignment.id }
}

################################################################################
# Propagation gate
#
# Depend on this from any module that uses an identity against a DATA PLANE,
# where a control-plane role assignment must already be effective:
#
#   module "key_vault" {
#     depends_on = [module.managed_identity]
#     ...
#   }
#
# Consuming the module creates the dependency automatically; this output exists
# to make the intent explicit and to expose whether a wait actually occurred.
################################################################################

output "ready" {
  description = "Identifier of the propagation wait, or null when the wait is disabled. Depend on this to order downstream data-plane use after the Entra ID propagation window."
  value       = local.wait_enabled ? time_sleep.propagation[0].id : null
}

output "propagation_delay_applied_seconds" {
  description = "Seconds actually waited after identity creation. Zero means no wait was applied, and a downstream data-plane operation may hit PrincipalNotFound intermittently."
  value       = local.wait_enabled ? var.propagation_delay_seconds : 0
}
