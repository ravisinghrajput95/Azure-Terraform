################################################################################
# Unit tests for the naming module.
#
# Runs with `terraform test` from the module directory. No provider, no
# credentials, no network — the module is pure computation, so these execute in
# CI on a runner with no Azure access.
################################################################################

variables {
  workload    = "cloudcart"
  environment = "prod"
  location    = "East US"
  unique_seed = "00000000-0000-0000-0000-000000000000"
}

################################################################################
# Happy path
################################################################################

run "composes_hyphenated_base" {
  command = plan

  assert {
    condition     = output.base == "cloudcart-prod-eus"
    error_message = "Expected base \"cloudcart-prod-eus\", got \"${output.base}\"."
  }

  assert {
    condition     = output.base_compact == "cloudcartprdeus"
    error_message = "Expected compact base \"cloudcartprdeus\", got \"${output.base_compact}\"."
  }

  assert {
    condition     = output.location_short == "eus"
    error_message = "Expected location abbreviation \"eus\", got \"${output.location_short}\"."
  }

  assert {
    condition     = output.environment_short == "prd"
    error_message = "Expected environment abbreviation \"prd\", got \"${output.environment_short}\"."
  }
}

run "normalises_display_and_internal_region_names" {
  command = plan

  variables {
    location = "eastus"
  }

  # "East US" (the run above) and "eastus" must yield the same abbreviation.
  # A mismatch here would mean the same region produces two different name sets
  # depending on where the operator copied the string from.
  assert {
    condition     = output.location_normalized == "eastus"
    error_message = "Expected normalised region \"eastus\", got \"${output.location_normalized}\"."
  }

  assert {
    condition     = output.base == "cloudcart-prod-eus"
    error_message = "Region spelling must not affect the generated base name."
  }
}

run "builds_one_resource_group_per_lifecycle_scope" {
  command = plan

  assert {
    condition     = length(output.resource_group_names) == 5
    error_message = "Expected 5 resource groups (net, sec, data, app, mon), got ${length(output.resource_group_names)}."
  }

  assert {
    condition     = output.resource_group_names["net"] == "rg-cloudcart-prod-eus-net"
    error_message = "Unexpected networking resource group name: \"${output.resource_group_names["net"]}\"."
  }

  assert {
    condition     = output.resource_group_names["data"] == "rg-cloudcart-prod-eus-data"
    error_message = "Unexpected data resource group name: \"${output.resource_group_names["data"]}\"."
  }
}

run "builds_per_tier_names" {
  command = plan

  assert {
    condition     = output.subnet_names["app"] == "snet-app-prod-eus"
    error_message = "Unexpected app subnet name: \"${output.subnet_names["app"]}\"."
  }

  assert {
    condition     = output.network_security_group_names["biz"] == "nsg-biz-prod-eus"
    error_message = "Unexpected biz NSG name: \"${output.network_security_group_names["biz"]}\"."
  }

  assert {
    condition     = output.scale_set_names["app"] == "vmss-app-prod-eus-001"
    error_message = "Unexpected app scale set name: \"${output.scale_set_names["app"]}\"."
  }

  assert {
    condition     = length(output.subnet_names) == 5
    error_message = "Expected 5 tiers by default (app, biz, db, pep, mgmt)."
  }

  # Scale sets and identities exist only for compute tiers. A name for
  # "vmss-pep-..." would describe a resource that is never created.
  assert {
    condition     = length(output.scale_set_names) == 2
    error_message = "Expected scale set names for compute tiers only (app, biz), got ${length(output.scale_set_names)}."
  }

  assert {
    condition     = !contains(keys(output.scale_set_names), "pep")
    error_message = "The private endpoint tier must not have a scale set name."
  }
}

run "rejects_compute_tier_absent_from_tiers" {
  command = plan

  variables {
    tiers         = ["app", "pep"]
    compute_tiers = ["app", "biz"]
  }

  expect_failures = [
    var.compute_tiers,
  ]
}

################################################################################
# Azure naming constraints
#
# These are the constraints that cause an apply to fail minutes in. Asserting
# them here means a bad workload name fails in CI in under a second.
################################################################################

