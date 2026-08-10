################################################################################
# Validation
#
# No Azure resources. The single terraform_data resource hosts preconditions
# for constraints that depend on the merged tag map, which variable validation
# blocks cannot see.
#
# All checks are collected into one list and reported together, so a caller
# with three tag problems learns about all three in one plan rather than
# fixing them one failed plan at a time.
################################################################################

resource "terraform_data" "validation" {
  input = {
    workload    = var.workload
    environment = var.environment
    tag_keys    = sort(keys(local.tags))
  }

  lifecycle {
    precondition {
      condition = length(local.constraint_failures) == 0
      error_message = join("\n", concat(
        ["The composed tag map violates one or more constraints:"],
        local.constraint_failures
      ))
    }
  }
}
