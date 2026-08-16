# Module: `profile`

Selects a coherent bundle of SKUs, capacities and feature flags for an
environment, applies caller overrides, and refuses to emit a configuration that
is internally contradictory or that would exceed the subscription's vCPU quota.

This is where all environment-conditional logic in the platform lives.

Creates no Azure resources and declares no providers.

---

## The central rule

**`var.environment` appears in exactly three modules: `naming`, `tags` and
`profile`. Nowhere else.**

A module containing `var.environment == "prod" ? ... : ...` is not reusable —
it has an opinion about deployment topology baked into what should be a
component. Every other module receives explicit capability inputs:

```hcl
# Correct — the module knows nothing about environments
module "firewall" {
  count    = module.profile.enable_firewall ? 1 : 0
  source   = "../../modules/firewall"
  sku_tier = module.profile.profile.firewall_sku_tier
}

# Wrong — the anti-pattern this module exists to prevent
module "firewall" {
  count       = var.environment == "prod" ? 1 : 0
  environment = var.environment
}
```

---

## Usage

```hcl
module "profile" {
  source = "../../modules/profile"

  environment             = "dev"
  subscription_vcpu_quota = 4        # from `az vm list-usage`
  compute_tier_count      = 2

  overrides = {
    instance_count = 2               # everything else keeps the dev default
  }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `environment` | `string` | — | `dev`, `test` or `prod`. |
| `overrides` | `object` | `{}` | 41 optional attributes. Unset attributes keep the profile default. |
| `subscription_vcpu_quota` | `number` | `null` | Total regional vCPU quota. Enables the footprint check. |
| `compute_tier_count` | `number` | `2` | Tiers running a scale set; quota is shared across them. |
| `enforce_production_guardrails` | `bool` | `true` | Assert prod cannot be stripped of backup, alerts, purge protection or locks. |

## Outputs

`profile` (all 41 attributes), plus individually surfaced flags
(`enable_firewall`, `enable_application_gateway`, `enable_backup`, …),
`egress_strategy`, `ingress_strategy`, `vcpus_per_instance`, `peak_vcpus`,
`quota_checked`, `indicative_monthly_cost_usd`, `cost_breakdown`,
`validation_id`.

---

## The three profiles

| | dev | test | prod |
|---|---|---|---|
| **Egress** | NAT Gateway | NAT Gateway | Firewall Premium |
| **Ingress** | Public Standard LB | App Gateway WAF_v2 | App Gateway WAF_v2 |
| **WAF mode** | — | Detection | Prevention |
| **AppGW zones** | — | none | 1, 2, 3 |
| **Bastion** | Developer (free) | Basic | Standard |
| **VM size** | `Standard_B1s` | `Standard_D2s_v5` | `Standard_D4s_v5` |
| **Instances** | 1, no autoscale | 2 → 4 | 3 → 20 |
| **Compute zones** | none | 1, 2 | 1, 2, 3 |
| **SQL** | `GP_S_Gen5_1` serverless | `GP_Gen5_2` | `BC_Gen5_4` zone-redundant |
| **SQL backups** | 7 days | 7 days | 35 days + LTR |
| **Redis** | Basic C0 | Standard C1 | Premium P1 |
| **Storage** | LRS | LRS + versioning | GZRS + versioning |
| **KV purge protection** | off | off | **on** |
| **Resource locks** | off | off | **on** |
| **Defender** | off | off | **on** |
| **Log retention** | 30 d, 0.5 GB/day cap | 30 d, uncapped | 90 d, uncapped |
| **Backup** | off | 14 days | 90 days |
| **Peak vCPUs** | **2** | 16 | 160 |
| **Indicative $/month** | **~155** | ~1,225 | ~3,968 |

Cost figures are order-of-magnitude US list price, excluding data processing,
egress, storage capacity and transactions. Use infracost for anything
financial.

---

## Free-tier sizing

`dev` is the only profile intended to run on an Azure free or trial
subscription. Its values assume the conservative default quota — **4 total
regional vCPUs, burstable families only, zero Spot quota** — and are marked
`[FREE-TIER]` in `locals.tf`.

**These have not been verified against a real subscription.** Run:

```bash
az vm list-usage --location <region> -o table
```

and pass the "Total Regional vCPUs" limit as `subscription_vcpu_quota`. The
module then asserts the peak footprint fits, and fails the plan if it does not.

Specific free-tier accommodations:

- **NAT Gateway, not Azure Firewall** — ~$33/month against ~$912. The firewall
  alone would exhaust a $200 credit in under seven days.
- **NAT Gateway is not optional.** Default outbound access was retired on
  30 September 2025. A subnet with no explicit egress resource has no internet
  connectivity at all.
- **Public load balancer, not Application Gateway** — AppGW has no inexpensive
  tier; even Standard_v2 is roughly $180/month.
- **Bastion Developer SKU** — no charge. Portal-only, no native client, no
  peered-VNet support.
- **Burstable VM size, no Spot** — trial subscriptions are allocated zero Spot
  vCPUs, so spot instances fail to allocate rather than saving money.
- **Autoscale disabled** — an autoscale maximum above quota does not fail at
  apply. It fails silently under load when Azure refuses the allocation.
- **Purge protection off** — once enabled it *cannot* be disabled, and the
  deleted vault name is unusable for the retention period. Since `naming`
  produces a deterministic vault name, purge protection would break the
  destroy/recreate cycle that keeps a credit-limited subscription affordable.
- **Resource locks off** — they would block `terraform destroy`, which is the
  primary cost control on a credit-limited subscription.

---

## Design notes

**Overrides are written out attribute by attribute, not merged.** A
for-expression over an object with mixed attribute types forces Terraform to
unify them into one type, which either fails or silently stringifies booleans
and numbers. Explicit `!= null` ternaries are verbose but preserve types
exactly — and they handle `false` correctly, which `coalesce` does not.

**`overrides` is a typed object, not `map(any)`.** A misspelled attribute name
fails at plan time instead of being silently ignored — the failure mode that
makes configuration bugs expensive.

**Resource locks are the conditional substitute for `prevent_destroy`.**
`lifecycle { prevent_destroy = ... }` requires a literal; it cannot accept a
variable or an expression. There is no way to make it environment-dependent.
`azurerm_management_lock` *can* be conditional, so production protection is
delivered through locks gated on `enable_resource_locks`.

**`egress_strategy` and `ingress_strategy` are strings, not just paired
booleans.** The route table module needs to emit *no default route at all*
when egress is via NAT Gateway, because a NAT Gateway attaches directly to the
subnet and is not a UDR next hop. That is a three-way decision, not a toggle.

**Guardrails are evaluated after overrides.** Otherwise an override could strip
backup or purge protection from production and the check would pass against the
pre-override defaults.

**Unknown VM sizes skip the quota check rather than guessing.** A wrong guess
would either block a valid plan or pass an invalid one. `quota_checked` reports
whether the assertion actually ran, so a caller can tell "passed" from "not
checked".

---

## Coherence rules enforced

The plan fails if the resolved profile is contradictory:

| Rule | Why |
|---|---|
| Exactly one ingress path | Two public entry points means one bypasses the WAF |
| Exactly one egress path | Firewall UDR takes precedence, so a NAT Gateway alongside it is billed and unused |
| At least one egress path | Default outbound access is retired; no egress means package installs and agent enrolment fail |
| `autoscale_min ≤ instance_count ≤ autoscale_max` | Otherwise the scale set resizes immediately on creation |
| Peak vCPUs ≤ quota | Silent scale-out failure under load |
| Zones ⊆ {1, 2, 3} | Invalid zone is an apply-time API error |
| Zone-redundant SQL requires BC/Premium | General Purpose does not offer it the same way |
| `waf_mode = Prevention` requires `WAF_v2` | Otherwise the setting is silently ignored |
| No Spot in production | 30-second eviction notice, no SLA |
| Production requires backup, alerts, purge protection, locks, ≥35-day SQL retention, no ingestion cap | An override must not quietly produce an unprotected production environment |

---

## Tests

```bash
terraform init -backend=false
terraform test
```

22 tests: free-tier compliance of `dev`, production grade of `prod`, override
precedence including `false` booleans, quota enforcement and skip behaviour,
nine coherence violations and four production guardrail violations.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [terraform_data.validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_compute_tier_count"></a> [compute\_tier\_count](#input\_compute\_tier\_count) | Number of independently-scaling compute groups sharing the regional vCPU quota. One for an AKS cluster, whose node pools draw from the same quota; higher only where separate scale sets scale independently of each other. Used by both the vCPU quota assertion and the cost estimate, so an inflated value double-counts both. | `number` | `1` | no |
| <a name="input_enforce_production_guardrails"></a> [enforce\_production\_guardrails](#input\_enforce\_production\_guardrails) | When true and environment is prod, assert that backup, alerting, Key Vault purge protection and resource locks are enabled, and that SQL retains backups for at least 35 days. Prevents an override from silently producing an unprotected production environment. Disable only with a deliberate, documented reason. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment whose profile to select. This is the ONLY place, alongside naming and tags, where an environment name appears. No downstream module may branch on it — they receive explicit capability flags instead. See README.md. | `string` | n/a | yes |
| <a name="input_overrides"></a> [overrides](#input\_overrides) | Per-value overrides applied on top of the selected environment profile. Any attribute left unset keeps the profile default. | <pre>object({<br/>    # Egress<br/>    enable_firewall    = optional(bool)<br/>    firewall_sku_tier  = optional(string)<br/>    enable_nat_gateway = optional(bool)<br/><br/>    # Ingress<br/>    enable_application_gateway       = optional(bool)<br/>    application_gateway_sku          = optional(string)<br/>    waf_mode                         = optional(string)<br/>    application_gateway_zones        = optional(list(string))<br/>    application_gateway_min_capacity = optional(number)<br/>    application_gateway_max_capacity = optional(number)<br/>    enable_public_load_balancer      = optional(bool)<br/><br/>    # Operator access<br/>    enable_bastion = optional(bool)<br/>    bastion_sku    = optional(string)<br/><br/>    # Kubernetes<br/>    aks_sku_tier             = optional(string)<br/>    aks_private_cluster      = optional(bool)<br/>    aks_network_policy       = optional(string)<br/>    enable_user_node_pool    = optional(bool)<br/>    user_node_pool_min_count = optional(number)<br/>    user_node_pool_max_count = optional(number)<br/><br/>    # Compute<br/>    vm_size                 = optional(string)<br/>    instance_count          = optional(number)<br/>    enable_autoscale        = optional(bool)<br/>    autoscale_min_instances = optional(number)<br/>    autoscale_max_instances = optional(number)<br/>    compute_zones           = optional(list(string))<br/>    use_spot_instances      = optional(bool)<br/>    os_disk_type            = optional(string)<br/>    os_disk_size_gb         = optional(number)<br/><br/>    # Data<br/>    sql_sku_name                   = optional(string)<br/>    sql_zone_redundant             = optional(bool)<br/>    sql_backup_retention_days      = optional(number)<br/>    sql_enable_long_term_retention = optional(bool)<br/>    enable_redis                   = optional(bool)<br/>    redis_sku_name                 = optional(string)<br/>    redis_high_availability        = optional(bool)<br/>    storage_replication_type       = optional(string)<br/>    storage_enable_versioning      = optional(bool)<br/><br/>    # Security<br/>    data_plane_public_access_enabled     = optional(bool)<br/>    key_vault_purge_protection           = optional(bool)<br/>    key_vault_soft_delete_retention_days = optional(number)<br/>    enable_resource_locks                = optional(bool)<br/>    enable_ddos_protection               = optional(bool)<br/>    enable_defender                      = optional(bool)<br/><br/>    # Observability<br/>    log_retention_days    = optional(number)<br/>    log_daily_quota_gb    = optional(number)<br/>    enable_vm_insights    = optional(bool)<br/>    enable_alerts         = optional(bool)<br/>    enable_backup         = optional(bool)<br/>    backup_retention_days = optional(number)<br/>  })</pre> | `{}` | no |
| <a name="input_subscription_vcpu_quota"></a> [subscription\_vcpu\_quota](#input\_subscription\_vcpu\_quota) | Total regional vCPU quota for the target region, from `az vm list-usage`. When set, the profile asserts that the maximum autoscale footprint fits within it. Leave null to skip the check. | `number` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aks_is_highly_available"></a> [aks\_is\_highly\_available](#output\_aks\_is\_highly\_available) | Whether the cluster is genuinely HA: three or more nodes spread across at least three availability zones. False means a node or zone fault takes the cluster with it — reported explicitly so a degraded dev cluster never reads as production-shaped. |
| <a name="output_aks_private_cluster"></a> [aks\_private\_cluster](#output\_aks\_private\_cluster) | Whether the Kubernetes API server is private. When true, kubectl works only from inside the VNet or through Bastion. |
| <a name="output_cost_breakdown"></a> [cost\_breakdown](#output\_cost\_breakdown) | Indicative cost split by component, same caveats as indicative\_monthly\_cost\_usd. Useful for seeing which single component dominates an environment's bill. |
| <a name="output_data_plane_public_access_enabled"></a> [data\_plane\_public\_access\_enabled](#output\_data\_plane\_public\_access\_enabled) | Whether Key Vault and Storage keep a public endpoint, firewalled to an explicit IP allowlist. True only in dev, where secrets must be manageable from an operator laptop outside the VNet. Production forbids it. |
| <a name="output_egress_strategy"></a> [egress\_strategy](#output\_egress\_strategy) | Either "firewall" or "nat\_gateway". Determines whether route tables carry a 0.0.0.0/0 route. |
| <a name="output_enable_alerts"></a> [enable\_alerts](#output\_enable\_alerts) | Whether metric alert rules and action groups are deployed. |
| <a name="output_enable_application_gateway"></a> [enable\_application\_gateway](#output\_enable\_application\_gateway) | Whether Application Gateway provides ingress. When false, a public load balancer does. |
| <a name="output_enable_autoscale"></a> [enable\_autoscale](#output\_enable\_autoscale) | Whether autoscale rules are attached to the scale sets. |
| <a name="output_enable_backup"></a> [enable\_backup](#output\_enable\_backup) | Whether a Recovery Services vault and backup policies are deployed. |
| <a name="output_enable_bastion"></a> [enable\_bastion](#output\_enable\_bastion) | Whether Azure Bastion is deployed. |
| <a name="output_enable_defender"></a> [enable\_defender](#output\_enable\_defender) | Whether Microsoft Defender for Cloud plans should be enabled for this environment. |
| <a name="output_enable_firewall"></a> [enable\_firewall](#output\_enable\_firewall) | Whether Azure Firewall is deployed. When false, egress is via NAT Gateway. |
| <a name="output_enable_nat_gateway"></a> [enable\_nat\_gateway](#output\_enable\_nat\_gateway) | Whether a NAT Gateway provides egress. Mutually exclusive with enable\_firewall. |
| <a name="output_enable_public_load_balancer"></a> [enable\_public\_load\_balancer](#output\_enable\_public\_load\_balancer) | Whether a public Standard load balancer provides ingress. Mutually exclusive with enable\_application\_gateway. |
| <a name="output_enable_redis"></a> [enable\_redis](#output\_enable\_redis) | Whether Azure Cache for Redis is deployed. |
| <a name="output_enable_resource_locks"></a> [enable\_resource\_locks](#output\_enable\_resource\_locks) | Whether CanNotDelete management locks are applied to stateful resources. This is the conditional substitute for `prevent_destroy`, which cannot accept a variable. See README.md. |
| <a name="output_enable_user_node_pool"></a> [enable\_user\_node\_pool](#output\_enable\_user\_node\_pool) | Whether a separate user node pool is deployed. When false, workloads share the system pool with the cluster's own components — acceptable in dev, poor practice anywhere else. |
| <a name="output_indicative_monthly_cost_usd"></a> [indicative\_monthly\_cost\_usd](#output\_indicative\_monthly\_cost\_usd) | ORDER-OF-MAGNITUDE monthly estimate in USD at approximate US list price. Excludes data processing, egress, storage capacity, transactions and any discount. A planning aid to answer 'tens, hundreds or thousands', not a budget figure — use infracost for anything financial. |
| <a name="output_ingress_strategy"></a> [ingress\_strategy](#output\_ingress\_strategy) | Either "application\_gateway" or "public\_load\_balancer". |
| <a name="output_peak_vcpus"></a> [peak\_vcpus](#output\_peak\_vcpus) | Peak vCPU footprint across all compute tiers at maximum scale. Null when the VM size is unknown to the module. Compare against `az vm list-usage` before deploying. |
| <a name="output_profile"></a> [profile](#output\_profile) | The complete resolved profile: environment defaults with overrides applied. 41 attributes covering egress, ingress, operator access, compute, data, security and observability. |
| <a name="output_quota_checked"></a> [quota\_checked](#output\_quota\_checked) | Whether the vCPU quota assertion actually ran. False means either no quota was supplied or the VM size is not in the lookup table — the plan passed without checking. |
| <a name="output_validation_id"></a> [validation\_id](#output\_validation\_id) | Identifier of the internal validation resource. Depend on this to order profile validation ahead of resource creation. |
| <a name="output_vcpus_per_instance"></a> [vcpus\_per\_instance](#output\_vcpus\_per\_instance) | vCPU count for the selected VM size, or null when the size is not in the module's lookup table. |
<!-- END_TF_DOCS -->
