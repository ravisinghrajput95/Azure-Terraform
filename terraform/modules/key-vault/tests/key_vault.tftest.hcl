################################################################################
# Unit tests for the key-vault module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# Key Vault is the sharpest example of this repository's premise. Its control
# plane and data plane are separate: a vault with no reachable data plane is
# created successfully, reports Succeeded, and the apply goes green — because
# creating the vault is a control-plane operation. The failure appears the
# first time something tries to READ a secret, which is normally in an
# environment nobody is watching.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "kv-cloudcart-test-cus"
  resource_group_name = "rg-cloudcart-test-cus-sec"
  location            = "centralus"
  tags                = { environment = "test" }
  tenant_id           = "00000000-0000-0000-0000-000000000000"

  public_network_access_enabled = false
  create_private_endpoint       = true
  private_endpoint_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pep"
  private_endpoint_name         = "pep-kv-cloudcart-test-cus"
  private_dns_zone_ids          = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"]

  role_assignments = {
    app = {
      principal_id         = "00000000-0000-0000-0000-000000000001"
      role_definition_name = "Key Vault Secrets User"
    }
  }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_vault" {
  command = plan

  assert {
    condition     = strcontains(output.reachable_from, "Private endpoint from inside the VNet.")
    error_message = "A private-endpoint vault must say so in its posture output."
  }

  assert {
    condition     = output.public_access_is_firewalled == false
    error_message = "With no public endpoint at all, there is no public firewall to report."
  }

  assert {
    condition     = length(output.granted_principal_ids) == 1
    error_message = "The single role assignment's principal must be reported."
  }
}

################################################################################
# Reachability
#
# The apply SUCCEEDS for this configuration. That is the whole point of the
# precondition: the control plane creates the vault, Terraform is satisfied,
# and no client can ever read a secret from it.
################################################################################

run "rejects_a_vault_nothing_can_reach" {
  command = plan

  variables {
    public_network_access_enabled = false
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  expect_failures = [azurerm_key_vault.this]
}

run "accepts_a_public_vault_behind_an_allowlist" {
  command = plan

  variables {
    public_network_access_enabled = true
    network_acls_default_action   = "Deny"
    allowed_ip_rules              = ["203.0.113.4"]
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  assert {
    condition     = output.public_access_is_firewalled == true
    error_message = "A public endpoint that denies by default is firewalled and must report as such."
  }

  assert {
    condition     = strcontains(output.reachable_from, "restricted to 1 IP rule(s)")
    error_message = "The posture output must count the rules actually configured."
  }
}

################################################################################
# Network ACLs that read as an allowlist and are not one
#
# default_action = "Allow" with IP rules configured is the trap. It looks like
# an allowlist in the portal and in the diff. It permits every source that is
# not explicitly denied, so the rules do nothing at all.
################################################################################

run "rejects_permissive_acls_that_look_like_an_allowlist" {
  command = plan

  variables {
    public_network_access_enabled = true
    network_acls_default_action   = "Allow"
    allowed_ip_rules              = ["203.0.113.4"]
    create_private_endpoint       = false
    private_endpoint_subnet_id    = null
    private_dns_zone_ids          = []
  }

  expect_failures = [azurerm_key_vault.this]
}

run "reports_a_public_endpoint_with_no_rules_at_all" {
  command = plan

  # Legitimate when a private endpoint carries every request, and usually a
  # forgotten allowlist. Reported rather than refused, because both readings
  # are real and Terraform cannot tell them apart.
  variables {
    public_network_access_enabled = true
    network_acls_default_action   = "Deny"
    allowed_ip_rules              = []
    allowed_subnet_ids            = []
  }

  assert {
    condition     = output.public_endpoint_locked_shut == true
    error_message = "A public endpoint that denies by default with no rules reaches nothing, and must be reported."
  }
}

################################################################################
# Private endpoint and DNS
################################################################################

run "rejects_a_private_endpoint_with_no_subnet" {
  command = plan

  variables {
    create_private_endpoint    = true
    private_endpoint_subnet_id = null
  }

  expect_failures = [azurerm_key_vault.this]
}

run "rejects_a_private_endpoint_with_no_dns_zone" {
  command = plan

  # The endpoint gets a private IP that nothing resolves to. Clients keep
  # resolving the public vault name and are refused there, which looks like a
  # firewall problem rather than a missing zone.
  variables {
    create_private_endpoint = true
    private_dns_zone_ids    = []
  }

  expect_failures = [azurerm_key_vault.this]
}

################################################################################
# Deletion protection
#
# Purge protection cannot be turned off once on, and vault names are
# deterministic here — so a teardown with it enabled strands the name for the
# full retention period and the environment cannot be rebuilt under it.
################################################################################

run "reports_deletion_protection_as_configured" {
  command = plan

  variables {
    purge_protection_enabled   = true
    soft_delete_retention_days = 90
  }

  assert {
    condition     = output.purge_protection_enabled == true
    error_message = "Purge protection must be reported as configured."
  }

  assert {
    condition     = output.soft_delete_retention_days == 90
    error_message = "The retention window must be reported as configured."
  }
}
