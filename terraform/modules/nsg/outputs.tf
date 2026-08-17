################################################################################
# Network security groups
################################################################################

output "ids" {
  description = "Map of NSG name to ARM resource ID. Feed this to the diagnostics module with for_each to attach flow diagnostics to every NSG."
  value       = { for name, nsg in azurerm_network_security_group.this : name => nsg.id }
}

output "names" {
  description = "Map of NSG name to name, for callers that need the map shape."
  value       = { for name, nsg in azurerm_network_security_group.this : name => nsg.name }
}

################################################################################
# Associations
################################################################################

output "associated_subnet_ids" {
  description = "Map of NSG name to the subnet it protects. An NSG absent from this map exists but is attached to nothing, so its rules are inert."
  value       = local.associations
}

output "unassociated_nsgs" {
  description = "NSGs that were created but attached to no subnet. Their rules have no effect. Usually this is a staged configuration, occasionally it is a subnet reference that silently evaluated to null."
  value = sort([
    for name, nsg in var.network_security_groups : name
    if nsg.subnet_id == null
  ])
}

################################################################################
# Rule inventory
#
# Surfaced so the effective policy can be reviewed from `terraform output`
# without reading six module invocations, and so a security review has a single
# artefact to diff between environments.
################################################################################

output "rule_count" {
  description = "Total number of security rules managed by this module."
  value       = length(local.rules)
}

output "rules_by_nsg" {
  description = "Map of NSG name to its rules in Azure's evaluation order — direction, then ascending priority. A single artefact for reviewing effective policy or diffing it between environments. Each rule carries its source and destination prefixes and destination ports as lists, with the singular and plural forms of each collapsed into one, so a rule's reach can be read without knowing which form declared it."
  value       = local.rules_by_nsg
}

################################################################################
# Security posture
################################################################################

output "nsgs_with_explicit_inbound_deny" {
  description = "NSGs carrying an explicit inbound deny-all rule. Any NSG missing from this list relies on Azure's built-in AllowVnetInBound at priority 65000, which permits all intra-VNet traffic and therefore enforces no tier isolation."
  value       = sort(tolist(local.nsgs_with_inbound_deny))
}
