################################################################################
# Placement
################################################################################

variable "resource_group_name" {
  description = "Resource group for the identities. Should be the \"sec\" lifecycle scope — identities are security-team owned and outlive the compute that assumes them."
  type        = string
}

variable "location" {
  description = "Azure region, normalised form."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Identities
#
# User-assigned rather than system-assigned, deliberately.
#
# A system-assigned identity is created and destroyed with its resource. Every
# scale set replacement produces a NEW principal ID, which invalidates every
# role assignment and Key Vault grant pointing at the old one — so a routine
# instance refresh silently removes the application's access to its own
# secrets.
#
# A user-assigned identity has a lifecycle independent of the compute that
# assumes it. Permissions are granted once and survive replacement, and the
# same identity can be shared by a scale set and the deployment pipeline that
# updates it.
################################################################################

variable "identities" {
  description = "Map of tier key to identity name, e.g. { app = \"id-app-dev-eus-001\" }. The key is used to address the identity in outputs and in role_assignments, so it must be stable — renaming a key destroys and recreates the identity, invalidating every role assignment that referenced its principal ID."
  type        = map(string)

  validation {
    condition     = length(var.identities) > 0
    error_message = "At least one identity must be defined."
  }

  validation {
    condition     = alltrue([for name in values(var.identities) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$", name))])
    error_message = "Identity names must be 3-128 characters, alphanumerics, hyphens and underscores, and must start with an alphanumeric."
  }

  validation {
    condition     = length(distinct(values(var.identities))) == length(values(var.identities))
    error_message = "Identity names must be unique."
  }
}

################################################################################
# Role assignments
#
# Optional. Most access in this platform is granted by the RESOURCE OWNER
# rather than here: the key-vault and storage modules take a list of principal
# IDs and create role assignments scoped to themselves.
#
# That direction matters. A grant scoped to the vault lives and dies with the
# vault, so deleting the vault removes the grant. A grant created here, scoped
# to a resource this module does not own, would outlive its target and leave an
# orphaned assignment pointing at a deleted scope.
#
# Use this input for genuinely cross-cutting grants where the scope is a
# subscription or resource group rather than a single resource.
################################################################################

variable "role_assignments" {
  description = "Map of assignment key to { identity_key, scope, role_definition_name or role_definition_id, description, condition }. Prefer having the resource owner grant access to itself; use this for subscription or resource-group scoped roles."
  type = map(object({
    identity_key         = string
    scope                = string
    role_definition_name = optional(string)
    role_definition_id   = optional(string)
    description          = optional(string)
    condition            = optional(string)
    condition_version    = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for assignment in values(var.role_assignments) :
      (assignment.role_definition_name != null) != (assignment.role_definition_id != null)
    ])
    error_message = "Each role assignment must set exactly one of role_definition_name or role_definition_id."
  }

  validation {
    condition = alltrue([
      for assignment in values(var.role_assignments) :
      assignment.condition == null || assignment.condition_version != null
    ])
    error_message = "condition_version must be set when condition is used; Azure rejects a condition without one."
  }
}

################################################################################
# Entra ID propagation
################################################################################

variable "propagation_delay_seconds" {
  description = <<-EOT
    Seconds to wait after creating identities before dependent resources use
    them.

    A newly created user-assigned identity's service principal takes time to
    become visible across Entra ID, and there is no API to poll for readiness.
    Until it propagates, operations referencing the principal fail with
    PrincipalNotFound — intermittently, which makes it look like a flaky apply
    rather than a consistency window.

    Role assignments created by THIS module set principal_type explicitly,
    which avoids the lookup entirely and needs no delay. This wait exists for
    downstream consumers that touch a data plane — Key Vault in particular,
    where the RBAC grant must be effective before a secret can be read.

    Set to 0 to disable. 30 is usually enough; a first-ever identity in a
    tenant can take longer.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.propagation_delay_seconds >= 0 && var.propagation_delay_seconds <= 600
    error_message = "propagation_delay_seconds must be between 0 and 600."
  }
}
