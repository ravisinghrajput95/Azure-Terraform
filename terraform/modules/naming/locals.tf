################################################################################
# Azure CAF resource type abbreviations
#
# Source of truth for every resource prefix in the platform. Callers reference
# local.abbreviations via the module output rather than typing "nsg-" inline,
# which is what makes "no hardcoded strings" enforceable instead of aspirational.
################################################################################

locals {
  abbreviations = {
    resource_group            = "rg"
    virtual_network           = "vnet"
    subnet                    = "snet"
    network_security_group    = "nsg"
    application_security_grp  = "asg"
    route_table               = "rt"
    public_ip                 = "pip"
    public_ip_prefix          = "ippre"
    nat_gateway               = "ng"
    firewall                  = "afw"
    firewall_policy           = "afwp"
    bastion                   = "bas"
    application_gateway       = "agw"
    waf_policy                = "waf"
    load_balancer_internal    = "lbi"
    load_balancer_external    = "lbe"
    virtual_machine_scale_set = "vmss"
    virtual_machine           = "vm"
    network_interface         = "nic"
    disk                      = "disk"
    key_vault                 = "kv"
    storage_account           = "st"
    sql_server                = "sql"
    sql_database              = "sqldb"
    redis                     = "redis"
    log_analytics_workspace   = "log"
    application_insights      = "appi"
    managed_identity          = "id"
    private_endpoint          = "pep"
    private_dns_zone          = "pdns"
    recovery_services_vault   = "rsv"
    backup_policy             = "bkpol"
    data_collection_rule      = "dcr"
    data_collection_endpoint  = "dce"
    action_group              = "ag"
    alert_rule                = "alrt"
    autoscale_setting         = "as"
    management_lock           = "lock"
    diagnostic_setting        = "diag"
  }
}

################################################################################
# Region abbreviations
#
# Azure exposes regions under two spellings ("East US" and "eastus"). The
# normalisation below collapses both to the internal form before lookup, so a
# caller copying a region out of the portal gets the same result as one copying
# it out of the CLI.
#
# An unknown region is a hard failure (see the precondition in main.tf) rather
# than a silent fallback. A silent fallback would produce two different regions
# sharing an abbreviation, and therefore colliding resource names.
################################################################################

locals {
  default_location_abbreviations = {
    # Americas
    eastus          = "eus"
    eastus2         = "eus2"
    westus          = "wus"
    westus2         = "wus2"
    westus3         = "wus3"
    centralus       = "cus"
    northcentralus  = "ncus"
    southcentralus  = "scus"
    westcentralus   = "wcus"
    canadacentral   = "cnc"
    canadaeast      = "cne"
    brazilsouth     = "brs"
    brazilsoutheast = "brse"
    mexicocentral   = "mxc"
    # Europe
    northeurope        = "neu"
    westeurope         = "weu"
    uksouth            = "uks"
    ukwest             = "ukw"
    francecentral      = "frc"
    francesouth        = "frs"
    germanywestcentral = "gwc"
    germanynorth       = "gn"
    norwayeast         = "nwe"
    norwaywest         = "nww"
    switzerlandnorth   = "szn"
    switzerlandwest    = "szw"
    swedencentral      = "sdc"
    italynorth         = "itn"
    polandcentral      = "plc"
    spaincentral       = "spc"
    # Middle East and Africa
    uaenorth         = "uan"
    uaecentral       = "uac"
    qatarcentral     = "qac"
    israelcentral    = "ilc"
    southafricanorth = "san"
    southafricawest  = "saw"
    # Asia Pacific
    centralindia       = "inc"
    southindia         = "ins"
    westindia          = "inw"
    eastasia           = "ea"
    southeastasia      = "sea"
    japaneast          = "jpe"
    japanwest          = "jpw"
    koreacentral       = "krc"
    koreasouth         = "krs"
    australiaeast      = "aue"
    australiasoutheast = "ause"
    australiacentral   = "auc"
    australiacentral2  = "auc2"
    newzealandnorth    = "nzn"
  }

  # Collapse "East US", "eastus" and "EastUS" onto a single key.
  location_normalized = lower(replace(trimspace(var.location), " ", ""))

  # Caller overrides win, so a new Azure region can be adopted without waiting
  # for this module to be updated.
  location_abbreviations = merge(local.default_location_abbreviations, var.location_abbreviations)

  location_is_known = contains(keys(local.location_abbreviations), local.location_normalized)

  # lookup() with a sentinel keeps evaluation total. The precondition in main.tf
  # is what actually fails the plan; without the sentinel, an unknown region
  # would raise an opaque index error before the precondition could report a
  # useful message.
  location_short = lookup(local.location_abbreviations, local.location_normalized, "xxx")
}

################################################################################
# Name segments
################################################################################

locals {
  # Full environment word is used in hyphenated names because it reads clearly
  # in the portal. The 3-character form is reserved for names with a hard
  # length cap and no separators (storage accounts).
  environment_abbreviations = {
    dev  = "dev"
    test = "tst"
    prod = "prd"
  }

  environment_short = local.environment_abbreviations[var.environment]

  # Deterministic 4-character suffix for globally-unique names. Derived from a
  # hash rather than random_string so that the name is stable across state
  # rebuilds — a random_string would rename (and therefore destroy and
  # recreate) the storage account if state were ever lost and re-imported.
  unique_suffix = substr(sha256(join("-", [var.workload, var.environment, local.location_normalized, var.unique_seed])), 0, 4)

  # Hyphenated base, e.g. "cloudcart-prod-eus"
  base = join("-", [var.workload, var.environment, local.location_short])

  # Separator-free base for resources that reject hyphens, e.g. "cloudcartprdeus"
  base_compact = join("", [var.workload, local.environment_short, local.location_short])
}

