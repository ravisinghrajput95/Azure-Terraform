################################################################################
# Unit tests for the managed-identity module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# The identities themselves are trivial. What is not trivial is that a role
# assignment naming an identity that does not exist resolves to an empty
# principal ID, and Azure accepts an assignment for an empty principal — the
# grant is created, shows in the portal, and gives nobody anything.
################################################################################

mock_provider "azurerm" {}

variables {
  resource_group_name = "rg-cloudcart-test-cus-sec"
  location            = "centralus"
  tags                = { environment = "test" }

  identities = {
    app = "id-cloudcart-app-test-cus"
    biz = "id-cloudcart-biz-test-cus"
  }

  role_assignments = {
    app-reads-secrets = {
      identity_key         = "app"
      scope                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv"
      role_definition_name = "Key Vault Secrets User"
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_coherent_identities_and_grants" {
  command = plan

  assert {
    condition     = length(output.names) == 2
    error_message = "Both identities must be created."
  }

  assert {
    condition     = length(output.role_assignment_ids) == 1
    error_message = "The role assignment must be created."
  }
}

################################################################################
# A grant to an identity that does not exist
#
# The per-tier separation this platform claims — app cannot read biz's secrets —
# depends on each grant naming a real identity. A typo'd key does not fail; it
# grants nothing to nobody while looking exactly like a grant.
################################################################################

run "rejects_a_grant_naming_an_unknown_identity" {
  command = plan

  variables {
    role_assignments = {
      typo = {
        identity_key         = "ap" # "app" misspelled
        scope                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv"
        role_definition_name = "Key Vault Secrets User"
      }
    }
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "accepts_grants_to_several_identities" {
  command = plan

  variables {
    role_assignments = {
      app-reads-secrets = {
        identity_key         = "app"
        scope                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv"
        role_definition_name = "Key Vault Secrets User"
      }
      biz-reads-blobs = {
        identity_key         = "biz"
        scope                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data/providers/Microsoft.Storage/storageAccounts/st"
        role_definition_name = "Storage Blob Data Reader"
      }
    }
  }

  assert {
    condition     = length(output.role_assignment_ids) == 2
    error_message = "Each identity must be able to hold its own grants."
  }
}

run "accepts_identities_with_no_grants_at_all" {
  command = plan

  # An identity with no role assignment is legitimate — the grant often lives
  # with the resource being granted on, not here.
  variables {
    role_assignments = {}
  }

  assert {
    condition     = length(output.names) == 2
    error_message = "Identities must be creatable without any role assignments."
  }

  assert {
    condition     = length(output.role_assignment_ids) == 0
    error_message = "No grants means no assignments."
  }
}
