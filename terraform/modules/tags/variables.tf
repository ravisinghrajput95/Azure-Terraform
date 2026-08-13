################################################################################
# Mandatory governance tags
#
# Every one of these is required. They are the tags that FinOps, security
# review and incident response actually query on. Making them optional with a
# default would guarantee that half the estate carries "unknown".
################################################################################

variable "workload" {
  description = "Workload or application identifier. Should match the value passed to the naming module so that tags and names agree."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.workload))
    error_message = "workload must be 2-10 characters, lowercase letters and digits only, and start with a letter, matching the naming module's constraint."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["dev", "qa", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, qa, stage, prod."
  }
}

variable "owner" {
  description = "Email address of the team or individual accountable for these resources. Used by cost reports and by incident response to find someone at 3am, so a distribution list is preferred over a personal address."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.owner))
    error_message = "owner must be a valid email address, e.g. \"platform-team@example.com\"."
  }
}

variable "cost_center" {
  description = "Chargeback code this workload bills to. Azure Cost Management groups by this tag, so an inconsistent value here silently breaks cost allocation."
  type        = string

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be empty."
  }

  validation {
    condition     = length(var.cost_center) <= 256
    error_message = "cost_center exceeds the 256-character Azure tag value limit."
  }
}

variable "criticality" {
  description = "Business criticality. Drives backup retention, alert routing and change-approval requirements downstream."
  type        = string

  validation {
    condition     = contains(["low", "medium", "high", "mission-critical"], var.criticality)
    error_message = "criticality must be one of: low, medium, high, mission-critical."
  }
}

variable "data_classification" {
  description = "Sensitivity of data handled. Determines encryption, private endpoint and audit requirements under most data-governance policies."
  type        = string

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_classification)
    error_message = "data_classification must be one of: public, internal, confidential, restricted."
  }
}

################################################################################
# Optional inputs
################################################################################

variable "additional_tags" {
  description = "Extra tags merged into the mandatory set. May not override a mandatory tag, and may not collide with one by case alone — Azure treats tag keys as case-insensitive, so \"Environment\" and \"environment\" are a conflict, not two tags."
  type        = map(string)
  default     = {}
}

variable "tiers" {
  description = "Workload tiers for which a tier-scoped tag map is precomputed. Lets callers use module.tags.tier_tags[\"app\"] instead of merging a tier tag inline at every call site."
  type        = list(string)
  default     = ["app", "biz", "db", "pep", "mgmt"]

  validation {
    condition     = length(distinct(var.tiers)) == length(var.tiers)
    error_message = "tiers must not contain duplicates."
  }
}

variable "max_tag_key_length" {
  description = "Maximum permitted tag key length. Defaults to 128 rather than Azure's general 512 limit because storage accounts cap tag names at 128 — validating against the strictest limit guarantees the same tag map applies cleanly to every resource type in the platform."
  type        = number
  default     = 128

  validation {
    condition     = var.max_tag_key_length > 0 && var.max_tag_key_length <= 512
    error_message = "max_tag_key_length must be between 1 and 512."
  }
}
