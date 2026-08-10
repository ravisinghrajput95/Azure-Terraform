################################################################################
# Mandatory tag set
#
# camelCase throughout, matching the convention already in use in this
# repository. Azure treats tag keys as case-insensitive for lookup but
# case-preserving for display, so the convention has to be picked once and held.
#
# Deliberately ABSENT: any tag derived from timestamp(), the current git commit,
# or a build number. Those change on every plan or every deploy, which produces
# a diff on every tagged resource in the estate — thousands of no-op updates
# that bury real changes in plan output. Deployment provenance belongs in a
# deployment record, not on every resource. See README.md.
################################################################################

locals {
  mandatory_tags = {
    workload           = var.workload
    environment        = var.environment
    owner              = var.owner
    costCenter         = var.cost_center
    criticality        = var.criticality
    dataClassification = var.data_classification
    managedBy          = "Terraform"
  }

  mandatory_tag_keys = keys(local.mandatory_tags)
}

################################################################################
# Merge
#
# Mandatory tags are merged LAST so they win. Combined with the override
# precondition in main.tf, this means a caller cannot weaken governance tags
# either deliberately or by accident.
################################################################################

locals {
  tags = merge(var.additional_tags, local.mandatory_tags)

  # Tier-scoped variants, so callers do not merge a tier tag inline in six
  # different modules.
  tier_tags = {
    for tier in var.tiers :
    tier => merge(local.tags, { tier = tier })
  }
}

################################################################################
# Constraint checks
#
# Azure tag limits: 50 tags per resource, key length 512 (128 on storage
# accounts), value length 256. Keys may not contain < > % & \ ? /
#
# A violation here fails the apply on the first resource that carries the tag
# map — which is every resource — so catching it at plan time is worth the
# small amount of machinery below.
################################################################################

locals {
  invalid_key_characters = ["<", ">", "%", "&", "\\", "?", "/"]

  # Case-insensitive collision detection. merge() collapses exactly-equal keys,
  # but "Environment" and "environment" both survive it and then fail at the
  # Azure API with an unhelpful error.
  lowercased_keys = [for k in keys(local.tags) : lower(k)]

  case_colliding_keys = [
    for k in distinct(local.lowercased_keys) : k
    if length([for lk in local.lowercased_keys : lk if lk == k]) > 1
  ]

  # Attempts to override a mandatory tag, compared case-insensitively.
  attempted_overrides = [
    for k in keys(var.additional_tags) : k
    if contains([for mk in local.mandatory_tag_keys : lower(mk)], lower(k))
  ]

  oversized_keys = [
    for k in keys(local.tags) : k
    if length(k) > var.max_tag_key_length
  ]

  oversized_values = [
    for k, v in local.tags : k
    if length(v) > 256
  ]

  keys_with_invalid_characters = [
    for k in keys(local.tags) : k
    if length([for c in local.invalid_key_characters : c if strcontains(k, c)]) > 0
  ]

  empty_values = [
    for k, v in local.tags : k
    if length(trimspace(v)) == 0
  ]

  constraint_failures = concat(
    length(local.tags) > 50 ? ["Tag count is ${length(local.tags)}; Azure permits a maximum of 50 tags per resource."] : [],
    [for k in local.attempted_overrides : "additional_tags key \"${k}\" attempts to override the mandatory tag of the same name. Mandatory governance tags cannot be overridden."],
    [for k in local.case_colliding_keys : "Tag key \"${k}\" appears more than once when compared case-insensitively. Azure treats tag keys as case-insensitive and will reject the request."],
    [for k in local.oversized_keys : "Tag key \"${k}\" is ${length(k)} characters; the configured limit is ${var.max_tag_key_length}."],
    [for k in local.oversized_values : "Value of tag \"${k}\" exceeds the 256-character Azure limit."],
    [for k in local.keys_with_invalid_characters : "Tag key \"${k}\" contains a character Azure does not permit in tag names (< > % & \\ ? /)."],
    [for k in local.empty_values : "Tag \"${k}\" has an empty value. An empty tag conveys nothing and defeats cost allocation queries."],
  )
}
