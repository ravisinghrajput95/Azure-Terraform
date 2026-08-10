################################################################################
# Unit tests for the tags module.
#
# No provider, no credentials, no network.
################################################################################

variables {
  workload            = "cloudcart"
  environment         = "prod"
  owner               = "platform-team@example.com"
  cost_center         = "CC-4417"
  criticality         = "high"
  data_classification = "confidential"
}

################################################################################
# Composition
################################################################################

run "emits_all_mandatory_tags" {
  command = plan

  assert {
    condition     = length(output.mandatory_tag_keys) == 7
    error_message = "Expected 7 mandatory tags, got ${length(output.mandatory_tag_keys)}."
  }

  assert {
    condition     = output.tags["environment"] == "prod"
    error_message = "environment tag not propagated."
  }

  assert {
    condition     = output.tags["costCenter"] == "CC-4417"
    error_message = "costCenter tag not propagated."
  }

  assert {
    condition     = output.tags["managedBy"] == "Terraform"
    error_message = "managedBy must be the constant \"Terraform\"."
  }

  assert {
    condition     = output.tags["dataClassification"] == "confidential"
    error_message = "dataClassification tag not propagated."
  }
}

run "merges_additional_tags" {
  command = plan

  variables {
    additional_tags = {
      project      = "checkout-rewrite"
      changeTicket = "CHG-9912"
    }
  }

  assert {
    condition     = output.tags["project"] == "checkout-rewrite"
    error_message = "additional_tags were not merged."
  }

  assert {
    condition     = length(output.tags) == 9
    error_message = "Expected 7 mandatory + 2 additional = 9 tags, got ${length(output.tags)}."
  }

  # Mandatory tags must survive the merge intact.
  assert {
    condition     = output.tags["managedBy"] == "Terraform"
    error_message = "Mandatory tags must survive merging with additional_tags."
  }
}

run "builds_tier_scoped_tag_maps" {
  command = plan

  assert {
    condition     = output.tier_tags["app"]["tier"] == "app"
    error_message = "tier_tags must stamp the tier name."
  }

  assert {
    condition     = output.tier_tags["biz"]["environment"] == "prod"
    error_message = "tier_tags must carry the full base tag set, not just the tier."
  }

  assert {
    condition     = length(output.tier_tags) == 5
    error_message = "Expected tier tag maps for 5 default tiers."
  }
}

run "exposes_values_used_for_downstream_branching" {
  command = plan

  assert {
    condition     = output.criticality == "high"
    error_message = "criticality must be exposed for backup and alert sizing."
  }

  assert {
    condition     = output.owner == "platform-team@example.com"
    error_message = "owner must be exposed for action group wiring."
  }
}

################################################################################
# Azure tag constraints
################################################################################

run "stays_within_azure_tag_limits" {
  command = plan

  assert {
    condition     = length(output.tags) <= 50
    error_message = "Tag count exceeds the Azure limit of 50 per resource."
  }

  assert {
    condition     = alltrue([for k in keys(output.tags) : length(k) <= 128])
    error_message = "A tag key exceeds 128 characters, the storage account limit."
  }

  assert {
    condition     = alltrue([for v in values(output.tags) : length(v) <= 256])
    error_message = "A tag value exceeds the Azure limit of 256 characters."
  }
}

################################################################################
# Rejected inputs
################################################################################

run "rejects_override_of_mandatory_tag" {
  command = plan

  variables {
    additional_tags = {
      managedBy = "ClickOps"
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_case_only_collision_with_mandatory_tag" {
  command = plan

  # Azure tag keys are case-insensitive. "Environment" is not a second tag
  # alongside "environment" — it is a conflict the API rejects.
  variables {
    additional_tags = {
      Environment = "production"
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_invalid_character_in_tag_key" {
  command = plan

  variables {
    additional_tags = {
      "cost/center" = "CC-4417"
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_empty_tag_value" {
  command = plan

  variables {
    additional_tags = {
      project = "   "
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_oversized_tag_value" {
  command = plan

  variables {
    additional_tags = {
      notes = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_malformed_owner_email" {
  command = plan

  variables {
    owner = "platform-team"
  }

  expect_failures = [
    var.owner,
  ]
}

run "rejects_unknown_criticality" {
  command = plan

  variables {
    criticality = "very-important"
  }

  expect_failures = [
    var.criticality,
  ]
}

run "rejects_unknown_data_classification" {
  command = plan

  variables {
    data_classification = "secret"
  }

  expect_failures = [
    var.data_classification,
  ]
}

run "rejects_empty_cost_center" {
  command = plan

  variables {
    cost_center = "  "
  }

  expect_failures = [
    var.cost_center,
  ]
}
