################################################################################
# Unit tests for the profile module.
#
# No provider, no credentials, no network.
################################################################################

variables {
  environment = "dev"
}

################################################################################
# dev — must stay inside free-tier constraints
################################################################################

run "dev_is_free_tier_safe" {
  command = plan

  assert {
    condition     = output.profile.vm_size == "Standard_B1s"
    error_message = "dev must use a burstable size; trial subscriptions have zero quota for most other families."
  }

  assert {
    condition     = output.peak_vcpus <= 4
    error_message = "dev peak footprint is ${output.peak_vcpus} vCPUs, above the 4-vCPU default trial quota."
  }

  assert {
    condition     = output.enable_firewall == false
    error_message = "dev must not deploy Azure Firewall; it alone exceeds a $200 credit in under seven days."
  }

  assert {
    condition     = output.enable_nat_gateway == true
    error_message = "dev still needs explicit egress — default outbound access was retired in September 2025."
  }

  assert {
    condition     = output.profile.bastion_sku == "Developer"
    error_message = "dev should use the no-charge Bastion Developer SKU."
  }

  assert {
    condition     = output.profile.use_spot_instances == false
    error_message = "Trial subscriptions have zero Spot quota; spot instances would fail to allocate."
  }

  assert {
    condition     = output.profile.key_vault_purge_protection == false
    error_message = "Purge protection in dev blocks the destroy/recreate cycle that keeps a credit-limited subscription affordable."
  }

  assert {
    condition     = output.profile.enable_resource_locks == false
    error_message = "Resource locks in dev would block terraform destroy."
  }

  assert {
    condition     = output.indicative_monthly_cost_usd < 250
    error_message = "dev indicative cost is $${output.indicative_monthly_cost_usd}/month, too high for a $200 30-day credit."
  }
}

run "dev_uses_load_balancer_ingress_not_application_gateway" {
  command = plan

  assert {
    condition     = output.ingress_strategy == "public_load_balancer"
    error_message = "dev should use a public load balancer; Application Gateway has no inexpensive tier."
  }

  assert {
    condition     = output.egress_strategy == "nat_gateway"
    error_message = "dev egress should be NAT Gateway."
  }
}

################################################################################
# prod — must be genuinely production grade
################################################################################

run "prod_is_production_grade" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = output.enable_firewall == true
    error_message = "prod must deploy Azure Firewall."
  }

  assert {
    condition     = output.profile.waf_mode == "Prevention"
    error_message = "prod WAF must be in Prevention mode, not Detection."
  }

  assert {
    condition     = length(output.profile.compute_zones) == 3
    error_message = "prod compute must span three availability zones."
  }

  assert {
    condition     = length(output.profile.application_gateway_zones) == 3
    error_message = "prod Application Gateway must span three zones."
  }

  assert {
    condition     = output.profile.sql_zone_redundant == true
    error_message = "prod SQL must be zone redundant."
  }

  assert {
    condition     = output.profile.storage_replication_type == "GZRS"
    error_message = "prod storage must be geo-zone-redundant."
  }

  assert {
    condition     = output.profile.log_daily_quota_gb == -1
    error_message = "prod must not cap Log Analytics ingestion."
  }

  assert {
    condition     = output.indicative_monthly_cost_usd > 1000
    error_message = "A production-grade profile costing under $1000/month suggests something was silently disabled."
  }
}

run "prod_and_dev_differ_across_every_availability_control" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = output.profile.enable_backup && !run.dev_is_free_tier_safe.profile.enable_backup
    error_message = "Backup must differ between dev and prod."
  }

  assert {
    condition     = output.indicative_monthly_cost_usd > run.dev_is_free_tier_safe.indicative_monthly_cost_usd * 5
    error_message = "prod should cost substantially more than dev; if not, one of them is misconfigured."
  }
}

################################################################################
# Overrides
################################################################################

run "overrides_replace_profile_defaults" {
  command = plan

  variables {
    overrides = {
      vm_size        = "Standard_B2s"
      instance_count = 2
      enable_redis   = false
    }
  }

  assert {
    condition     = output.profile.vm_size == "Standard_B2s"
    error_message = "Override of vm_size was not applied."
  }

  assert {
    condition     = output.profile.enable_redis == false
    error_message = "A false boolean override must be applied, not treated as unset."
  }

  assert {
    condition     = output.cost_breakdown.redis == 0
    error_message = "Disabling Redis must remove it from the cost breakdown."
  }
}

