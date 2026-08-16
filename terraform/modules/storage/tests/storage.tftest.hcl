################################################################################
# Unit tests for the storage module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# With shared access keys disabled, EVERY data-plane operation authenticates as
# an Entra principal — including Terraform creating a container. Control-plane
# roles do not help: a subscription Owner holding no data role gets 403 on the
# first container create. That is the failure the data-plane grant precondition
# exists to catch, and it is invisible until the apply reaches the container.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "stcloudcarttestcus"
  resource_group_name = "rg-cloudcart-test-cus-data"
  location            = "centralus"
  tags                = { environment = "test" }

  public_network_access_enabled = false
  create_private_endpoints      = true
  private_endpoint_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pep"
  private_endpoint_name_prefix  = "pep-st-cloudcart-test-cus"
  private_endpoint_subresources = ["blob"]
  private_dns_zone_ids_by_subresource = {
    blob = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"]
  }

  shared_access_key_enabled = false
  containers                = { data = {} }
  role_assignments = {
    app = {
      principal_id         = "00000000-0000-0000-0000-000000000001"
      role_definition_name = "Storage Blob Data Contributor"
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_account" {
  command = plan

  assert {
    condition     = output.shared_access_key_enabled == false
    error_message = "Shared access keys must stay disabled in the baseline configuration."
  }

  assert {
    condition     = strcontains(output.reachable_from, "Entra ID authentication only.")
    error_message = "With keys disabled, the posture output must say authentication is Entra-only."
  }

  assert {
    condition     = output.allows_public_blob_access == false
    error_message = "Anonymous blob access must be foreclosed account-wide."
  }
}

################################################################################
# Reachability
################################################################################

run "rejects_an_account_nothing_can_reach" {
  command = plan

  variables {
    public_network_access_enabled       = false
    create_private_endpoints            = false
    private_endpoint_subnet_id          = null
    private_endpoint_subresources       = []
    private_dns_zone_ids_by_subresource = {}
  }

  expect_failures = [azurerm_storage_account.this]
}

run "accepts_a_public_account_behind_an_allowlist" {
  command = plan

  variables {
    public_network_access_enabled       = true
    network_rules_default_action        = "Deny"
    allowed_ip_rules                    = ["203.0.113.4"]
    create_private_endpoints            = false
    private_endpoint_subnet_id          = null
    private_endpoint_subresources       = []
    private_dns_zone_ids_by_subresource = {}
  }

  assert {
    condition     = strcontains(output.reachable_from, "restricted to 1 IP rule(s)")
    error_message = "A firewalled public endpoint must report the rules actually configured."
  }
}

################################################################################
# Network rules that read as an allowlist and are not one
################################################################################

run "rejects_permissive_rules_that_look_like_an_allowlist" {
  command = plan

  variables {
    public_network_access_enabled       = true
    network_rules_default_action        = "Allow"
    allowed_ip_rules                    = ["203.0.113.4"]
    create_private_endpoints            = false
    private_endpoint_subnet_id          = null
    private_endpoint_subresources       = []
    private_dns_zone_ids_by_subresource = {}
  }

  expect_failures = [azurerm_storage_account.this]
}

################################################################################
# Private endpoints need a zone PER SUB-RESOURCE
#
# A blob endpoint does not make file, queue or table resolve. Each sub-resource
# has its own privatelink zone, and a missing one leaves that sub-resource
# resolving to the public name.
################################################################################

run "rejects_a_subresource_with_no_dns_zone" {
  command = plan

  variables {
    private_endpoint_subresources = ["blob", "file"]
    private_dns_zone_ids_by_subresource = {
      blob = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"]
      # file deliberately absent
    }
  }

  expect_failures = [azurerm_storage_account.this]
}

run "accepts_multiple_subresources_each_with_its_own_zone" {
  command = plan

  variables {
    private_endpoint_subresources = ["blob", "file"]
    private_dns_zone_ids_by_subresource = {
      blob = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"]
      file = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"]
    }
  }

  assert {
    condition     = length(output.private_endpoint_subresources) == 2
    error_message = "Both sub-resources must get an endpoint when each has a zone."
  }
}

################################################################################
# The data-plane grant
#
# Creating a container is a DATA-plane operation. With keys disabled and no
# blob data role, Terraform itself is refused — and the role it needs is not
# one that Owner or Contributor implies.
################################################################################

run "rejects_containers_with_no_data_plane_role" {
  command = plan

  variables {
    shared_access_key_enabled = false
    containers                = { data = {} }
    role_assignments = {
      # A control-plane role. Carries dataActions: [], so it grants no access
      # to the blob endpoint at all.
      reader = {
        principal_id         = "00000000-0000-0000-0000-000000000001"
        role_definition_name = "Reader"
      }
    }
  }

  expect_failures = [azurerm_storage_account.this]
}

run "accepts_containers_when_a_data_plane_role_is_granted" {
  command = plan

  variables {
    shared_access_key_enabled = false
    containers                = { data = {}, logs = {} }
    role_assignments = {
      app = {
        principal_id         = "00000000-0000-0000-0000-000000000001"
        role_definition_name = "Storage Blob Data Owner"
      }
    }
  }

  assert {
    condition     = length(output.container_names) == 2
    error_message = "Both containers must be created when a data-plane role exists."
  }
}

run "accepts_containers_with_keys_enabled_and_no_data_role" {
  command = plan

  # Keys are a data-plane credential in their own right, so Terraform can
  # create the container without an RBAC grant. Worse posture, not incoherent —
  # reported in the output rather than refused.
  variables {
    shared_access_key_enabled = true
    containers                = { data = {} }
    role_assignments          = {}
  }

  assert {
    condition     = strcontains(output.reachable_from, "WARNING: shared access keys are ENABLED.")
    error_message = "Enabling shared access keys must be reported as a warning."
  }
}
