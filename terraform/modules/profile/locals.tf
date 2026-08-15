################################################################################
# Environment profiles
#
# Three coherent bundles. "Coherent" is the point: zone-redundant compute with
# a single-zone database is not a cheaper production environment, it is a
# broken one. Bundling the settings that must move together prevents an
# environment being assembled from individually reasonable but collectively
# incoherent choices.
#
# VALUES MARKED [FREE-TIER] are sized for an Azure free/trial subscription with
# the conservative default quota: 4 total regional vCPUs, burstable families
# only, zero Spot quota. They have NOT been verified against the target
# subscription. Run:
#
#   az vm list-usage --location <region> -o table
#
# and pass the result as var.subscription_vcpu_quota to have the module check
# them for you.
################################################################################

locals {
  profiles = {
    ##########################################################################
    # dev — free-tier safe.
    #
    # The only environment expected to be applied on a trial subscription.
    # Egress via NAT Gateway rather than Azure Firewall (~$33/month against
    # ~$912), ingress via a public Standard load balancer rather than
    # Application Gateway (~$18 against ~$260 minimum), and Bastion Developer,
    # which carries no charge.
    ##########################################################################
    dev = {
      # Egress. NAT Gateway is not optional decoration: default outbound
      # access was retired on 30 September 2025, so a subnet with no explicit
      # egress resource has no internet connectivity at all.
      enable_firewall    = false
      firewall_sku_tier  = "Standard"
      enable_nat_gateway = true

      # Ingress. Application Gateway has no inexpensive tier — Standard_v2
      # still costs roughly $180/month before capacity units.
      enable_application_gateway       = false
      application_gateway_sku          = "Standard_v2"
      waf_mode                         = "Detection"
      application_gateway_zones        = []
      application_gateway_min_capacity = 1
      application_gateway_max_capacity = 2
      enable_public_load_balancer      = true

      # Bastion Developer carries no charge. It is portal-only, does not
      # support the native client, and does not work across peered VNets —
      # all acceptable for dev, none acceptable for prod.
      enable_bastion = true
      bastion_sku    = "Developer"

      # Kubernetes.
      #
      # dev's cluster is deliberately NOT highly available, and the reason is
      # arithmetic rather than preference: HA needs three nodes across three
      # zones, which is 6 vCPU against a 4 vCPU trial quota. Even two nodes
      # fails, because AKS adds a surge node during upgrades (max_surge = 1)
      # and a cluster that cannot be patched is not one worth running.
      #
      # So dev runs a single-node system pool. The is_highly_available output
      # reports false so this never reads as production-shaped.
      aks_sku_tier             = "Free"
      aks_private_cluster      = false
      aks_network_policy       = "azure"
      enable_user_node_pool    = false
      user_node_pool_min_count = 1
      user_node_pool_max_count = 2

      # [FREE-TIER] 1 node x 2 vCPU = 2 vCPU, inside a 4-vCPU quota with
      # headroom for the upgrade surge node.
      #
      # NOT Standard_B2s: that size is not permitted on this subscription in
      # Central US. The API rejects it with "The VM size of Standard_B2s is not
      # allowed in your subscription in location", which is a subscription
      # restriction rather than a quota — the same class of block as SQL
      # provisioning in East US.
      #
      # Standard_D2s_v4 is permitted, x86, and 2 vCPU / 8 GiB, comfortably over
      # the AKS system pool minimum of 2 vCPU / 4 GiB.
      #
      # The cheapest PERMITTED size is Standard_B2pls_v2 at roughly $28/month
      # against this one's ~$70-90 — but it is ARM, so every container image
      # would need an arm64 build. That is a workload constraint, not an
      # infrastructure one, so it is left as a deliberate override rather than
      # a default:
      #
      #   profile_overrides = { vm_size = "Standard_B2pls_v2" }
      vm_size                 = "Standard_D2s_v4"
      instance_count          = 1
      enable_autoscale        = false
      autoscale_min_instances = 1
      autoscale_max_instances = 1
      compute_zones           = []
      # Trial subscriptions are allocated zero Spot vCPUs by default, so spot
      # instances would fail to allocate rather than save money.
      use_spot_instances = false
      os_disk_type       = "StandardSSD_LRS"
      os_disk_size_gb    = 64

      # Serverless SQL with auto-pause bills near zero while idle, which suits
      # an environment used a few hours a day.
      sql_sku_name                   = "GP_S_Gen5_1"
      sql_zone_redundant             = false
      sql_backup_retention_days      = 7
      sql_enable_long_term_retention = false

      # Azure Cache for Redis is RETIRING — its API rejects creation outright.
      # Azure Managed Redis replaces it, and Balanced_B0 at roughly $13/month
      # is slightly cheaper than the classic Basic C0 it supersedes.
      #
      # High availability off in dev: it roughly halves the cost and removes
      # the SLA, which is acceptable where the cache is a pure accelerator and
      # a cold start is survivable. Redis has no free tier and remains the
      # first component worth disabling if credit runs short.
      enable_redis            = true
      redis_sku_name          = "Balanced_B0"
      redis_high_availability = false

      storage_replication_type  = "LRS"
      storage_enable_versioning = false

      # Data-plane public access stays ON in dev, but firewalled to an explicit
      # IP allowlist with default_action = Deny.
      #
      # This is a deliberate trade, not an oversight. Key Vault and Storage
      # secrets are managed over the DATA plane, and a private endpoint is only
      # reachable from inside the VNet. With public access fully disabled, an
      # operator on a laptop — and Terraform running there — cannot read or
      # write a secret at all. In dev that would mean no way to verify the
      # deployment without standing up a jump host for every check.
      #
      # test and prod turn this off: their pipelines run from inside the
      # network, so the private endpoint is the only path they need.
      data_plane_public_access_enabled = true

      # Purge protection is deliberately OFF in dev. Once enabled it CANNOT be
      # disabled, and a deleted vault name is unusable for the retention
      # period — which breaks the destroy/recreate cycle that keeps a trial
      # subscription affordable.
      key_vault_purge_protection           = false
      key_vault_soft_delete_retention_days = 7

      # Resource locks would block `terraform destroy`, the primary cost
      # control on a credit-limited subscription.
      enable_resource_locks  = false
      enable_ddos_protection = false
      enable_defender        = false

      # A daily cap protects the free 5 GB/month Log Analytics allowance.
      # Note that a cap DROPS data once hit, including security signals —
      # tolerable in dev, never in production.
      log_retention_days = 30
      log_daily_quota_gb = 0.5
      enable_vm_insights = true

      # Alerting is ON in dev, unlike backup and locks above, because it is the
      # one protection here that is nearly free: the AKS metrics alerted on are
      # free platform metrics, action groups cost nothing, and the rules
      # themselves are cents per month. It stays on mainly so the alerting
      # configuration is exercised somewhere before prod depends on it — an
      # alert rule that was never going to fire looks identical to one that
      # works.
      enable_alerts = true

      enable_backup         = false
      backup_retention_days = 7
    }

    ##########################################################################
    # qa — functional validation.
    #
    # Adds the WAF in Detection mode so rule tuning happens here rather than
    # against production traffic, and partial zone spread so zone-aware
    # behaviour is exercised. No Azure Firewall: at ~$912/month it is the
    # single largest line item, and qa's job is to answer "does the
    # application work", which egress inspection does not change. Firewall
    # topology is validated in stage instead.
    #
    # NOT deployable on a free subscription.
    ##########################################################################
    qa = {
      enable_firewall    = false
      firewall_sku_tier  = "Standard"
      enable_nat_gateway = true

      # Detection mode logs what Prevention would have blocked. Running
      # Prevention here first would block legitimate test traffic and teach
      # the team to distrust the WAF.
      enable_application_gateway       = true
      application_gateway_sku          = "WAF_v2"
      waf_mode                         = "Detection"
      application_gateway_zones        = []
      application_gateway_min_capacity = 1
      application_gateway_max_capacity = 3
      enable_public_load_balancer      = false

      enable_bastion = true
      bastion_sku    = "Basic"

      aks_sku_tier             = "Standard"
      aks_private_cluster      = true
      aks_network_policy       = "azure"
      enable_user_node_pool    = true
      user_node_pool_min_count = 1
      user_node_pool_max_count = 3

      vm_size                 = "Standard_D2s_v5"
      instance_count          = 2
      enable_autoscale        = true
      autoscale_min_instances = 2
      autoscale_max_instances = 4
      compute_zones           = ["1", "2"]
      use_spot_instances      = false
      os_disk_type            = "StandardSSD_LRS"
      os_disk_size_gb         = 128

      sql_sku_name                   = "GP_Gen5_2"
      sql_zone_redundant             = false
      sql_backup_retention_days      = 7
      sql_enable_long_term_retention = false

      enable_redis            = true
      redis_sku_name          = "Balanced_B1"
      redis_high_availability = true

      storage_replication_type  = "LRS"
      storage_enable_versioning = true

      # Private endpoint only. Pipelines run inside the network.
      data_plane_public_access_enabled = false

      # Also off in test: the naming module produces a deterministic vault
      # name, so purge protection would block recreating test after a
      # teardown for the full retention period.
      key_vault_purge_protection           = false
      key_vault_soft_delete_retention_days = 30

      enable_resource_locks  = false
      enable_ddos_protection = false
      enable_defender        = false

      log_retention_days = 30
      log_daily_quota_gb = -1
      enable_vm_insights = true
      enable_alerts      = true

      enable_backup         = true
      backup_retention_days = 14
    }

    ##########################################################################
    # stage — pre-production soak.
    #
    # The environment that exists to be WRONG about prod cheaply. Its guiding
    # rule: mirror production on anything STRUCTURAL, and deviate only where
    # the deviation is purely a matter of scale. Every deviation below is
    # therefore a capacity choice, never a topology one — because a soak
    # environment shaped differently from production validates the wrong shape.
    #
    # This is why stage, unlike qa, runs the Azure Firewall. Egress through a
    # firewall with UDRs is a different network than egress through a NAT
    # Gateway, and it carries the two failure modes that break this topology in
    # production: a 0.0.0.0/0 UDR on the Application Gateway subnet, and the
    # same on AzureBastionSubnet. Neither is reachable in an environment that
    # has no firewall at all, so without stage they would first be exercised in
    # prod.
    #
    # WHAT REMAINS UNVALIDATED, stated plainly rather than implied:
    #   - Firewall is Standard, not Premium, so IDPS and TLS inspection are
    #     never exercised (~$365/month cheaper).
    #   - SQL is General Purpose zone-redundant, not Business Critical, so
    #     zone redundancy is validated but not BC's failover characteristics.
    #   - Node size is D2s_v5 rather than D4s_v5, so zone spread and autoscale
    #     behaviour are exercised but performance figures are not comparable.
    #
    # NOT deployable on a free subscription. Cost is close to production.
    ##########################################################################
    stage = {
      # The reason stage exists. Standard rather than Premium: the topology,
      # the UDRs and the egress rules are what need validating, and those are
      # identical across the two tiers.
      enable_firewall    = true
      firewall_sku_tier  = "Standard"
      enable_nat_gateway = false

      # Prevention, matching prod. qa runs Detection to tune the rules; stage
      # runs the tuned rules in the mode prod will use, because a rule set that
      # has only ever been observed in Detection has never actually blocked
      # anything.
      enable_application_gateway       = true
      application_gateway_sku          = "WAF_v2"
      waf_mode                         = "Prevention"
      application_gateway_zones        = ["1", "2", "3"]
      application_gateway_min_capacity = 2
      application_gateway_max_capacity = 6
      enable_public_load_balancer      = false

      enable_bastion = true
      bastion_sku    = "Standard"

      aks_sku_tier             = "Standard"
      aks_private_cluster      = true
      aks_network_policy       = "azure"
      enable_user_node_pool    = true
      user_node_pool_min_count = 2
      user_node_pool_max_count = 6

      # Three nodes across three zones, matching prod's structure at a smaller
      # size. The zone spread is the property worth validating; the core count
      # is not.
      vm_size                 = "Standard_D2s_v5"
      instance_count          = 3
      enable_autoscale        = true
      autoscale_min_instances = 3
      autoscale_max_instances = 8
      compute_zones           = ["1", "2", "3"]
      use_spot_instances      = false
      os_disk_type            = "Premium_LRS"
      os_disk_size_gb         = 128

      # Business Critical at half prod's core count, NOT General Purpose.
      #
      # Zone redundancy is structural, and on Azure SQL it is a property of the
      # TIER, not a flag: General Purpose cannot carry it here. Dropping to GP
      # to save money would therefore have silently dropped zone redundancy
      # too, which is the one database property stage exists to prove. The
      # module's own coherence check rejects that combination outright.
      #
      # So the deviation from prod is cores, which is capacity, rather than
      # tier, which is topology. Long-term retention is on because restoring
      # from an LTR backup is a procedure worth rehearsing before it is needed.
      sql_sku_name                   = "BC_Gen5_2"
      sql_zone_redundant             = true
      sql_backup_retention_days      = 35
      sql_enable_long_term_retention = true

      enable_redis            = true
      redis_sku_name          = "Balanced_B1"
      redis_high_availability = true

      # GZRS matches prod. Replication type determines what a regional outage
      # actually costs, so a cheaper setting here would validate nothing.
      storage_replication_type  = "GZRS"
      storage_enable_versioning = true

      data_plane_public_access_enabled = false

      # The ONE production behaviour stage deliberately does not mirror.
      #
      # Purge protection cannot be disabled once enabled, and the naming module
      # produces a deterministic vault name — so a single stage teardown would
      # make the environment unrebuildable for the full 90-day retention. A
      # pre-production environment that cannot be rebuilt has stopped being
      # useful for its one purpose.
      #
      # The consequence is that "purge protection blocks recreation" is a
      # lesson prod learns on its own. Soft delete retention still matches
      # prod, so the recovery window itself is exercised.
      key_vault_purge_protection           = false
      key_vault_soft_delete_retention_days = 90

      # Locks validate an operational runbook rather than this Terraform, and
      # they obstruct the rebuild cycle stage depends on.
      enable_resource_locks = false

      # Tenant-level and per-resource decisions respectively; duplicating
      # either here doubles the bill without changing what is validated.
      enable_ddos_protection = false
      enable_defender        = false

      log_retention_days = 90
      log_daily_quota_gb = -1
      enable_vm_insights = true
      enable_alerts      = true

      enable_backup         = true
      backup_retention_days = 35
    }

    ##########################################################################
    # prod — full production grade.
    #
    # Every availability and security control enabled. Zone-redundant across
    # compute, ingress, database and cache.
    #
    # NOT deployable on a free subscription. Indicative cost is four figures
    # per month; see the indicative_monthly_cost_usd output.
    ##########################################################################
    prod = {
      # Premium rather than Standard for IDPS and TLS inspection, which is
      # what makes the firewall an inspection point rather than an expensive
      # NAT device. Roughly $365/month more than Standard.
      enable_firewall    = true
      firewall_sku_tier  = "Premium"
      enable_nat_gateway = false

      enable_application_gateway       = true
      application_gateway_sku          = "WAF_v2"
      waf_mode                         = "Prevention"
      application_gateway_zones        = ["1", "2", "3"]
      application_gateway_min_capacity = 2
      application_gateway_max_capacity = 10
      enable_public_load_balancer      = false

      enable_bastion = true
      bastion_sku    = "Standard"

      aks_sku_tier             = "Standard"
      aks_private_cluster      = true
      aks_network_policy       = "azure"
      enable_user_node_pool    = true
      user_node_pool_min_count = 3
      user_node_pool_max_count = 10

      vm_size                 = "Standard_D4s_v5"
      instance_count          = 3
      enable_autoscale        = true
      autoscale_min_instances = 3
      autoscale_max_instances = 20
      compute_zones           = ["1", "2", "3"]
      use_spot_instances      = false
      os_disk_type            = "Premium_LRS"
      os_disk_size_gb         = 128

      # Business Critical is required for zone redundancy plus a local replica
      # set. General Purpose supports zone redundancy on some hardware but
      # without the same failover characteristics.
      sql_sku_name                   = "BC_Gen5_4"
      sql_zone_redundant             = true
      sql_backup_retention_days      = 35
      sql_enable_long_term_retention = true

      # High availability is what carries the Managed Redis SLA.
      enable_redis            = true
      redis_sku_name          = "Balanced_B3"
      redis_high_availability = true

      storage_replication_type  = "GZRS"
      storage_enable_versioning = true

      data_plane_public_access_enabled = false

      key_vault_purge_protection           = true
      key_vault_soft_delete_retention_days = 90

      enable_resource_locks = true
      # DDoS Network Protection is roughly $2,900/month per tenant and is
      # therefore opt-in even in production. Enable it once, at tenant level,
      # rather than per environment.
      enable_ddos_protection = false
      enable_defender        = true

      log_retention_days = 90
      # No daily cap in production. A cap drops data once hit, and the data it
      # drops is exactly what an incident investigation needs.
      log_daily_quota_gb = -1
      enable_vm_insights = true
      enable_alerts      = true

      enable_backup         = true
      backup_retention_days = 90
    }
  }

  selected = local.profiles[var.environment]
}

