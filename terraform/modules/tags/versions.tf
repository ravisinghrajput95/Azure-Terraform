################################################################################
# Version constraints
#
# Like the naming module, this declares no providers. It composes and validates
# a tag map, so it plans and tests without Azure credentials.
################################################################################

terraform {
  required_version = ">= 1.9"
}