run "globally_unique_names_satisfy_azure_constraints" {
  command = plan

  assert {
    condition     = can(regex("^[a-z0-9]{3,24}$", output.storage_account_name))
    error_message = "Storage account name \"${output.storage_account_name}\" violates the 3-24 lowercase alphanumeric constraint."
  }

  assert {
    condition     = length(output.key_vault_name) <= 24
    error_message = "Key Vault name \"${output.key_vault_name}\" exceeds 24 characters."
  }

  assert {
    condition     = can(regex("^[a-zA-Z]", output.key_vault_name))
    error_message = "Key Vault name must start with a letter, got \"${output.key_vault_name}\"."
  }

  assert {
    condition     = !can(regex("-$", output.key_vault_name))
    error_message = "Key Vault name must not end with a hyphen, got \"${output.key_vault_name}\"."
  }

  assert {
    condition     = length(output.sql_server_name) <= 63
    error_message = "SQL server name \"${output.sql_server_name}\" exceeds 63 characters."
  }
}

run "longest_permitted_workload_still_fits_storage_limit" {
  command = plan

  # 10 characters is the maximum var.workload allows. If the compact name
  # scheme ever changes, this is the case that breaks first.
  variables {
    workload = "abcdefghij"
  }

  assert {
    condition     = length(output.storage_account_name) <= 24
    error_message = "Storage account name \"${output.storage_account_name}\" exceeds 24 characters at the maximum permitted workload length."
  }

  assert {
    condition     = length(output.key_vault_name) <= 24
    error_message = "Key Vault name \"${output.key_vault_name}\" exceeds 24 characters at the maximum permitted workload length."
  }
}

################################################################################
# Uniqueness
################################################################################

run "suffix_differs_across_environments" {
  command = plan

  variables {
    environment = "dev"
  }

  # The dev suffix must not equal the prod suffix computed in the first run,
  # otherwise two environments in one subscription would collide on the
  # globally-unique names.
  assert {
    condition     = output.unique_suffix != run.composes_hyphenated_base.unique_suffix
    error_message = "Environments dev and prod produced identical global name suffixes."
  }

  assert {
    condition     = output.storage_account_name != run.composes_hyphenated_base.storage_account_name
    error_message = "Environments dev and prod produced identical storage account names."
  }
}

run "suffix_is_deterministic_for_identical_inputs" {
  command = plan

  assert {
    condition     = output.unique_suffix == run.composes_hyphenated_base.unique_suffix
    error_message = "Identical inputs produced a different suffix — names are not stable across applies."
  }
}

################################################################################
# Rejected inputs
#
# Each of these must fail the plan. A silent fallback would produce colliding
# or invalid names that only surface at apply time.
################################################################################

run "rejects_unknown_region" {
  command = plan

  variables {
    location = "Mars Central"
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_uppercase_workload" {
  command = plan

  variables {
    workload = "CloudCart"
  }

  expect_failures = [
    var.workload,
  ]
}

run "rejects_workload_exceeding_ten_characters" {
  command = plan

  variables {
    workload = "verylongworkloadname"
  }

  expect_failures = [
    var.workload,
  ]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [
    var.environment,
  ]
}

run "rejects_malformed_instance" {
  command = plan

  variables {
    instance = "1"
  }

  expect_failures = [
    var.instance,
  ]
}

run "rejects_duplicate_tiers" {
  command = plan

  variables {
    tiers = ["app", "app", "biz"]
  }

  expect_failures = [
    var.tiers,
  ]
}

################################################################################
# The generated-name constraint check has no test that fires it
#
# main.tf asserts length(local.constraint_failures) == 0 — every generated name
# must satisfy its own Azure constraint. Mutation testing showed no run depends
# on it: weakening it changes nothing.
#
# That is because the variable validations upstream already make it
# unsatisfiable, as far as any input could be constructed here. workload is
# capped at 10 lowercase alphanumeric characters, environment comes from a
# fixed set, instance is three digits, and location abbreviations are validated
# to [a-z0-9]{2,6}. The longest key vault name those can produce is 24
# characters, exactly its limit, and it ends in a hex digit rather than a
# hyphen; the storage account name is substr'd to 24 from alphanumeric parts.
#
# So it is defence in depth against a future abbreviation or naming change
# rather than a live guard, and the runs above assert its PREMISE — that the
# generated names satisfy the constraints — rather than its failure. Stated
# here so the gap reads as understood rather than overlooked.
################################################################################
