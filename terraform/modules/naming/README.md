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
| <a name="input_compute_tiers"></a> [compute\_tiers](#input\_compute\_tiers) | Subset of var.tiers that actually host compute and therefore need scale set and managed identity names. Kept separate so the module does not emit names for combinations that never exist (there is no scale set in the private endpoint subnet). Must be a subset of var.tiers. | `list(string)` | <pre>[<br/>  "app",<br/>  "biz"<br/>]</pre> | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment. Drives both the name segment and the environment profile selected downstream. | `string` | n/a | yes |
| <a name="input_instance"></a> [instance](#input\_instance) | Three-digit instance number, allowing a second parallel deployment of the same workload in the same region without a name collision. | `string` | `"001"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region. Accepts either the display name ('East US') or the internal name ('eastus'); both normalise to the same abbreviation. | `string` | n/a | yes |
| <a name="input_location_abbreviations"></a> [location\_abbreviations](#input\_location\_abbreviations) | Override or extend the built-in region abbreviation table. Merged over the defaults, so supplying a single new region does not require restating the whole map. Keys must be normalised region names (lowercase, no spaces). | `map(string)` | `{}` | no |
| <a name="input_resource_group_scopes"></a> [resource\_group\_scopes](#input\_resource\_group\_scopes) | Lifecycle scopes that each receive their own resource group. See docs/ARCHITECTURE.md section 1.2 — resource groups are the unit of RBAC and deletion blast radius, so compute and network edge are deliberately separated. | `list(string)` | <pre>[<br/>  "net",<br/>  "sec",<br/>  "data",<br/>  "app",<br/>  "mon"<br/>]</pre> | no |
| <a name="input_tiers"></a> [tiers](#input\_tiers) | Workload tiers that receive their own subnet, NSG and (where applicable) scale set. Names are precomputed for each tier so callers never concatenate strings themselves. | `list(string)` | <pre>[<br/>  "app",<br/>  "biz",<br/>  "db",<br/>  "pep",<br/>  "mgmt"<br/>]</pre> | no |
| <a name="input_unique_seed"></a> [unique\_seed](#input\_unique\_seed) | Seed mixed into the hash suffix applied to globally-unique resource names (storage, Key Vault, SQL, Redis). Pass the subscription ID so the same workload deployed in a different subscription or tenant produces different global names. Leaving this empty still yields deterministic names, but two tenants deploying identical inputs would collide. | `string` | `""` | no |
| <a name="input_workload"></a> [workload](#input\_workload) | Short workload or application identifier. Appears in every resource name, so it is length-constrained to keep globally-unique names (storage accounts cap at 24 characters) within their limits. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_abbreviations"></a> [abbreviations](#output\_abbreviations) | Azure CAF resource type abbreviation table. Reference this instead of typing prefixes inline. |
| <a name="output_base"></a> [base](#output\_base) | Hyphenated name base shared by most resources, e.g. "cloudcart-prod-eus". |
| <a name="output_base_compact"></a> [base\_compact](#output\_base\_compact) | Separator-free name base for resources that reject hyphens, e.g. "cloudcartprdeus". |
| <a name="output_environment_short"></a> [environment\_short](#output\_environment\_short) | Three-character environment abbreviation, e.g. "prd". |
| <a name="output_key_vault_name"></a> [key\_vault\_name](#output\_key\_vault\_name) | Key Vault name, 3-24 characters. |
| <a name="output_location_normalized"></a> [location\_normalized](#output\_location\_normalized) | Region normalised to Azure's internal form, e.g. "eastus". Pass this to resources rather than the raw input so that "East US" and "eastus" cannot produce two different values in state. |
| <a name="output_location_short"></a> [location\_short](#output\_location\_short) | Region abbreviation used in names, e.g. "eus". |
| <a name="output_managed_identity_names"></a> [managed\_identity\_names](#output\_managed\_identity\_names) | Map of tier to user-assigned managed identity name. |
| <a name="output_names"></a> [names](#output\_names) | Map of resource key to name for all remaining platform resources (virtual\_network, firewall, bastion, application\_gateway, log\_analytics\_workspace, and so on). |
| <a name="output_network_security_group_names"></a> [network\_security\_group\_names](#output\_network\_security\_group\_names) | Map of tier to network security group name. |
| <a name="output_redis_name"></a> [redis\_name](#output\_redis\_name) | Azure Cache for Redis name. |
| <a name="output_resource_group_names"></a> [resource\_group\_names](#output\_resource\_group\_names) | Map of lifecycle scope to resource group name, e.g. { net = "rg-cloudcart-prod-eus-net", ... }. |
| <a name="output_scale_set_names"></a> [scale\_set\_names](#output\_scale\_set\_names) | Map of tier to virtual machine scale set name. |
| <a name="output_sql_server_name"></a> [sql\_server\_name](#output\_sql\_server\_name) | Azure SQL logical server name. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Storage account name, 3-24 lowercase alphanumerics. |
| <a name="output_subnet_names"></a> [subnet\_names](#output\_subnet\_names) | Map of tier to subnet name. Reserved Azure subnet names (AzureFirewallSubnet, AzureBastionSubnet, GatewaySubnet) are NOT produced here — they are fixed by the platform and are emitted as literals by the networking module. |
| <a name="output_unique_suffix"></a> [unique\_suffix](#output\_unique\_suffix) | Deterministic 4-character hash suffix applied to globally-unique names. |
| <a name="output_validation_id"></a> [validation\_id](#output\_validation\_id) | Identifier of the internal validation resource. Depend on this to order name checking ahead of resource creation. |
<!-- END_TF_DOCS -->