################################################################################
# Override application
#
# Written out attribute by attribute rather than with a merge() over the
# override object. A for-expression over an object with mixed attribute types
# forces Terraform to unify them into a single type, which either fails or
# silently stringifies booleans and numbers. Explicit null checks are verbose
# but preserve types exactly.
################################################################################

locals {
  o = var.overrides

  profile = {
    enable_firewall    = local.o.enable_firewall != null ? local.o.enable_firewall : local.selected.enable_firewall
    firewall_sku_tier  = local.o.firewall_sku_tier != null ? local.o.firewall_sku_tier : local.selected.firewall_sku_tier
    enable_nat_gateway = local.o.enable_nat_gateway != null ? local.o.enable_nat_gateway : local.selected.enable_nat_gateway

    enable_application_gateway       = local.o.enable_application_gateway != null ? local.o.enable_application_gateway : local.selected.enable_application_gateway
    application_gateway_sku          = local.o.application_gateway_sku != null ? local.o.application_gateway_sku : local.selected.application_gateway_sku
    waf_mode                         = local.o.waf_mode != null ? local.o.waf_mode : local.selected.waf_mode
    application_gateway_zones        = local.o.application_gateway_zones != null ? local.o.application_gateway_zones : local.selected.application_gateway_zones
    application_gateway_min_capacity = local.o.application_gateway_min_capacity != null ? local.o.application_gateway_min_capacity : local.selected.application_gateway_min_capacity
    application_gateway_max_capacity = local.o.application_gateway_max_capacity != null ? local.o.application_gateway_max_capacity : local.selected.application_gateway_max_capacity
    enable_public_load_balancer      = local.o.enable_public_load_balancer != null ? local.o.enable_public_load_balancer : local.selected.enable_public_load_balancer

    enable_bastion = local.o.enable_bastion != null ? local.o.enable_bastion : local.selected.enable_bastion
    bastion_sku    = local.o.bastion_sku != null ? local.o.bastion_sku : local.selected.bastion_sku

    aks_sku_tier             = local.o.aks_sku_tier != null ? local.o.aks_sku_tier : local.selected.aks_sku_tier
    aks_private_cluster      = local.o.aks_private_cluster != null ? local.o.aks_private_cluster : local.selected.aks_private_cluster
    aks_network_policy       = local.o.aks_network_policy != null ? local.o.aks_network_policy : local.selected.aks_network_policy
    enable_user_node_pool    = local.o.enable_user_node_pool != null ? local.o.enable_user_node_pool : local.selected.enable_user_node_pool
    user_node_pool_min_count = local.o.user_node_pool_min_count != null ? local.o.user_node_pool_min_count : local.selected.user_node_pool_min_count
    user_node_pool_max_count = local.o.user_node_pool_max_count != null ? local.o.user_node_pool_max_count : local.selected.user_node_pool_max_count

    vm_size                 = local.o.vm_size != null ? local.o.vm_size : local.selected.vm_size
    instance_count          = local.o.instance_count != null ? local.o.instance_count : local.selected.instance_count
    enable_autoscale        = local.o.enable_autoscale != null ? local.o.enable_autoscale : local.selected.enable_autoscale
    autoscale_min_instances = local.o.autoscale_min_instances != null ? local.o.autoscale_min_instances : local.selected.autoscale_min_instances
    autoscale_max_instances = local.o.autoscale_max_instances != null ? local.o.autoscale_max_instances : local.selected.autoscale_max_instances
    compute_zones           = local.o.compute_zones != null ? local.o.compute_zones : local.selected.compute_zones
    use_spot_instances      = local.o.use_spot_instances != null ? local.o.use_spot_instances : local.selected.use_spot_instances
    os_disk_type            = local.o.os_disk_type != null ? local.o.os_disk_type : local.selected.os_disk_type
    os_disk_size_gb         = local.o.os_disk_size_gb != null ? local.o.os_disk_size_gb : local.selected.os_disk_size_gb

    sql_sku_name                   = local.o.sql_sku_name != null ? local.o.sql_sku_name : local.selected.sql_sku_name
    sql_zone_redundant             = local.o.sql_zone_redundant != null ? local.o.sql_zone_redundant : local.selected.sql_zone_redundant
    sql_backup_retention_days      = local.o.sql_backup_retention_days != null ? local.o.sql_backup_retention_days : local.selected.sql_backup_retention_days
    sql_enable_long_term_retention = local.o.sql_enable_long_term_retention != null ? local.o.sql_enable_long_term_retention : local.selected.sql_enable_long_term_retention
    enable_redis                   = local.o.enable_redis != null ? local.o.enable_redis : local.selected.enable_redis
    redis_sku_name                 = local.o.redis_sku_name != null ? local.o.redis_sku_name : local.selected.redis_sku_name
    redis_high_availability        = local.o.redis_high_availability != null ? local.o.redis_high_availability : local.selected.redis_high_availability
    storage_replication_type       = local.o.storage_replication_type != null ? local.o.storage_replication_type : local.selected.storage_replication_type
    storage_enable_versioning      = local.o.storage_enable_versioning != null ? local.o.storage_enable_versioning : local.selected.storage_enable_versioning

    data_plane_public_access_enabled     = local.o.data_plane_public_access_enabled != null ? local.o.data_plane_public_access_enabled : local.selected.data_plane_public_access_enabled
    key_vault_purge_protection           = local.o.key_vault_purge_protection != null ? local.o.key_vault_purge_protection : local.selected.key_vault_purge_protection
    key_vault_soft_delete_retention_days = local.o.key_vault_soft_delete_retention_days != null ? local.o.key_vault_soft_delete_retention_days : local.selected.key_vault_soft_delete_retention_days
    enable_resource_locks                = local.o.enable_resource_locks != null ? local.o.enable_resource_locks : local.selected.enable_resource_locks
    enable_ddos_protection               = local.o.enable_ddos_protection != null ? local.o.enable_ddos_protection : local.selected.enable_ddos_protection
    enable_defender                      = local.o.enable_defender != null ? local.o.enable_defender : local.selected.enable_defender

    log_retention_days    = local.o.log_retention_days != null ? local.o.log_retention_days : local.selected.log_retention_days
    log_daily_quota_gb    = local.o.log_daily_quota_gb != null ? local.o.log_daily_quota_gb : local.selected.log_daily_quota_gb
    enable_vm_insights    = local.o.enable_vm_insights != null ? local.o.enable_vm_insights : local.selected.enable_vm_insights
    enable_alerts         = local.o.enable_alerts != null ? local.o.enable_alerts : local.selected.enable_alerts
    enable_backup         = local.o.enable_backup != null ? local.o.enable_backup : local.selected.enable_backup
    backup_retention_days = local.o.backup_retention_days != null ? local.o.backup_retention_days : local.selected.backup_retention_days
  }
}

