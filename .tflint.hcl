################################################################################
# TFLint configuration
#
# TFLint catches what `terraform validate` cannot. validate checks syntax and
# type correctness against the provider schema; it does not know that
# "Standard_D2ds_v7" might not exist, that a variable is declared and never
# used, or that a resource name breaks an Azure length limit.
#
# The azurerm ruleset in particular validates SKU and VM size names against a
# generated list, which turns a class of twenty-minutes-into-an-apply failure
# into a lint error.
################################################################################

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

config {
  call_module_type = "local"
  force            = false
}

################################################################################
# Naming conventions
#
# snake_case is the HashiCorp style guide default. Enforcing it stops a
# repository drifting into three conventions over time.
################################################################################

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

################################################################################
# Documentation
#
# Every variable and output must carry a description. These modules are the
# interface other people build against, and an undocumented input is a question
# someone has to ask.
################################################################################

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

################################################################################
# Hygiene
################################################################################

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

# Provider versions must be pinned. An unpinned provider means a build that
# passed yesterday can fail today for reasons nobody changed.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

################################################################################
# Deliberately disabled
################################################################################

# Expects a fixed main.tf/variables.tf/outputs.tf layout. This repository
# deliberately splits locals.tf, versions.tf and topic files such as nsg-rules.tf,
# which reads better than one enormous main.tf.
rule "terraform_standard_module_structure" {
  enabled = false
}

