################################################################################
# Tag maps
################################################################################

output "tags" {
  description = "The composed tag map. Pass this to every resource's `tags` argument. Azure does not inherit tags from resource group to resource, so every resource must carry it explicitly."
  value       = local.tags
}

output "tier_tags" {
  description = "Map of tier to that tier's tag map, each being the base tags plus `tier = <name>`. Use module.tags.tier_tags[\"app\"] rather than merging a tier tag at the call site."
  value       = local.tier_tags
}

output "mandatory_tags" {
  description = "Only the mandatory governance tags, without any additional_tags. Useful for Azure Policy definitions that assert the required set is present."
  value       = local.mandatory_tags
}

output "mandatory_tag_keys" {
  description = "Keys of the mandatory tag set. Feed this to a policy or compliance check that verifies tag presence across the subscription."
  value       = sort(local.mandatory_tag_keys)
}

################################################################################
# Individual values
#
# Exposed because several downstream modules branch on criticality or
# classification (backup retention, alert severity, encryption requirements)
# and should read them from here rather than taking duplicate inputs that could
# drift out of step with the tags actually applied.
################################################################################

output "criticality" {
  description = "Business criticality value, for modules that size backup retention or alert severity from it."
  value       = var.criticality
}

output "data_classification" {
  description = "Data classification value, for modules that gate encryption or audit settings on it."
  value       = var.data_classification
}

output "owner" {
  description = "Accountable owner email, for wiring into monitor action groups."
  value       = var.owner
}

################################################################################
# Ordering handle
################################################################################

output "validation_id" {
  description = "Identifier of the internal validation resource. Depend on this to order tag validation ahead of resource creation."
  value       = terraform_data.validation.id
}