################################################################################
# vCPU footprint
#
# Sizes not in this table skip the quota check rather than guessing, since a
# wrong guess would either block a valid plan or pass an invalid one.
################################################################################

locals {
  vm_size_vcpus = {
    Standard_B1s  = 1
    Standard_B1ms = 1
    Standard_B2s  = 2
    Standard_B2ms = 2
    Standard_B4ms = 4
    Standard_B8ms = 8

    # Sizes permitted on a restricted subscription. B-series x86 is blocked in
    # some regions, so the ARM b*ps_v2 family and the D-series are the fallbacks.
    Standard_B2ps_v2  = 2
    Standard_B2pls_v2 = 2
    Standard_B4ps_v2  = 4
    Standard_D2s_v4   = 2
    Standard_D4s_v4   = 4
    Standard_D2s_v6   = 2
    Standard_D2ls_v6  = 2
    Standard_D2as_v7  = 2
    Standard_DS1_v2   = 1
    Standard_DS2_v2   = 2
    Standard_D2s_v3   = 2
    Standard_D4s_v3   = 4
    Standard_D2s_v5   = 2
    Standard_D4s_v5   = 4
    Standard_D8s_v5   = 8
    Standard_D2ds_v5  = 2
    Standard_D4ds_v5  = 4
    Standard_D2ds_v7  = 2
    Standard_D4ds_v7  = 4
    Standard_F2s_v2   = 2
    Standard_F4s_v2   = 4
    Standard_E2s_v5   = 2
    Standard_E4s_v5   = 4
  }

  vcpus_per_instance = lookup(local.vm_size_vcpus, local.profile.vm_size, null)

  # Peak footprint is every compute tier at its autoscale maximum
  # simultaneously, which is what a correlated load spike produces.
  peak_instances = local.profile.enable_autoscale ? local.profile.autoscale_max_instances : local.profile.instance_count
  peak_vcpus     = local.vcpus_per_instance == null ? null : local.vcpus_per_instance * local.peak_instances * var.compute_tier_count

  quota_check_possible = var.subscription_vcpu_quota != null && local.peak_vcpus != null

  # coalesce because `&&` is not guaranteed to short-circuit: on Terraform
  # 1.9.8 the comparison runs even when quota_check_possible is false, and
  # comparing null fails the whole expression. When the check is not possible
  # both sides coalesce to 0, so the comparison is false either way and the
  # guard above still decides the outcome.
  quota_exceeded = local.quota_check_possible && (
    coalesce(local.peak_vcpus, 0) > coalesce(var.subscription_vcpu_quota, 0)
  )
}

