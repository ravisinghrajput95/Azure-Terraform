################################################################################
# Tests for the Phase 0 state backend.
#
# This is the configuration everything else depends on and the last one to get
# tests, which is the wrong way round: it is also the only configuration in the
# repository running on LOCAL state, so a mistake here is not recoverable by
# reading state back from the account — the account IS the state.
#
# Unlike an environment root, this one declares its resources directly, so
# `expect_failures` can name them and the storage account's precondition is
# testable in place. Unlike every module, it has no caller to validate its
# inputs first, so the variable validations are the only thing between a typo
# and an Azure error that does not name the rule it broke.
#
# Uses mock_provider: NO credentials, no Azure calls, nothing created. It never
# touches the real terraform.tfstate in this directory — `terraform test` keeps
# its own ephemeral state.
################################################################################

mock_provider "azurerm" {}

################################################################################
# Every variable is pinned, and the two that matter are deliberately fake.
#
# terraform.tfvars is gitignored here for a stronger reason than elsewhere: it
# holds the live storage account name, which is a public DNS label resolving to
# the endpoint that stores every environment's state. `terraform test` reads
# that file like any other command, so leaving these unset would both make the
# run machine-dependent AND risk asserting the real name into a committed file.
################################################################################

variables {
  subscription_id      = "00000000-0000-0000-0000-000000000000"
  resource_group_name  = "rg-tfstate-test"
  storage_account_name = "sttfstatetest001"
  location             = "eastus"

  environments                    = ["dev", "qa", "stage", "prod"]
  shared_access_key_enabled       = false
  blob_soft_delete_retention_days = 30

  tags = {
    workload  = "cloudcart"
    purpose   = "terraform-state"
    managedBy = "Terraform"
  }
}

################################################################################
# One container per environment
#
# for_each over a statically-known set, so the container set is known at plan
# time. Adding an environment here is the only prerequisite before that
# environment can run `terraform init`, which makes a missing container a
# blocked deployment rather than a degraded one.
################################################################################

run "creates_one_container_per_environment" {
  command = plan

  assert {
    condition     = length(output.container_names) == 4
    error_message = "Each of dev, qa, stage and prod needs its own state container."
  }

  assert {
    condition     = output.container_names["dev"] == "tfstate-dev"
    error_message = "Container names must be tfstate-<environment>. The name is written into each environment's backend.conf, so a change here silently points an environment at a container that does not exist."
  }
}

run "adding_an_environment_adds_its_container" {
  command = plan

  variables {
    environments = ["dev", "sandbox"]
  }

  assert {
    condition     = length(output.container_names) == 2
    error_message = "The container set must follow the environments variable exactly."
  }

  assert {
    condition     = output.container_names["sandbox"] == "tfstate-sandbox"
    error_message = "A new environment must get a container named for it."
  }
}

################################################################################
# backend_config — the output that is copied by hand
#
# backend.conf is gitignored, so this output is how it gets written. It is
# string assembly with no schema behind it: a wrong key name here produces a
# backend.conf Terraform rejects at init, and a wrong VALUE produces one it
# accepts while pointing at the wrong state.
################################################################################

run "backend_config_is_usable_as_written" {
  command = plan

  assert {
    condition     = strcontains(output.backend_config["dev"], "container_name       = \"tfstate-dev\"")
    error_message = "Each environment's backend config must name its own container."
  }

  assert {
    condition     = strcontains(output.backend_config["prod"], "key                  = \"cloudcart.prod.tfstate\"")
    error_message = "Each environment's state key must carry its own environment name. Two environments sharing a key share a state file, and the second apply adopts the first's resources."
  }

  # Without this the backend authenticates with an account key — which does not
  # exist, because shared_access_key_enabled is false. The failure appears at
  # init as an authentication error rather than as a configuration one.
  assert {
    condition     = strcontains(output.backend_config["dev"], "use_azuread_auth     = true")
    error_message = "Every backend config must authenticate with Entra ID. The account has shared keys disabled, so a config without this cannot reach state at all."
  }
}

