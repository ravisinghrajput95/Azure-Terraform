################################################################################
# Version constraints
#
# This module deliberately declares NO providers. It performs string
# computation only and uses the built-in `terraform_data` resource for
# validation, so it can be initialised and planned without Azure credentials
# and without a network connection to the provider registry.
#
# Keeping the naming contract provider-free means it can be unit-tested in CI
# with `terraform test` on a runner that has no cloud access at all.
################################################################################

terraform {
  required_version = ">= 1.9"
}