################################################################################
# Indicative cost
#
# ORDER OF MAGNITUDE ONLY. Approximate US list prices, no committed-use or
# enterprise discount, no data processing, egress, storage capacity or
# transaction charges. Intended to answer "is this tens, hundreds or thousands
# of dollars a month" at plan time. Use infracost for figures anyone will act
# on financially.
################################################################################

locals {
  cost_firewall = local.profile.enable_firewall ? (local.profile.firewall_sku_tier == "Premium" ? 1277 : 912) : 0
  cost_nat      = local.profile.enable_nat_gateway ? 33 : 0

  cost_appgw = local.profile.enable_application_gateway ? (
    (local.profile.application_gateway_sku == "WAF_v2" ? 263 : 180)
    + local.profile.application_gateway_min_capacity * 7
  ) : 0

  cost_public_lb = local.profile.enable_public_load_balancer ? 18 : 0

  bastion_costs = {
    Developer = 0
    Basic     = 140
    Standard  = 175
  }
  cost_bastion = local.profile.enable_bastion ? lookup(local.bastion_costs, local.profile.bastion_sku, 140) : 0

  vm_monthly_costs = {
    Standard_B1s      = 8
    Standard_B1ms     = 15
    Standard_B2s      = 30
    Standard_B2ms     = 60
    Standard_D2s_v4   = 75
    Standard_B2pls_v2 = 28
    Standard_D2s_v5   = 70
    Standard_D4s_v5   = 140
    Standard_D8s_v5   = 280
    Standard_D2ds_v5  = 82
    Standard_D4ds_v5  = 164
  }
  cost_compute = lookup(local.vm_monthly_costs, local.profile.vm_size, 100) * local.profile.instance_count * var.compute_tier_count

  sql_monthly_costs = {
    GP_S_Gen5_1 = 15
    GP_Gen5_2   = 370
    GP_Gen5_4   = 740
    BC_Gen5_2   = 465
    BC_Gen5_4   = 930
  }
  cost_sql = lookup(local.sql_monthly_costs, local.profile.sql_sku_name, 400)

  # Azure Managed Redis, approximate Central US list price. High availability
  # roughly doubles the node count and therefore the rate.
  redis_monthly_costs = {
    Balanced_B0         = 13
    Balanced_B1         = 26
    Balanced_B3         = 53
    Balanced_B5         = 105
    MemoryOptimized_M10 = 130
    ComputeOptimized_X3 = 95
    FlashOptimized_A250 = 320
  }
  cost_redis = local.profile.enable_redis ? (
    lookup(local.redis_monthly_costs, local.profile.redis_sku_name, 50) * (local.profile.redis_high_availability ? 2 : 1)
  ) : 0

  cost_ddos = local.profile.enable_ddos_protection ? 2944 : 0

  # Four private endpoints at roughly $7.30 each, plus the internal load
  # balancer, plus a nominal Log Analytics figure.
  cost_fixed = 29 + 18 + 10

  indicative_monthly_cost_usd = (
    local.cost_firewall + local.cost_nat + local.cost_appgw + local.cost_public_lb +
    local.cost_bastion + local.cost_compute + local.cost_sql + local.cost_redis +
    local.cost_ddos + local.cost_fixed
  )
}

