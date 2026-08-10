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
<!-- END_TF_DOCS -->
