################################################################################
# Validation
#
# No Azure resources. Preconditions enforce two separate classes of rule:
#
#   1. Coherence — the selected profile, after overrides, describes a
#      deployable environment. Two ingress paths or no egress path are caught
#      here rather than discovered in production.
#
#   2. Production guardrails — an override cannot silently strip backup,
#      alerting, purge protection or locks from production.
#
# Both are reported as aggregated lists so a caller sees every problem in one
# plan.
################################################################################

resource "terraform_data" "validation" {
  input = {
    environment    = var.environment
    vm_size        = local.profile.vm_size
    peak_vcpus     = local.peak_vcpus
    ingress        = local.profile.enable_application_gateway ? "application_gateway" : "public_load_balancer"
    egress         = local.profile.enable_firewall ? "firewall" : "nat_gateway"
    indicative_usd = local.indicative_monthly_cost_usd
  }

  lifecycle {
    precondition {
      condition = length(local.constraint_failures) == 0
      error_message = join("\n", concat(
        ["Environment profile \"${var.environment}\" is not internally coherent:"],
        local.constraint_failures
      ))
    }

    precondition {
      condition = length(local.production_guardrail_failures) == 0
      error_message = join("\n", concat(
        ["Production guardrails failed. Set enforce_production_guardrails = false only with a documented reason."],
        local.production_guardrail_failures
      ))
    }
  }
}