################################################################################
# Coherence checks
################################################################################

locals {
  valid_zones = ["1", "2", "3"]

  constraint_failures = concat(
    # Exactly one ingress path. Both would mean two public entry points, one
    # of them bypassing the WAF entirely.
    local.profile.enable_application_gateway && local.profile.enable_public_load_balancer ? [
      "Both enable_application_gateway and enable_public_load_balancer are true. Two public ingress paths means one bypasses the WAF. Enable exactly one."
    ] : [],

    !local.profile.enable_application_gateway && !local.profile.enable_public_load_balancer ? [
      "Neither enable_application_gateway nor enable_public_load_balancer is true. The application would have no ingress path."
    ] : [],

    # Exactly one egress path. Azure Firewall works by UDR and takes
    # precedence, so a NAT Gateway alongside it is billed and unused.
    local.profile.enable_firewall && local.profile.enable_nat_gateway ? [
      "Both enable_firewall and enable_nat_gateway are true. The firewall UDR takes precedence, so the NAT Gateway would be billed (~$33/month) and never used. Enable exactly one."
    ] : [],

    !local.profile.enable_firewall && !local.profile.enable_nat_gateway ? [
      "Neither enable_firewall nor enable_nat_gateway is true. Default outbound access was retired on 30 September 2025, so workload subnets would have no internet egress at all — package installs, agent enrolment and certificate revocation checks would all fail."
    ] : [],

    # Autoscale bounds.
    local.profile.autoscale_min_instances > local.profile.autoscale_max_instances ? [
      "autoscale_min_instances (${local.profile.autoscale_min_instances}) exceeds autoscale_max_instances (${local.profile.autoscale_max_instances})."
    ] : [],

    local.profile.enable_autoscale && local.profile.instance_count < local.profile.autoscale_min_instances ? [
      "instance_count (${local.profile.instance_count}) is below autoscale_min_instances (${local.profile.autoscale_min_instances}); the scale set would be scaled up immediately on creation."
    ] : [],

    local.profile.enable_autoscale && local.profile.instance_count > local.profile.autoscale_max_instances ? [
      "instance_count (${local.profile.instance_count}) exceeds autoscale_max_instances (${local.profile.autoscale_max_instances}); the scale set would be scaled down immediately on creation."
    ] : [],

    # Quota.
    local.quota_exceeded ? [
      "Peak vCPU footprint is ${local.peak_vcpus} (${local.vcpus_per_instance} vCPU x ${local.peak_instances} instances x ${var.compute_tier_count} tiers) but the subscription quota is ${var.subscription_vcpu_quota}. Scale-out would fail silently under load. Reduce autoscale_max_instances, choose a smaller vm_size, or request a quota increase."
    ] : [],

    # Zones.
    length(setsubtract(toset(local.profile.compute_zones), toset(local.valid_zones))) > 0 ? [
      "compute_zones contains values outside [\"1\", \"2\", \"3\"]: ${join(", ", tolist(setsubtract(toset(local.profile.compute_zones), toset(local.valid_zones))))}."
    ] : [],

    length(setsubtract(toset(local.profile.application_gateway_zones), toset(local.valid_zones))) > 0 ? [
      "application_gateway_zones contains values outside [\"1\", \"2\", \"3\"]."
    ] : [],

    # WAF mode is only meaningful on the WAF SKU.
    local.profile.enable_application_gateway && local.profile.application_gateway_sku != "WAF_v2" && local.profile.waf_mode == "Prevention" ? [
      "waf_mode is \"Prevention\" but application_gateway_sku is \"${local.profile.application_gateway_sku}\". WAF rules require the WAF_v2 SKU; the setting would be silently ignored."
    ] : [],

    contains(["Detection", "Prevention"], local.profile.waf_mode) ? [] : [
      "waf_mode must be \"Detection\" or \"Prevention\", got \"${local.profile.waf_mode}\"."
    ],

    # Zone redundancy requires tiers that support it.
    local.profile.sql_zone_redundant && !startswith(local.profile.sql_sku_name, "BC_") && !startswith(local.profile.sql_sku_name, "P") ? [
      "sql_zone_redundant is true but sql_sku_name is \"${local.profile.sql_sku_name}\". Zone redundancy requires a Business Critical or Premium tier."
    ] : [],

    length(local.profile.application_gateway_zones) > 0 && local.profile.enable_application_gateway && local.profile.application_gateway_sku == "Standard" ? [
      "Application Gateway zones require a v2 SKU."
    ] : [],

    # Key Vault retention window.
    local.profile.key_vault_soft_delete_retention_days < 7 || local.profile.key_vault_soft_delete_retention_days > 90 ? [
      "key_vault_soft_delete_retention_days must be between 7 and 90, got ${local.profile.key_vault_soft_delete_retention_days}."
    ] : [],

    # Log Analytics retention window.
    local.profile.log_retention_days < 30 || local.profile.log_retention_days > 730 ? [
      "log_retention_days must be between 30 and 730, got ${local.profile.log_retention_days}."
    ] : [],

    # Spot instances are an availability trade, not a cost lever, for a tier
    # fronted by a load balancer with an SLA.
    local.profile.use_spot_instances && var.environment == "prod" ? [
      "use_spot_instances is true in production. Spot instances are evicted with 30 seconds notice and carry no SLA."
    ] : [],
  )
}