################################################################################
# Composed names
################################################################################

locals {
  # One resource group per lifecycle scope.
  resource_group_names = {
    for scope in var.resource_group_scopes :
    scope => join("-", [local.abbreviations.resource_group, local.base, scope])
  }

  # Per-tier names. Precomputed here so that callers iterate a map instead of
  # building strings, which keeps tier naming consistent across the six modules
  # that need it.
  subnet_names = {
    for tier in var.tiers :
    tier => join("-", [local.abbreviations.subnet, tier, var.environment, local.location_short])
  }

  network_security_group_names = {
    for tier in var.tiers :
    tier => join("-", [local.abbreviations.network_security_group, tier, var.environment, local.location_short])
  }

  # Scoped to compute_tiers, not tiers. Emitting "vmss-pep-..." would imply a
  # scale set exists in the private endpoint subnet, which it never does.
  scale_set_names = {
    for tier in var.compute_tiers :
    tier => join("-", [local.abbreviations.virtual_machine_scale_set, tier, var.environment, local.location_short, var.instance])
  }

  managed_identity_names = {
    for tier in var.compute_tiers :
    tier => join("-", [local.abbreviations.managed_identity, tier, var.environment, local.location_short, var.instance])
  }

  # Globally-unique names carry the hash suffix. Everything else is unique
  # within its resource group and does not need it.
  storage_account_name = substr(join("", [local.abbreviations.storage_account, local.base_compact, local.unique_suffix]), 0, 24)
  key_vault_name       = substr(join("-", [local.abbreviations.key_vault, var.workload, local.environment_short, local.unique_suffix]), 0, 24)
  sql_server_name      = join("-", [local.abbreviations.sql_server, local.base, local.unique_suffix])
  redis_name           = join("-", [local.abbreviations.redis, local.base, local.unique_suffix])

  # Regional / resource-group-scoped names.
  names = {
    virtual_network         = join("-", [local.abbreviations.virtual_network, local.base, var.instance])
    route_table_workload    = join("-", [local.abbreviations.route_table, "workload", var.environment, local.location_short])
    route_table_firewall    = join("-", [local.abbreviations.route_table, "fw", var.environment, local.location_short])
    firewall                = join("-", [local.abbreviations.firewall, local.base, var.instance])
    firewall_policy         = join("-", [local.abbreviations.firewall_policy, local.base, var.instance])
    nat_gateway             = join("-", [local.abbreviations.nat_gateway, local.base, var.instance])
    bastion                 = join("-", [local.abbreviations.bastion, local.base, var.instance])
    application_gateway     = join("-", [local.abbreviations.application_gateway, local.base, var.instance])
    waf_policy              = join("-", [local.abbreviations.waf_policy, local.base, var.instance])
    load_balancer_internal  = join("-", [local.abbreviations.load_balancer_internal, "biz", var.environment, local.location_short, var.instance])
    load_balancer_external  = join("-", [local.abbreviations.load_balancer_external, local.base, var.instance])
    log_analytics_workspace = join("-", [local.abbreviations.log_analytics_workspace, local.base, var.instance])
    recovery_services_vault = join("-", [local.abbreviations.recovery_services_vault, local.base, var.instance])
    action_group            = join("-", [local.abbreviations.action_group, local.base, var.instance])
    data_collection_rule    = join("-", [local.abbreviations.data_collection_rule, "vminsights", var.environment, local.location_short])
    sql_database            = join("-", [local.abbreviations.sql_database, local.base, var.instance])
  }
}

################################################################################
# Constraint checks
#
# Evaluated by preconditions in main.tf. Azure enforces different character
# sets and length caps per resource type; catching a violation here costs a
# second at plan time instead of a failed apply partway through a deployment.
################################################################################

locals {
  constraint_checks = {
    storage_account = {
      value   = local.storage_account_name
      valid   = can(regex("^[a-z0-9]{3,24}$", local.storage_account_name))
      message = "Storage account name must be 3-24 lowercase alphanumeric characters. Shorten var.workload."
    }
    key_vault = {
      value   = local.key_vault_name
      valid   = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", local.key_vault_name))
      message = "Key Vault name must be 3-24 characters, alphanumeric and hyphens, start with a letter and not end with a hyphen. Shorten var.workload."
    }
    sql_server = {
      value   = local.sql_server_name
      valid   = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", local.sql_server_name))
      message = "SQL server name must be 1-63 lowercase alphanumeric characters or hyphens, and must not start or end with a hyphen."
    }
    redis = {
      value   = local.redis_name
      valid   = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$", local.redis_name))
      message = "Redis cache name must be 1-63 alphanumeric characters or hyphens, and must not start or end with a hyphen."
    }
    virtual_network = {
      value   = local.names.virtual_network
      valid   = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}[a-zA-Z0-9_]$", local.names.virtual_network))
      message = "Virtual network name must be 2-64 characters and may not end with a period or hyphen."
    }
  }

  constraint_failures = [
    for key, check in local.constraint_checks :
    "${key}: \"${check.value}\" is invalid. ${check.message}"
    if !check.valid
  ]
}
