# Contributing

This repository has conventions that are load-bearing rather than stylistic.
Several exist because breaking them produced a real outage or a silent failure
that took hours to find. Those are marked.

```bash
pre-commit install     # same checks CI runs, at commit time
make check             # fmt-check, validate, test, lint
make plan ENV=dev      # needs credentials
```

---

## The rules that matter

### `count` and `for_each` must depend only on statically-known values

**This one broke five modules.** Deriving `for_each` from another resource's
attributes works on an incremental apply — the attribute is already in state —
and fails on a cold apply, where it is not yet known. The bug is invisible
until someone rebuilds from nothing.

```hcl
for_each = var.subnets                      # statically known
for_each = azurerm_subnet.this              # breaks on a cold apply
```

### `for_each` over maps, never `count`, on named resources

`count` indexes by position, so removing the second of three subnets destroys
and recreates the third. `for_each` keys by name and touches only what changed.

### Preconditions for anything that fails silently

If Azure **accepts** a configuration and then does not act on it, a
precondition is the only place to catch it. The bar is not "could this be
wrong" but "would being wrong be invisible".

Worked examples in this repo:

- `aks` — a public cluster whose nodes egress from an address its own API
  server rejects. Provisions for 15 minutes, then crash-loops the node pool
  every 14 minutes forever.
- `monitor` — an alert rule on a metric that does not exist, an aggregation the
  metric does not publish, or a dimension it does not carry. All three are
  accepted, display as healthy, and never fire.
- `recovery-services` — a retention rule naming a weekday the backup schedule
  never runs on. Retains nothing, and shows a retention duration in the portal
  that never materialises.

Error messages should say what will happen, not just what is wrong. "Azure
accepts this and the rule never fires" is more useful than "invalid metric".

### Check the provider schema before writing a resource

```bash
terraform providers schema -json | jq '...'
```

This has caught **seven** deprecated arguments so far: `enable_rbac_authorization`,
`metric`, `enable_http2`, `enable_floating_ip`, `enable_tcp_reset`,
`storage_account_name`, and `soft_delete_enabled`. Documentation lags the
provider; the schema does not.

### Verify against the Azure API, not Terraform's output

A green apply means Terraform is satisfied. It does not mean the resource
works. Two examples from this repo:

- An AKS cluster reported `Succeeded` by Terraform while its node pool
  crash-looped, because the apply had been interrupted.
- An alert rule on `cluster_autoscaler_unschedulable_pods_count` that deployed
  cleanly and returned **zero data points**, because the autoscaler was not
  running and therefore published nothing.

Query the resource. Confirm the thing you claimed actually happened.

### Say what is unverified

Do not imply coverage that does not exist. If a module ships with mocked tests
and was never applied, its README says so. If an alert has never fired, that is
recorded. Overstating verification is worse than having none, because it stops
anyone from checking.

### A shell script needs a `.sh` suffix or the executable bit

Shell is linted by ShellCheck in three places — the pre-commit hook, `make
lint-sh`, and the `ShellCheck` job in CI — all reading the same `.shellcheckrc`
so they cannot disagree about what "clean" means.

They do not discover files identically, and that is why this rule exists.
`make lint-sh` and CI find scripts by shebang as well as by extension.
pre-commit's `shell` file type does not: it is satisfied by a `.sh` suffix, or
by a shebang on a file that is **executable**, and a shebang on its own is not
enough. A script with neither the suffix nor the bit is therefore linted by CI
and skipped by the commit hook, with neither of them mentioning it — you find
out when CI fails on a file your own hook waved through, which is precisely how
people learn to stop trusting the local hook.

`make lint-sh` and CI both refuse that state rather than let the two drift. An
empty file list is a failure too: a linter reporting success over a file set it
never built is the same problem one level up.

CI pins ShellCheck and asserts the version on `PATH` before linting, because
the GitHub runner image ships an older one that would quietly enforce a weaker
check set than the commit hook.

---

## Module layout

Every module ships `versions.tf`, `variables.tf`, `locals.tf`, `main.tf`,
`outputs.tf` and `README.md`.

| File | Holds |
|---|---|
| `variables.tf` | Inputs, with `validation` on anything with a bounded domain |
| `locals.tf` | Derived values and the coherence checks preconditions assert on |
| `main.tf` | Resources, with `lifecycle { precondition }` blocks |
| `outputs.tf` | IDs consumed downstream, plus posture outputs stating degraded states in plain language |

Coherence checks live in `locals.tf` as named booleans or lists, and
`main.tf` asserts on them. This keeps the precondition readable and the logic
testable.

### Environment names appear in exactly three modules

`naming`, `tags` and `profile`. **No other module may branch on the
environment** — they receive explicit capability flags (`enable_alerts`,
`enable_backup`) instead. This is why adding `qa` and `stage` touched three
modules rather than twenty. Do not add a fourth.

---

## Tests

`terraform test` with `mock_provider`, so tests need no credentials and create
nothing.

Test the **preconditions**, not the provider. A test asserting that
`azurerm_storage_account` sets a name is testing HashiCorp's code. A test
asserting that a weekly retention rule misaligned with its schedule is rejected
is testing yours.

```hcl
run "rejects_the_thing_that_fails_silently" {
  command = plan
  variables { ... }
  expect_failures = [azurerm_thing.this]
}
```

CI discovers `terraform/modules/*/tests/`, `terraform/environments/*/tests/`
and `bootstrap/tests/` automatically. Adding a directory is all that is needed;
no workflow change.

### Environment tests are a different job from module tests

A module test proves a module honours its contract. An environment test proves
the composition wires those modules to each other correctly — that a name
derived in one place reaches every consumer, that a subnet which must not carry
a default route does not, that the profile's decision reaches the resource it
governs. Assert on what this repository decides: names, keys, counts, and
resolved profile values. Do not assert on provider-computed values — IDs, URIs,
IPs, FQDNs are random mock strings under `mock_provider`.

Two things bite when writing one:

**Pin every variable in the test file.** `terraform test` reads
`terraform.tfvars` like any other command, and that file is gitignored. A test
that leaves a variable to be filled in from it passes on your machine and fails
in CI. The first draft of `dev`'s suite asserted a `cus` name prefix while
`var.location` defaults to `eastus`, and passed only because the local tfvars
said `centralus`.

**`expect_failures` cannot name anything inside a child module.** It only
accepts checkable objects in the root module under test, and a composition root
declares no resources of its own — so the failures that matter most there
(a route to a null next hop, a footprint over quota, a cluster nobody can
authenticate to) cannot be expressed. Terraform reports ``Invalid
`expect_failures` reference`` or `Missing expected failure`. Test those in the
module that owns the precondition, and assert the positive wiring in the
environment.

---

## Commits

- No `Co-Authored-By` trailers.
- Explain **why**, not what — the diff already shows what.
- If the change fixes something subtle, describe the failure mode it prevents.
  Several commits here are the only written record of a trap.

---

## Costs

This runs on a credit-limited subscription. Before adding anything billable,
check it against the real constraints in `terraform/README.md` — 4 regional
vCPUs, `Standard_B2s` not permitted, SQL provisioning blocked in East US. The
`profile` module's `indicative_monthly_cost_usd` is an order-of-magnitude
planning aid, not a budget figure.
