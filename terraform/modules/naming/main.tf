################################################################################
# Validation
#
# This module creates no cloud resources. The single `terraform_data` resource
# exists purely to host preconditions.
#
# Why not `validation` blocks in variables.tf? A variable validation block can
# only see that one variable. Every check below depends on *computed* values —
# the region abbreviation table after merging overrides, or a storage account
# name assembled from four separate inputs. Those cannot be expressed as input
# validation.
#
# Why not `check` blocks? A `check` block emits a warning and lets the apply
# proceed. An invalid resource name is guaranteed to fail at apply, so failing
# the plan is correct. Preconditions block; checks do not.
#
# `terraform_data` is a built-in resource requiring no provider, which keeps
# this module credential-free. It adds one trivial entry to state.
################################################################################

resource "terraform_data" "validation" {
  # Re-evaluates whenever any naming input changes.
  input = {
    workload    = var.workload
    environment = var.environment
    location    = local.location_normalized
    instance    = var.instance
  }

  lifecycle {
    precondition {
      condition = local.location_is_known
      error_message = join("", [
        "Unknown Azure region \"${var.location}\" (normalised to \"${local.location_normalized}\"). ",
        "No abbreviation is defined for it, and guessing one risks two regions sharing a prefix and producing colliding resource names. ",
        "Either use a supported region or extend the table via var.location_abbreviations, e.g. { ${local.location_normalized} = \"abc\" }."
      ])
    }

    precondition {
      condition = length(local.constraint_failures) == 0
      error_message = join("\n", concat(
        ["One or more generated resource names violate Azure naming constraints:"],
        local.constraint_failures
      ))
    }
  }
}