################################################################################
# Protections on the state itself
#
# Versioning covers overwrite; soft delete covers deletion. They are different
# failures and only one of them ends a platform.
################################################################################

run "state_protections_are_reported_accurately" {
  command = plan

  assert {
    condition     = !output.shared_key_access_is_open
    error_message = "Shared key access must be off. A shared key is static, non-expiring, unscopable and grants total control of every state file in the account."
  }

  # This pins the reported window at the value this run supplies — and 30 is
  # also what the variables block above supplies, so it cannot tell a derived
  # number from a hardcoded one. Replacing the interpolation in outputs.tf with
  # a literal 30 leaves this assertion green; the mutation campaign found that.
  # What actually holds the derivation is
  # `a_soft_delete_window_of_exactly_a_week_is_allowed` below, which supplies a
  # different number and asserts the summary followed it.
  assert {
    condition     = strcontains(output.state_protection_summary, "Blob soft delete retains deletions for 30 days.")
    error_message = "The summary must report the configured soft-delete window."
  }

  assert {
    condition     = strcontains(output.state_protection_summary, "Shared key access disabled; Entra ID only.")
    error_message = "The summary must report that shared key access is closed."
  }
}

# The summary exists to state the posture rather than imply it, so the warning
# branches are worth exercising: they are what someone reads when the account
# is NOT configured the way the defaults configure it.
run "a_weakened_posture_is_reported_as_a_warning" {
  command = plan

  variables {
    shared_access_key_enabled       = true
    blob_soft_delete_retention_days = 0
  }

  assert {
    condition     = output.shared_key_access_is_open
    error_message = "Enabling shared keys must be reported, not hidden."
  }

  assert {
    condition     = strcontains(output.state_protection_summary, "WARNING: blob soft delete is DISABLED")
    error_message = "Disabling soft delete must produce a warning. Versioning does not cover deletion, so a deleted state file would be unrecoverable."
  }

  assert {
    condition     = strcontains(output.state_protection_summary, "WARNING: shared key access is ENABLED")
    error_message = "Enabling shared keys must produce a warning: it reopens a path that bypasses RBAC entirely."
  }
}

################################################################################
# Failure modes
#
# These are reachable here in a way they are not from an environment root,
# because this configuration owns its resources rather than composing modules.
################################################################################

# A window shorter than a week rarely outlives the weekend on which the
# deletion happened. 0 disables the protection deliberately; 1 to 6 is someone
# thinking they have it.
run "a_soft_delete_window_too_short_to_help_is_refused" {
  command = plan

  variables {
    blob_soft_delete_retention_days = 3
  }

  expect_failures = [
    azurerm_storage_account.tfstate,
  ]
}

run "a_soft_delete_window_of_exactly_a_week_is_allowed" {
  command = plan

  variables {
    blob_soft_delete_retention_days = 7
  }

  assert {
    condition     = strcontains(output.state_protection_summary, "retains deletions for 7 days")
    error_message = "Seven days is the documented minimum and must be accepted."
  }
}

# Azure rejects a malformed storage account name with an error that does not
# name the rule it broke, which is the reason this validation exists.
run "a_malformed_storage_account_name_is_refused" {
  command = plan

  variables {
    storage_account_name = "st-tfstate-test"
  }

  expect_failures = [
    var.storage_account_name,
  ]
}

run "an_oversized_storage_account_name_is_refused" {
  command = plan

  variables {
    storage_account_name = "sttfstatetestaccountnametoolong"
  }

  expect_failures = [
    var.storage_account_name,
  ]
}

run "a_malformed_resource_group_name_is_refused" {
  command = plan

  variables {
    resource_group_name = "rg/tfstate"
  }

  expect_failures = [
    var.resource_group_name,
  ]
}
