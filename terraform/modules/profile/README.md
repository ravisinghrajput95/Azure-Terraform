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
