################################################################################
# Unit tests for the log-analytics module.
#
# Uses mock_provider, so these run with NO Azure credentials and create
# nothing.
#
# The workspace is where every other module reports, which is what makes its
# failures so quiet: nothing breaks, data simply stops arriving. Agents keep
# running and keep reporting healthy, and the first symptom is an alert that
# does not fire during the incident it exists for.
################################################################################

mock_provider "azurerm" {}

variables {
  name                = "log-cloudcart-test-cus-001"
  resource_group_name = "rg-cloudcart-test-cus-mon"
  location            = "centralus"
  tags                = { environment = "test" }
}

################################################################################
# Valid configuration
################################################################################

run "accepts_a_coherent_workspace" {
  command = plan

  assert {
    condition     = output.name == "log-cloudcart-test-cus-001"
    error_message = "The workspace name must be passed through unchanged."
  }
}

################################################################################
# Severing the ingestion path
#
# Disabling internet ingestion or query without an Azure Monitor Private Link
# Scope does not fail. It silently cuts the path: agents run, report healthy,
# and no data arrives.
################################################################################

run "rejects_disabled_ingestion_with_no_private_link_scope" {
  command = plan

  variables {
    internet_ingestion_enabled    = false
    private_link_scope_configured = false
  }

  expect_failures = [azurerm_log_analytics_workspace.this]
}

run "rejects_disabled_query_with_no_private_link_scope" {
  command = plan

  variables {
    internet_query_enabled        = false
    private_link_scope_configured = false
  }

  expect_failures = [azurerm_log_analytics_workspace.this]
}

run "accepts_disabled_ingestion_with_a_private_link_scope" {
  command = plan

  # With a scope configured there IS a path, so the precondition must not fire.
  # Refusing this would make the private configuration unbuildable.
  variables {
    internet_ingestion_enabled    = false
    internet_query_enabled        = false
    private_link_scope_configured = true
  }

  assert {
    condition     = output.name == "log-cloudcart-test-cus-001"
    error_message = "A private-link workspace must be accepted."
  }
}

################################################################################
# The daily cap
#
# A cap is a data-loss control, not a cost control: once hit, everything
# arriving afterwards is DROPPED for the rest of the cap period and cannot be
# recovered. dev ran at 995 MB/day of kube-audit against a 512 MB/day cap and
# was silently losing telemetry every day.
################################################################################

run "reports_an_uncapped_workspace" {
  command = plan

  variables {
    daily_quota_gb = -1
  }

  assert {
    condition     = output.ingestion_is_capped == false
    error_message = "-1 is Azure's sentinel for no cap and must report as uncapped."
  }
}

run "reports_a_capped_workspace" {
  command = plan

  variables {
    daily_quota_gb = 0.5
  }

  assert {
    condition     = output.ingestion_is_capped == true
    error_message = "A workspace with a quota must report as capped."
  }

  assert {
    condition     = output.daily_quota_gb == 0.5
    error_message = "The configured cap must be reported."
  }
}

################################################################################
# Retention billing
#
# 30 days is included; beyond that is billed per GB per month, on data already
# paid for at ingestion. It is the setting most often raised without anyone
# noticing the recurring cost.
################################################################################

run "reports_free_retention_at_the_included_limit" {
  command = plan

  variables {
    retention_in_days = 30
  }

  assert {
    condition     = output.retention_is_billable == false
    error_message = "30 days is included and must not report as billable."
  }
}

run "reports_billable_retention_beyond_the_included_limit" {
  command = plan

  variables {
    retention_in_days = 90
  }

  assert {
    condition     = output.retention_is_billable == true
    error_message = "Retention beyond 30 days is billed and must be reported as such."
  }
}
