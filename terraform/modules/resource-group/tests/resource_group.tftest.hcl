################################################################################
# Unit tests for the resource-group module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# Resource groups are the unit of lifecycle, RBAC scope and deletion blast
# radius (ARCHITECTURE.md §1.2), so the interesting failure here is a LOCK that
# does not exist. A lock named for a scope that was never created produces no
# error and no lock — the group it was meant to protect is simply unprotected,
# and nothing says so.
################################################################################

mock_provider "azurerm" {}

variables {
  resource_group_names = {
    net  = "rg-cloudcart-test-cus-net"
    sec  = "rg-cloudcart-test-cus-sec"
    data = "rg-cloudcart-test-cus-data"
    app  = "rg-cloudcart-test-cus-app"
  }
  location = "centralus"
  tags     = { environment = "test" }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_coherent_resource_groups" {
  command = plan

  assert {
    condition     = length(output.names) == 4
    error_message = "Every requested group must be created."
  }

  assert {
    condition     = output.names["net"] == "rg-cloudcart-test-cus-net"
    error_message = "Groups must be addressable by lifecycle scope, not by index."
  }
}

################################################################################
# Locks naming a scope that does not exist
################################################################################

run "rejects_a_lock_on_a_scope_that_was_never_created" {
  command = plan

  variables {
    enable_resource_locks = true
    lock_scopes           = ["net", "mon"] # mon is not in resource_group_names
  }

  expect_failures = [azurerm_resource_group.this]
}

run "rejects_an_unknown_lock_scope_even_when_locks_are_disabled" {
  command = plan

  # The scope list is wrong whether or not locks are switched on today, and
  # catching it only when enabled would let the typo sit until the environment
  # that enables locks is built — which is prod.
  variables {
    enable_resource_locks = false
    lock_scopes           = ["net", "typo"]
  }

  expect_failures = [azurerm_resource_group.this]
}

################################################################################
# Which scopes actually get locked
################################################################################

run "locks_only_the_named_scopes" {
  command = plan

  variables {
    enable_resource_locks = true
    lock_scopes           = ["net", "sec", "data"]
  }

  assert {
    condition     = length(output.locked_scopes) == 3
    error_message = "Exactly the named scopes must be locked."
  }

  assert {
    condition     = !contains(output.locked_scopes, "app")
    error_message = "app must NOT be locked by default: a CanNotDelete lock cascades to every resource inside the group and would block the routine replacements application deploys depend on."
  }
}

run "creates_no_locks_when_locks_are_disabled" {
  command = plan

  variables {
    enable_resource_locks = false
    lock_scopes           = ["net", "sec", "data"]
  }

  assert {
    condition     = length(output.locked_scopes) == 0
    error_message = "With locks disabled, nothing is locked regardless of the scope list."
  }

  assert {
    condition     = length(output.lock_ids) == 0
    error_message = "No lock resources may be created when locks are disabled."
  }
}
