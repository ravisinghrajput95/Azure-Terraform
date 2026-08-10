# Module: `naming`

Single source of truth for every resource name in the platform. Implements
Azure CAF abbreviations, normalises regions, enforces per-resource-type Azure
naming constraints, and generates deterministic suffixes for globally-unique
names.

Creates no Azure resources and declares no providers. It can be planned and
tested without credentials.

---

## Usage

```hcl
module "naming" {
  source = "../../modules/naming"

  workload    = "cloudcart"
  environment = "prod"
  location    = "East US"
  unique_seed = data.azurerm_client_config.current.subscription_id
}

resource "azurerm_virtual_network" "this" {
  name                = module.naming.names.virtual_network
  resource_group_name = module.naming.resource_group_names["net"]
  location            = module.naming.location_normalized
  # ...
}
```

Callers never build name strings. If a name is needed that this module does not
produce, add it here rather than concatenating at the call site — that is what
keeps the convention enforceable.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `workload` | `string` | — | 2–10 lowercase alphanumerics, starts with a letter. Length-capped because storage account names cap at 24. |
| `environment` | `string` | — | `dev`, `test` or `prod`. |
| `location` | `string` | — | Display name (`East US`) or internal name (`eastus`); both normalise identically. |
| `instance` | `string` | `"001"` | Three digits. Allows a parallel deployment of the same workload in one region. |
| `unique_seed` | `string` | `""` | Mixed into the global-name hash. Pass the subscription ID. |
| `resource_group_scopes` | `list(string)` | `["net","sec","data","app","mon"]` | Lifecycle scopes, one resource group each. |
| `tiers` | `list(string)` | `["app","biz","db","pep","mgmt"]` | Tiers receiving a subnet and NSG. |
| `compute_tiers` | `list(string)` | `["app","biz"]` | Subset of `tiers` that hosts compute. Must be a subset. |
| `location_abbreviations` | `map(string)` | `{}` | Merged over the built-in region table. |

## Outputs

**Segments:** `base`, `base_compact`, `abbreviations`, `location_normalized`,
`location_short`, `environment_short`, `unique_suffix`

**Name maps:** `resource_group_names`, `subnet_names`,
`network_security_group_names`, `scale_set_names`, `managed_identity_names`,
`names`

**Globally-unique:** `storage_account_name`, `key_vault_name`,
`sql_server_name`, `redis_name`

**Ordering:** `validation_id`

---

## Generated names

`workload = "cloudcart"`, `environment = "prod"`, `location = "East US"`:

```
rg-cloudcart-prod-eus-net        vnet-cloudcart-prod-eus-001
rg-cloudcart-prod-eus-sec        snet-app-prod-eus
rg-cloudcart-prod-eus-data       nsg-app-prod-eus
rg-cloudcart-prod-eus-app        rt-workload-prod-eus
rg-cloudcart-prod-eus-mon        afw-cloudcart-prod-eus-001
                                 agw-cloudcart-prod-eus-001
vmss-app-prod-eus-001            bas-cloudcart-prod-eus-001
vmss-biz-prod-eus-001            lbi-biz-prod-eus-001
id-app-prod-eus-001              log-cloudcart-prod-eus-001

stcloudcartprdeus9198            kv-cloudcart-prd-9198
sql-cloudcart-prod-eus-9198      redis-cloudcart-prod-eus-9198
```

---

## Design notes

**Full environment word in hyphenated names, 3-character form only where
length-capped.** `rg-cloudcart-prod-eus-net` reads clearly in the portal.
`stcloudcartprdeus9198` uses `prd` because storage accounts allow 24 characters,
no separators and no uppercase.

**Hash suffix, not `random_string`.** A `random_string` lives in state. If state
is lost and resources re-imported, it regenerates — renaming the storage
account, which for most Azure resources means destroy and recreate. A
`sha256`-derived suffix is a pure function of the inputs, so it is stable
forever.

**Suffix length is effectively frozen after first deploy.** Four hex characters
gives 65,536 values, scoped within a namespace already narrowed by workload,
environment and region. Widening it later renames every globally-unique
resource. Four is a deliberate trade-off, not an oversight.

**Unknown regions fail rather than falling back.** A default abbreviation would
let two regions share a prefix and generate colliding names. Extend
`location_abbreviations` instead.

**Validation lives in three places, for three reasons.**

| Mechanism | Used for | Why not the others |
|---|---|---|
| `validation` block | Single-variable constraints (`workload` charset, `instance` format) | Cannot see computed values |
| Cross-variable `validation` | `compute_tiers ⊆ tiers` | Requires Terraform ≥ 1.9 — the reason for that floor |
| `precondition` | Computed names (storage length, region known) | Variable validation cannot reach locals |

`check` blocks were rejected throughout: they warn and let the apply proceed,
but an invalid Azure resource name is a guaranteed apply failure, so the plan
should fail.

**The one `terraform_data` resource** exists solely to host preconditions. It
adds a trivial state entry and needs no provider.

---

## Tests

```bash
terraform init -backend=false
terraform test
```

15 tests, no credentials required: name composition, region normalisation
across both spellings, per-tier maps, Azure constraint compliance at the
maximum permitted workload length, suffix determinism and cross-environment
uniqueness, and six rejected-input cases.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