################################################################################
# Production guardrails
#
# Applied AFTER overrides, so an override cannot quietly produce an
# unprotected production environment.
################################################################################

locals {
  production_guardrail_failures = (
    var.environment == "prod" && var.enforce_production_guardrails
    ) ? concat(
    local.profile.enable_backup ? [] : ["Production requires enable_backup."],
    local.profile.enable_alerts ? [] : ["Production requires enable_alerts."],
    local.profile.key_vault_purge_protection ? [] : ["Production requires key_vault_purge_protection. Without it, a deleted vault and its keys are unrecoverable."],
    local.profile.enable_resource_locks ? [] : ["Production requires enable_resource_locks."],
    local.profile.data_plane_public_access_enabled ? ["Production must not expose data services on a public endpoint. Set data_plane_public_access_enabled = false; access is via private endpoint only."] : [],
    (local.profile.enable_redis && !local.profile.redis_high_availability) ? ["Production requires redis_high_availability. Without it the cache is a single node with no SLA, and a host fault loses it entirely."] : [],
    local.profile.aks_private_cluster ? [] : ["Production requires aks_private_cluster. A public API server endpoint exposes the Kubernetes control plane to the internet."],
    local.profile.aks_sku_tier == "Standard" || local.profile.aks_sku_tier == "Premium" ? [] : ["Production requires the Standard or Premium AKS SKU tier. The Free tier carries NO control-plane SLA and caps the cluster at a smaller node count."],
    length(local.profile.compute_zones) >= 3 ? [] : ["Production requires node pools across three availability zones. Fewer means a zone outage takes the cluster with it."],
    local.profile.sql_backup_retention_days >= 35 ? [] : ["Production requires sql_backup_retention_days of at least 35, got ${local.profile.sql_backup_retention_days}."],
    local.profile.log_daily_quota_gb > 0 ? ["Production must not set a Log Analytics daily quota (log_daily_quota_gb = ${local.profile.log_daily_quota_gb}). A cap drops ingestion once hit, including the security signals an investigation depends on. Use -1."] : [],
  ) : []
}
