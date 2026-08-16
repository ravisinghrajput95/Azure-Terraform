# Module: `tags`

Composes and validates the governance tag map applied to every resource in the
platform. Enforces a mandatory tag set that callers cannot weaken, and rejects
tag maps that Azure would refuse at apply time.

Creates no Azure resources and declares no providers.

---

## Usage

```hcl
module "tags" {
  source = "../../modules/tags"

  workload            = "cloudcart"
  environment         = "prod"
  owner               = "platform-team@example.com"
  cost_center         = "CC-4417"
  criticality         = "high"
  data_classification = "confidential"

  additional_tags = {
    project = "checkout-rewrite"
  }
}

resource "azurerm_virtual_network" "this" {
  # ...
  tags = module.tags.tags
}

resource "azurerm_linux_virtual_machine_scale_set" "app" {
  # ...
  tags = module.tags.tier_tags["app"]   # base tags + tier = "app"
}
```

**Azure does not inherit tags from a resource group to the resources inside
it.** Every resource must carry the map explicitly. Inheritance exists only as
an Azure Policy `modify` effect, which introduces its own drift problem — see
Operational notes below.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `workload` | `string` | — | Matches the naming module's workload. |
| `environment` | `string` | — | `dev`, `test` or `prod`. |
| `owner` | `string` | — | Accountable email. Distribution list preferred over a personal address. |
| `cost_center` | `string` | — | Chargeback code. Cost Management groups on this. |
| `criticality` | `string` | — | `low`, `medium`, `high`, `mission-critical`. |
| `data_classification` | `string` | — | `public`, `internal`, `confidential`, `restricted`. |
| `additional_tags` | `map(string)` | `{}` | Merged in. Cannot override or case-collide with a mandatory tag. |
| `tiers` | `list(string)` | `["app","biz","db","pep","mgmt"]` | Tiers receiving a precomputed tag map. |
| `max_tag_key_length` | `number` | `128` | Strictest limit across resource types (storage accounts). |

## Outputs

`tags`, `tier_tags`, `mandatory_tags`, `mandatory_tag_keys`, `criticality`,
`data_classification`, `owner`, `validation_id`

---

## The mandatory set

```
workload            cloudcart
environment         prod
owner               platform-team@example.com
costCenter          CC-4417
criticality         high
dataClassification  confidential
managedBy           Terraform
```

camelCase throughout, matching the convention already used elsewhere in this
repository. Azure tag keys are case-insensitive for lookup but case-preserving
for display, so the convention has to be chosen once and held.

These seven are required with no defaults. A default would guarantee that a
meaningful share of the estate ends up tagged `unknown`, and a cost report
that cannot attribute 30% of spend is not a cost report.

---

## Design notes

**No timestamp, commit SHA or build number tags.** This is the most common
tagging anti-pattern in enterprise Terraform. A `timestamp()` tag changes on
every plan; a git SHA tag changes on every deploy. Either produces a diff on
every tagged resource in the estate — hundreds of no-op updates per plan that
bury genuine changes and make review meaningless. Deployment provenance belongs
in a deployment record or in the state's own metadata, not stamped onto every
resource. If a specific resource genuinely needs it, pass it through
`additional_tags` for that resource only.

**Mandatory tags are merged last, so they win.** `merge(var.additional_tags,
local.mandatory_tags)`. A precondition additionally *fails* the plan on an
override attempt rather than silently ignoring it, so the caller learns their
tag was dropped instead of assuming it applied.

**Case-insensitive collision detection.** `merge()` collapses exactly-equal
keys, but `Environment` and `environment` both survive it. Azure then rejects
the request with an unhelpful error. The module catches this at plan time.

**Key length validated at 128, not Azure's general 512.** Storage accounts cap
tag names at 128. Validating against the strictest limit in the platform
guarantees one tag map applies cleanly to every resource type, rather than
failing on exactly one resource late in an apply.

**`criticality`, `data_classification` and `owner` are re-exported.** Several
downstream modules size backup retention, alert severity and encryption
requirements from these. Re-exporting means they read the same value that is
actually tagged, instead of taking duplicate inputs that can drift out of step.

**All constraint failures are reported together.** A caller with three tag
problems sees all three in one plan, rather than discovering them across three
failed runs.

---

## Operational notes

