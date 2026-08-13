################################################################################
# Unit tests for the recovery-services module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# These matter more than usual because dev deploys the vault and its policies
# and protects NOTHING — there is nothing in the environment left to back up
# once compute moved to AKS. The policy logic is therefore never exercised by
# an apply, and these tests are the only thing that exercises it at all.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "rsv-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-mon"
  location            = "centralus"
  tags                = { environment = "test" }

  vm_backup_policies = {
    daily-7 = {
      frequency       = "Daily"
      time            = "23:00"
      retention_daily = 7
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_daily_policy" {
  command = plan

  assert {
    condition     = strcontains(output.backup_posture_summary, "0 items protected")
    error_message = "The vault must state plainly that nothing is bound to its policies."
  }

  assert {
    condition     = output.protected_item_count == 0
    error_message = "This module never creates protected items."
  }
}

run "reports_absence_of_a_geo_replicated_copy" {
  command = plan

  # The default is LocallyRedundant, deliberately — GeoRedundant is the Azure
  # default and costs materially more.
  assert {
    condition     = strcontains(output.backup_posture_summary, "cross-region restore is unavailable")
    error_message = "Local redundancy must state that no geo-replicated copy exists."
  }
}

run "warns_when_the_vault_holds_no_policies" {
  command = plan

  variables {
    vm_backup_policies = {}
  }

  assert {
    condition     = strcontains(output.backup_posture_summary, "no policies at all")
    error_message = "A vault with no policies must say so."
  }
}

################################################################################
# Retention alignment
#
# The only completely silent failure here. Azure accepts the policy, reports it
# as valid, and shows a retention duration in the portal that never
# materialises.
################################################################################

run "rejects_weekly_retention_on_a_day_the_backup_never_runs" {
  command = plan

  # Backup runs Sunday; weekly retention asks to keep Wednesday's recovery
  # point, which will never exist. That tier retains NOTHING.
  variables {
    vm_backup_policies = {
      weekly-misaligned = {
        frequency = "Weekly"
        time      = "23:00"
        weekdays  = ["Sunday"]

        retention_weekly = {
          count    = 4
          weekdays = ["Wednesday"]
        }
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

run "accepts_weekly_retention_aligned_with_the_schedule" {
  command = plan

  variables {
    vm_backup_policies = {
      weekly-aligned = {
        frequency = "Weekly"
        time      = "23:00"
        weekdays  = ["Sunday"]

        retention_weekly = {
          count    = 4
          weekdays = ["Sunday"]
        }
      }
    }
  }

  assert {
    condition     = strcontains(output.backup_posture_summary, "1 backup polic")
    error_message = "An aligned weekly policy should be accepted."
  }
}

run "rejects_monthly_retention_on_a_day_the_backup_never_runs" {
  command = plan

  variables {
    vm_backup_policies = {
      monthly-misaligned = {
        frequency = "Weekly"
        time      = "23:00"
        weekdays  = ["Sunday"]

        retention_monthly = {
          count    = 12
          weekdays = ["Monday"]
          weeks    = ["First"]
        }
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

run "rejects_a_weekly_schedule_with_no_weekdays" {
  command = plan

  # Never runs at all.
  variables {
    vm_backup_policies = {
      never-runs = {
        frequency = "Weekly"
        time      = "23:00"
        weekdays  = []
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

################################################################################
# Schedule and retention shape
#
# Azure rejects each of these, but names the API field rather than the
# Terraform argument.
################################################################################

run "rejects_a_daily_schedule_with_no_daily_retention" {
  command = plan

  variables {
    vm_backup_policies = {
      no-retention = {
        frequency = "Daily"
        time      = "23:00"
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

run "rejects_daily_retention_below_the_azure_minimum" {
  command = plan

  variables {
    vm_backup_policies = {
      too-short = {
        frequency       = "Daily"
        time            = "23:00"
        retention_daily = 3
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

run "rejects_daily_retention_on_a_weekly_schedule" {
  command = plan

  variables {
    vm_backup_policies = {
      contradictory = {
        frequency       = "Weekly"
        time            = "23:00"
        weekdays        = ["Sunday"]
        retention_daily = 7
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

run "rejects_instant_restore_outside_the_permitted_range" {
  command = plan

  variables {
    vm_backup_policies = {
      too-long = {
        frequency                      = "Daily"
        time                           = "23:00"
        retention_daily                = 7
        instant_restore_retention_days = 9
      }
    }
  }

  expect_failures = [azurerm_backup_policy_vm.this]
}

################################################################################
# Vault coherence
################################################################################

run "rejects_cross_region_restore_without_geo_redundant_storage" {
  command = plan

  # Cross-region restore reads the geo-replicated copy. Without GeoRedundant
  # storage there is no such copy, and Azure's error names only one setting.
  variables {
    cross_region_restore_enabled = true
    storage_mode_type            = "LocallyRedundant"
  }

  expect_failures = [azurerm_recovery_services_vault.this]
}

run "accepts_cross_region_restore_with_geo_redundant_storage" {
  command = plan

  variables {
    cross_region_restore_enabled = true
    storage_mode_type            = "GeoRedundant"
  }

  assert {
    condition     = !strcontains(output.backup_posture_summary, "cross-region restore is unavailable")
    error_message = "GeoRedundant storage should not report cross-region restore as unavailable."
  }
}

run "rejects_locked_immutability_without_acknowledgement" {
  command = plan

  # Irreversible by anyone, at any level, for the full retention of every
  # recovery point already taken.
  variables {
    immutability = "Locked"
  }

  expect_failures = [azurerm_recovery_services_vault.this]
}

run "accepts_locked_immutability_when_acknowledged" {
  command = plan

  variables {
    immutability                   = "Locked"
    immutability_lock_acknowledged = true
  }

  assert {
    condition     = strcontains(output.backup_posture_summary, "LOCKED and cannot be reversed")
    error_message = "A locked vault must state that the choice is irreversible."
  }
}