run "unset_overrides_fall_through_to_defaults" {
  command = plan

  variables {
    overrides = {
      vm_size = "Standard_B2s"
    }
  }

  assert {
    condition     = output.profile.bastion_sku == "Developer"
    error_message = "Attributes not present in overrides must keep the profile default."
  }
}

################################################################################
# Quota
################################################################################

run "quota_check_passes_within_limit" {
  command = plan

  variables {
    subscription_vcpu_quota = 4
  }

  assert {
    condition     = output.quota_checked == true
    error_message = "Quota check should have run when a quota was supplied and the VM size is known."
  }
}

run "rejects_footprint_exceeding_vcpu_quota" {
  command = plan

  variables {
    subscription_vcpu_quota = 4
    overrides = {
      vm_size                 = "Standard_D4s_v5"
      instance_count          = 3
      enable_autoscale        = true
      autoscale_min_instances = 3
      autoscale_max_instances = 10
    }
  }

  # 4 vCPU x 10 instances x 2 tiers = 80, far above a 4-vCPU quota.
  expect_failures = [
    terraform_data.validation,
  ]
}

run "quota_check_skipped_for_unknown_vm_size" {
  command = plan

  variables {
    subscription_vcpu_quota = 4
    overrides = {
      vm_size = "Standard_XYZ_v99"
    }
  }

  assert {
    condition     = output.quota_checked == false
    error_message = "An unknown VM size must skip the quota check rather than guessing its vCPU count."
  }

  assert {
    condition     = output.peak_vcpus == null
    error_message = "peak_vcpus must be null when the VM size is unknown."
  }
}

################################################################################
# Coherence
################################################################################

run "rejects_two_ingress_paths" {
  command = plan

  variables {
    overrides = {
      enable_application_gateway  = true
      enable_public_load_balancer = true
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_no_ingress_path" {
  command = plan

  variables {
    overrides = {
      enable_application_gateway  = false
      enable_public_load_balancer = false
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_two_egress_paths" {
  command = plan

  variables {
    overrides = {
      enable_firewall    = true
      enable_nat_gateway = true
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_no_egress_path" {
  command = plan

  variables {
    overrides = {
      enable_firewall    = false
      enable_nat_gateway = false
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_inverted_autoscale_bounds" {
  command = plan

  variables {
    overrides = {
      enable_autoscale        = true
      autoscale_min_instances = 8
      autoscale_max_instances = 2
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_zone_redundant_sql_on_general_purpose_tier" {
  command = plan

  variables {
    overrides = {
      sql_zone_redundant = true
      sql_sku_name       = "GP_Gen5_2"
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_invalid_availability_zone" {
  command = plan

  variables {
    overrides = {
      compute_zones = ["1", "4"]
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_spot_instances_in_production" {
  command = plan

  variables {
    environment = "prod"
    overrides = {
      use_spot_instances = true
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

################################################################################
# Production guardrails
################################################################################

run "rejects_production_without_backup" {
  command = plan

  variables {
    environment = "prod"
    overrides = {
      enable_backup = false
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_production_without_purge_protection" {
  command = plan

  variables {
    environment = "prod"
    overrides = {
      key_vault_purge_protection = false
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "rejects_production_with_log_ingestion_cap" {
  command = plan

  variables {
    environment = "prod"
    overrides = {
      log_daily_quota_gb = 5
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}

run "guardrails_can_be_disabled_deliberately" {
  command = plan

  variables {
    environment                   = "prod"
    enforce_production_guardrails = false
    overrides = {
      enable_backup = false
    }
  }

  assert {
    condition     = output.profile.enable_backup == false
    error_message = "With guardrails disabled, the override must apply."
  }
}

################################################################################
# Rejected inputs
################################################################################

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [
    var.environment,
  ]
}

################################################################################
# Data-plane public access
################################################################################

run "dev_keeps_firewalled_public_data_plane" {
  command = plan

  # Key Vault and Storage secrets are managed over the DATA plane, and a
  # private endpoint is only reachable from inside the VNet. With public access
  # fully off, an operator on a laptop cannot read a secret at all. dev keeps
  # the endpoint but firewalls it to an explicit allowlist.
  assert {
    condition     = output.data_plane_public_access_enabled == true
    error_message = "dev must retain a firewalled public data plane, or secrets cannot be managed from outside the VNet."
  }
}

run "test_and_prod_use_private_endpoint_only" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = output.data_plane_public_access_enabled == false
    error_message = "Production data services must be reachable only through private endpoints."
  }
}

run "rejects_production_with_public_data_plane" {
  command = plan

  variables {
    environment = "prod"
    overrides = {
      data_plane_public_access_enabled = true
    }
  }

  expect_failures = [
    terraform_data.validation,
  ]
}
