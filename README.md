# Azure-Terraform

Multi-environment Azure platform in Terraform: a three-tier application
topology on AKS, behind a WAF, with every data service reachable only through
private endpoints, controlled egress, and no public IP on any compute resource.

Four environments — `dev`, `qa`, `stage`, `prod` — built from 22 shared modules
and differentiated by variables rather than by code.

> ### Status: nothing is currently deployed
>
> `dev` was built, verified against the live Azure API, and **decommissioned on
> 2026-08-14** to stop spend. `qa`, `stage` and `prod` are complete, validate
> and plan, and **have never been applied** — the subscription cannot hold
> them.
>
> | Env | State | Why not running |
> |---|---|---|
> | `dev` | Was deployed and verified; destroyed | ~$212/month against a $200 credit |
> | `qa` | Plans, 146 resources | Needs 6 vCPU steady; regional limit is **4** |
> | `stage` | Plans, 143 resources | 10 vCPU steady, ~$2,148/month |
> | `prod` | Plans, 146 resources | 24 vCPU steady, ~$3,242/month |
>
> Each README states plainly which of its claims are observations and which are
> claims about a plan. That distinction is the point of this repository.

---

## The platform

One shape across all four environments, differentiated by variables rather
than by code. Labels carry the environments each component applies to.

![Canonical architecture — one shape across dev, qa, stage and prod. Users reach an Application Gateway WAF v2 (absent in dev) which fronts an AKS cluster on Azure CNI Overlay. Data services are reached only through private endpoints. Egress takes one of two paths chosen per environment: a NAT Gateway for dev and qa, uninspected; or an Azure Firewall for stage and prod, inspected with IDPS on prod.](docs/images/architecture.svg)

Two rows change the **topology** rather than a setting, which is why the
diagram branches at `EGRESS`:

| | `dev` | `qa` | `stage` | `prod` |
|---|---|---|---|---|
| **Egress** | NAT Gateway | NAT Gateway | **Firewall Standard** | **Firewall Premium + IDPS** |
| **Ingress** | **none** | AppGW, WAF *Detection* | AppGW, WAF *Prevention* | AppGW, WAF *Prevention* |
| API server | **public**, allowlisted | private | private | private |
| Data planes | **public**, IP-restricted | private only | private only | private only |
| Log ingestion | **capped 0.5 GB/day** | uncapped | uncapped | uncapped |
| Purge protection / locks | off | off | off | **on — irreversible** |

`dev` is the outlier on four of those rows — the only environment with no
ingress, a public API server and a public data plane. It is also the only
one that has ever run.

The full matrix, the abandoned original design, and a diagram of `dev`
exactly as it was built are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §3.

---

## What is actually interesting here

Not the resource count. This platform is built around a single idea:

**In Azure, the dangerous failures are the ones that succeed.**

A metric alert on a metric that does not exist is *accepted*. A firewall rule
that can never match is *accepted*. A cluster-admin binding that matches nobody
provisions cleanly and reports healthy. In every case Terraform is green, the
portal is green, and the control does nothing — and you find out during the
incident it was supposed to catch.

So every module carries `precondition` blocks for exactly one class of problem:
**configuration Azure accepts and then does not act on.** The bar is not "could
this be wrong" but "would being wrong be invisible".

### Real examples, all found by querying Azure rather than trusting Terraform