**Azure Policy tag inheritance causes drift.** A policy with a `modify` effect
that inherits tags from the resource group will add tags Terraform does not
know about. The next plan then shows a diff removing them, and the policy
re-adds them — a permanent fight. Pick one owner of tags. This module assumes
Terraform owns them, so any inheritance policy should be `audit`, not `modify`.

**Changing `cost_center` or `owner` updates every resource in the environment.**
That is a large but harmless plan. Expect it, and do not let its size mask
another change hiding in the same run.

---

## Tests

```bash
terraform init -backend=false
terraform test
```

14 tests: composition, merge precedence, tier maps, Azure limit compliance, and
nine rejected-input cases including mandatory-tag override, case-only collision,
invalid key characters, empty values and oversized values.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_tags"></a> [additional\_tags](#input\_additional\_tags) | Extra tags merged into the mandatory set. May not override a mandatory tag, and may not collide with one by case alone — Azure treats tag keys as case-insensitive, so "Environment" and "environment" are a conflict, not two tags. | `map(string)` | `{}` | no |
| <a name="input_cost_center"></a> [cost\_center](#input\_cost\_center) | Chargeback code this workload bills to. Azure Cost Management groups by this tag, so an inconsistent value here silently breaks cost allocation. | `string` | n/a | yes |
| <a name="input_criticality"></a> [criticality](#input\_criticality) | Business criticality. Drives backup retention, alert routing and change-approval requirements downstream. | `string` | n/a | yes |
| <a name="input_data_classification"></a> [data\_classification](#input\_data\_classification) | Sensitivity of data handled. Determines encryption, private endpoint and audit requirements under most data-governance policies. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment. | `string` | n/a | yes |
| <a name="input_max_tag_key_length"></a> [max\_tag\_key\_length](#input\_max\_tag\_key\_length) | Maximum permitted tag key length. Defaults to 128 rather than Azure's general 512 limit because storage accounts cap tag names at 128 — validating against the strictest limit guarantees the same tag map applies cleanly to every resource type in the platform. | `number` | `128` | no |
| <a name="input_owner"></a> [owner](#input\_owner) | Email address of the team or individual accountable for these resources. Used by cost reports and by incident response to find someone at 3am, so a distribution list is preferred over a personal address. | `string` | n/a | yes |
| <a name="input_tiers"></a> [tiers](#input\_tiers) | Workload tiers for which a tier-scoped tag map is precomputed. Lets callers use module.tags.tier\_tags["app"] instead of merging a tier tag inline at every call site. | `list(string)` | <pre>[<br/>  "app",<br/>  "biz",<br/>  "db",<br/>  "pep",<br/>  "mgmt"<br/>]</pre> | no |
| <a name="input_workload"></a> [workload](#input\_workload) | Workload or application identifier. Should match the value passed to the naming module so that tags and names agree. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_criticality"></a> [criticality](#output\_criticality) | Business criticality value, for modules that size backup retention or alert severity from it. |
| <a name="output_data_classification"></a> [data\_classification](#output\_data\_classification) | Data classification value, for modules that gate encryption or audit settings on it. |
| <a name="output_mandatory_tag_keys"></a> [mandatory\_tag\_keys](#output\_mandatory\_tag\_keys) | Keys of the mandatory tag set. Feed this to a policy or compliance check that verifies tag presence across the subscription. |
| <a name="output_mandatory_tags"></a> [mandatory\_tags](#output\_mandatory\_tags) | Only the mandatory governance tags, without any additional\_tags. Useful for Azure Policy definitions that assert the required set is present. |
| <a name="output_owner"></a> [owner](#output\_owner) | Accountable owner email, for wiring into monitor action groups. |
| <a name="output_tags"></a> [tags](#output\_tags) | The composed tag map. Pass this to every resource's `tags` argument. Azure does not inherit tags from resource group to resource, so every resource must carry it explicitly. |
| <a name="output_tier_tags"></a> [tier\_tags](#output\_tier\_tags) | Map of tier to that tier's tag map, each being the base tags plus `tier = <name>`. Use module.tags.tier\_tags["app"] rather than merging a tier tag at the call site. |
| <a name="output_validation_id"></a> [validation\_id](#output\_validation\_id) | Identifier of the internal validation resource. Depend on this to order tag validation ahead of resource creation. |
<!-- END_TF_DOCS -->
