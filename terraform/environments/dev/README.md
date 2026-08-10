# Environment: `dev`

Free-tier-safe development environment. This is the **only** environment
deployable on the current subscription.

---

## Subscription constraints

Verified against the target subscription, not assumed:

| Property | Value | Consequence |
|---|---|---|
| Offer | `FreeTrial_2014-09-01` | Quota increases **cannot** be requested. Upgrading to Pay-As-You-Go is a prerequisite, and preserves remaining credit. |
| Spending limit | `On` | At credit exhaustion the subscription is **disabled**, not billed. Resources stop; they are not deleted. |
| Total Regional vCPUs | **4** | Hard ceiling on all compute across every tier. |
| Standard BS Family vCPUs | 4 | The only family with usable headroom. |
| Low-priority (Spot) vCPUs | 3 | Non-zero, but Spot is still disabled in the profile — eviction in a dev loop wastes more time than it saves. |

The dev profile's peak footprint is **2 vCPUs** (1 × `Standard_B1s` × 2 compute
tiers), leaving headroom for a rolling upgrade. The `profile` module asserts
this against `subscription_vcpu_quota` and fails the plan if an override would
exceed it.

---

## Usage

```bash
terraform init -backend-config=backend.conf
terraform plan  -out=tfplan
terraform apply tfplan
```

Teardown, which matters on a credit-limited subscription:

```bash
terraform destroy
```

Locks are off in dev precisely so this works. **Destroy between working
sessions** — that habit controls cost more than any SKU choice.

---

## Configuration files

| File | Committed | Purpose |
|---|---|---|
| `backend.conf` | No | State storage account, container, key. |
| `terraform.tfvars` | No | Subscription ID and governance values. |
| `backend.conf.example` | Yes | Template. |
| `terraform.tfvars.example` | Yes | Template. |
| `.terraform.lock.hcl` | Yes | Provider version lock — commit it. |

Both live files are gitignored.

---

## Authentication

Azure CLI (`az login`). There is deliberately **no** service principal secret:
a client secret in a tfvars file is a static credential in plaintext on disk
and in shell history. For CI, use workload identity federation (OIDC).

State access uses `use_azuread_auth = true`, so the backend authenticates with
the caller's Entra identity rather than a storage account key. The deploying
identity needs **Storage Blob Data Contributor** on the state container.

---

## What is deployed

| Phase | Module | Status |
|---|---|---|
| 1 | `naming`, `tags`, `profile` | Applied — no Azure resources, pure computation |
| 1 | `resource-group` | **Applied** — 5 resource groups |
| 1 | `log-analytics` | Not built |
| 1 | `diagnostics` | Not built |
| 2 | `networking`, `nsg`, `route-table`, `private-dns`, `bastion` | Not built |
| 3 | `managed-identity`, `key-vault`, `storage` | Not built |
| 4 | `sql`, `redis` | Not built |
| 5 | `load-balancer`, `application-gateway`, `vm`, `autoscale` | Not built |
| 6 | `recovery-services`, `monitor` | Not built |

Current running cost: **effectively zero**. Resource groups carry no charge,
and the state storage account holds a few kilobytes.

---

## Resolved profile

`terraform output` surfaces what the profile actually decided:

```
egress_strategy             = "nat_gateway"
ingress_strategy            = "public_load_balancer"
peak_vcpus                  = 2
quota_checked               = true
indicative_monthly_cost_usd = 155
```

The cost figure is order-of-magnitude at US list price for the **full** dev
stack once every module is built — not the current spend. It excludes data
processing, egress and transactions. Use infracost for anything financial.