| Found | What was actually happening |
|---|---|
| Cluster admin bound to nobody | A *user* object ID sat in `aks_admin_group_object_ids`, which AKS binds as a Kubernetes **group** subject. Valid GUID, accepted, matched nothing. With local accounts disabled, **no one could reach the cluster** |
| Alert with zero data points | A rule on `cluster_autoscaler_unschedulable_pods_count` deployed cleanly — the autoscaler was off, so the metric was never published |
| Documented query matched nothing | Microsoft's own daily-cap query filters on `Operation`, which holds a **GUID** on this workspace. It returned 0 rows on a day the cap was genuinely hit; the replacement returned 1 |
| Telemetry silently lost every day | `kube-audit` was **995 MB/day against a 512 MB/day cap** — the workspace hit the cap daily and dropped everything after, blinding every alert at once |
| Redis unreachable by design | The private-endpoint NSG allowed `6380` — Azure *Cache* for Redis. This platform runs Azure **Managed** Redis, on `10000`. Every pod→Redis call would have hit the deny |
| A cluster that crash-looped forever | Nodes egressed from a NAT Gateway address its own API server allowlist did not contain. `vmssCSE` timed out and AKS recreated the node every ~14 minutes, indefinitely |
| State readable without RBAC | An 88-character shared key enumerated every environment's state, bypassing RBAC and attributable to nobody |

Each is now a precondition, a test, or both — and each is written up where the
decision lives, not only here.

---

## Layout

```
docs/                architecture, networking and deployment documentation
scripts/             four checks that answer what terraform plan cannot
bootstrap/           Phase 0 — the state backend, on local state by necessity
terraform/
├── environments/    one root module per environment (dev, qa, stage, prod)
└── modules/         22 reusable modules
Makefile             every check CI runs, plus plan/apply per environment
```

**Start here:** [`terraform/README.md`](terraform/README.md)

```bash
pre-commit install      # the CI checks, at commit time
make check              # fmt-check, validate, test, lint
make plan ENV=dev       # needs credentials
```

**356 tests** run with `mock_provider` — no credentials, no backend, nothing
created. They test the preconditions, not the provider: a test asserting that
`azurerm_storage_account` sets a name is testing HashiCorp's code.

**289 module tests** check each module against its own contract. **10 bootstrap
tests** cover Phase 0, the state backend — the one configuration that is
actually deployed and the only one on local state, where a mistake is not
recoverable by reading state back, because the account is what holds the state.
**57 environment tests** check the composition — that a name
derived in one place reaches every consumer, that a subnet which must not carry
a default route does not, that the profile's decision reaches the resource it
governs. That layer is invisible to a module test, and for `qa`, `stage` and
`prod` it is the only verification available at all: none of the three can be
applied on this subscription, so a mocked plan is the whole of it. `stage`'s
suite is the only thing that executes the Azure Firewall egress path anywhere.

The environment tests also cover the **NSG rule matrices** — 1,472 lines that
are the security policy of the platform and had no test of their own. They
assert reach rather than verdict: which source is admitted to which port, since
"Allow 443 inbound" reads identically whether the source is one subnet or the
whole internet. The tier boundary, SSH arriving only via Bastion, and the
private-endpoint data ports are each pinned — that last one is the rule that
named port 6380 for months while the platform's Managed Redis listens on 10000,
silently refusing every call from a pod to the cache.

What they do not prove is that Azure accepts the plan. A mocked plan shows the
configuration is internally coherent, not that the API agrees.

**Every configuration in the repository now has tests — 22 modules, 4
environments and the bootstrap — and the module
coverage was measured rather than asserted.** Every precondition in the
repository was weakened to an always-true expression in turn, with the suite
re-run each time, to check that some test actually fails when it stops
guarding. **105 of 110 are confirmed that way. The other 5 cannot fire at
all**, and each is written up in its own test file:

| Precondition | Why it can never fire |
|---|---|
| `bastion`, `load-balancer` — public IP name | The public IP resource rejects a null `name` first, so Terraform stops before preconditions are evaluated |
| `monitor` — cap warning window | The variable is validated to `P1D` or `P2D`, 1440 and 2880 minutes. Every permitted value already clears the 1440 bar |
| `naming` — generated name constraints | The upstream validations bound every input, so no constructible input produces an invalid name |
| `recovery-services` — file share retention alignment | `azurerm_backup_policy_file_share` accepts `Daily` or `Hourly` only; the provider refuses `Weekly`, so there is no weekly schedule to misalign against |

None is a missing test. Each is a guard made redundant by a stricter check
earlier in the chain — worth keeping, worth not counting as coverage.

The environment suites are not measured the same way, and cannot be. A
composition root declares no resources, so it has no preconditions of its own
to weaken — and `expect_failures` only accepts checkable objects in the root
module under test, which means a failure raised inside a child module cannot be
named from an environment test at all. Those failure modes are tested in the
module that owns them; the environment tests assert the positive wiring.

Writing the tests found five real defects, four of one kind: expressions
relying on `&&` and `||` to short-circuit, which Terraform 1.9.8 does not do.
Most were invisible to `terraform validate`, which does not evaluate those
paths, and to every environment plan, which needs credentials this repository
does not have.

| Document | Contents |
|---|---|
| [`scripts/README.md`](scripts/README.md) | Preflight, ingestion, cluster access and drift checks — each one exists because its absence caused a real failure |
| [`LICENSE`](LICENSE) | MIT |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Conventions that are load-bearing rather than stylistic, and the failures behind them |
| [`SECURITY.md`](SECURITY.md) | Security posture, and the weaknesses deliberately accepted |
| [`bootstrap/README.md`](bootstrap/README.md) | Why the backend runs on local state, and how it was adopted by import |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Design decisions and rejected alternatives, as-designed and as-built diagrams, Zero Trust mapping, cost |
| [`docs/NETWORKING.md`](docs/NETWORKING.md) | CIDR allocation, subnet plan, NSG rule matrix, routing, private DNS, CAF naming |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Module dependency graph, deployment phases, gates, rollback characteristics |

---

## Standards

| Area | Standard |
|---|---|
| Provider | `azurerm ~> 4.0`, exact patch locked in a committed `.terraform.lock.hcl` |
| Terraform | `>= 1.9` |
| Naming | Azure CAF abbreviations via the `naming` module — no literal resource names in calling code |
| Tagging | Mandatory governance tags enforced by validation |
| Iteration | `for_each` over maps, never `count` on named resources; keys statically known |
| Secrets | None in code or state — managed identity and Entra ID authentication throughout |
| State | Remote `azurerm` backend, one state file per environment, Entra auth, shared keys disabled |
| Frameworks | Azure Well-Architected Framework, Azure CAF, HashiCorp Style Guide |

Environment names appear in exactly **three** modules — `naming`, `tags` and
`profile`. Every other module takes capability flags, which is why adding `qa`
and `stage` touched three modules rather than twenty.

---

## The subscription shaped the design

This ran on an Azure FreeTrial subscription with the spending limit on. Three
constraints changed real decisions rather than being worked around:

| Constraint | Consequence |
|---|---|
| Azure SQL provisioning **blocked in East US** | The whole platform moved to Central US, after probing seven regions with throwaway servers. ARCHITECTURE.md §6a |
| **4 total regional vCPUs**, not raisable on FreeTrial | dev's cluster is a single node and explicitly not HA. Three nodes across three zones is 6 vCPU. It also blocks `qa`, `stage` and `prod` outright |
| Azure Firewall is ~$913/month | `dev` and `qa` egress through a NAT Gateway (~$35) with **no filtering at all**, which is stated rather than glossed. ARCHITECTURE.md §6c |

The interesting part is not that the constraints existed. It is that verifying
a service can be provisioned *for this subscription in this region* before
building on it turned a 28-resource rebuild into a one-line change.

---

## License

[MIT](LICENSE). Use it, fork it, ship it.

The Terraform is reusable; the **numbers are not**. Every quota, price and
measurement here was taken from one FreeTrial subscription in Central US on
2026-08-14. Costs change, quotas differ per subscription, and regional service
restrictions are invisible until an apply fails — which is the whole point of
§6a. Re-measure against your own subscription before relying on any of it.
