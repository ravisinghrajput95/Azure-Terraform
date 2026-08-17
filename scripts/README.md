# scripts

Five checks. Each one exists because its absence caused a real failure in this
repository, and each one answers a question `terraform plan` cannot.

They are read-only apart from `preflight.sh --probe-sql`, which creates and
immediately deletes a throwaway SQL server. None of them applies anything.

| Script | Answers |
|---|---|
| [`preflight.sh`](preflight.sh) | Can this subscription actually host this environment? |
| [`check-ingestion.sh`](check-ingestion.sh) | How close is a workspace to its daily cap, and has it been hit? |
| [`verify-aks-access.sh`](verify-aks-access.sh) | Can anyone actually reach the cluster? |
| [`drift.sh`](drift.sh) | Does Azure still match the code, per environment? |
| [`check-environment-conformance.py`](check-environment-conformance.py) | Do the four environments still agree where they must? |

The first four need Azure credentials. The last does not — it reads `.tf` files
and runs in CI on every push.

---

## `preflight.sh`

```bash
scripts/preflight.sh centralus --required-vcpu 6 --vm-size Standard_D2s_v5 --probe-sql
```

Checks the quota id and spending limit, the regional vCPU headroom, whether a
VM size is restricted, and — optionally — whether Azure SQL can be provisioned
at all.

**Why the SQL check provisions something.** There is no API that reports a
subscription-level regional restriction. ARCHITECTURE.md §6a exists because
Azure SQL turned out to be blocked in East US *for this subscription*, which is
invisible in the documentation and surfaced only when an apply failed at module
15. The only reliable check is attempting a create, so `--probe-sql` makes a
throwaway logical server and deletes it. It is free and takes under a minute.

Published regional availability is necessary and **not sufficient**.

## `check-ingestion.sh`

```bash
scripts/check-ingestion.sh rg-cloudcart-dev-cus-mon log-cloudcart-dev-cus-001
```

**The query is not the one Microsoft documents, deliberately.** The documented
cap query filters on `Operation =~ "Data collection Status"`. On this
platform's workspace that column holds a GUID. Both were run against a real
`OverQuota` record on 2026-08-14: the documented query matched **0** rows, the
one used here matched **1**. A rule built the documented way is accepted,
passes query validation, displays as healthy, and never fires.

Three further things it gets right because they were measured, not assumed:

- The cap period starts at the **reset hour**, read from
  `quotaNextResetTime` — not midnight, and not `ago(24h)`. This platform's
  workspace reset at 11:00 UTC.
- It filters on **`EndTime`**, not `TimeGenerated`. `EndTime` is the usage
  period the quantity belongs to; `TimeGenerated` is when the row was written,
  and they diverge under ingestion latency — exactly when the number matters.
- A GB is **1024** MB. Dividing by 1000 reports ~2.4% low, enough to push an
  80% warning past the cap it exists to precede.

## `verify-aks-access.sh`

```bash
scripts/verify-aks-access.sh rg-cloudcart-dev-cus-app aks-cloudcart-dev-cus-001
```

This platform once shipped a cluster **nobody could enter**, with every tool
reporting it healthy. `entra_admin_group_object_ids` held a *user* object ID,
which AKS binds as a Kubernetes **group** subject matched against the token's
`groups` claim — where a user's own object ID never appears. Local accounts
were disabled, so there was no fallback, and Owner and Contributor carry
`dataActions: []`, so full control of the subscription grants no `kubectl`
access whatsoever.

The script checks the data-plane role assignment, converts the kubeconfig with
`kubelogin -l azurecli` so it reuses the existing session instead of blocking
on a device-code prompt, prints `kubectl auth whoami` so the group claim is
visible, and then tests **concrete verbs**.

It deliberately does not use `kubectl auth can-i --list`. Azure RBAC is a
webhook authorizer and cannot enumerate its own rules, so that list comes back
looking almost empty even for a full cluster admin — and people read it as a
denial.

## `drift.sh`

```bash
scripts/drift.sh            # every configured environment
scripts/drift.sh dev qa     # named ones
```

Runs `terraform plan -detailed-exitcode` per environment and distinguishes four
outcomes, because they mean different things:

| Result | Meaning |
|---|---|
| **no drift** | Azure matches the code |
| **not deployed** | Many creates, no destroys — never applied, or decommissioned. **Not drift** |
| **CHANGES PENDING** | Real divergence. Someone changed something outside Terraform |
| **rejected by a precondition** | The configuration is refused before any Azure call, with the reason |

That last row matters here: `qa`, `stage` and `prod` are all rejected by the
`profile` module's vCPU guardrail, and reporting that as "plan failed" would
hide a deliberate, informative refusal behind a generic error.

Skips any environment with no `backend.conf` or `terraform.tfvars`, since both
are gitignored and machine-specific.

---

## `check-environment-conformance.py`

```bash
make conformance                              # or:
python3 scripts/check-environment-conformance.py
```

The environments are near-copies of each other by design — the same modules
composed with different values. That is what makes adding one cheap, and it is
also why they drift. Every copy-paste defect found in this repository was found
by a person reading two files side by side, which does not scale and does not
run in CI.

Three of those defects had reached a `description`, which is a real attribute
on `azurerm_network_security_rule`, not a comment: prod's NSG would have
documented itself in the Azure portal as qa's ingress path.

It checks three mechanical properties, and deliberately not a fourth:

| Check | Catches |
|---|---|
| No `description` names a different environment without naming its own | "Empty in dev by design" sitting in `prod/outputs.tf` |
| Variables that must share a default do | `dev` said `location = "eastus"` while its three siblings said `centralus` — and dev is the only environment ever deployed |
| The environments declare the same variable set | A variable added to one and forgotten in the others |

It does **not** judge whether prose is true; nothing mechanical can. A
deliberate contrast — "which is dev's and qa's posture" — is allowed by putting
`# conformance:cross-env-ok` on the line above, so an exception is a decision
someone wrote down next to the text rather than a rule quietly relaxed
somewhere else.

Both quoted and heredoc descriptions are read. That is not incidental: the
`subscription_vcpu_quota` descriptions that claimed qa's vCPU figure inside
`stage` and `prod` were heredocs, so a check reading only quoted strings would
have missed the defect that motivated writing this.

---

## Linting

These scripts are the checks that answer what `terraform plan` cannot, so a
defect in one of them is a defect in the verification itself. They are linted
by ShellCheck in three places, all reading the same `.shellcheckrc` at the
repository root:

| Where | Command |
|---|---|
| Commit time | `pre-commit install`, then automatically |
| Locally | `make lint-sh`, or `make lint` for Terraform and shell together |
| CI | the `ShellCheck` job in `.github/workflows/terraform-ci.yml` |

No call site passes check-selection flags. They all read `.shellcheckrc`,
because a linter whose local and CI configurations differ is worse than no
linter: a developer whose commit was green and whose CI is red learns to
distrust the local one and stops running it. For the same reason CI pins
ShellCheck 0.11.0 and asserts the version on `PATH` before linting — the GitHub
runner image ships 0.9.0, which would silently enforce a weaker check set than
the commit hook.

`.shellcheckrc` enables four optional checks beyond ShellCheck's defaults and
records, in the file, why the opinionated ones are left off and why
`check-extra-masked-returns` is tracked separately rather than suppressed.

**If you add a script, give it a `.sh` suffix or `chmod +x` it.** This is not
cosmetic. `make lint-sh` and CI discover scripts by shebang as well as by
extension, but pre-commit's `shell` file type is satisfied only by a `.sh`
suffix or by a shebang on an *executable* file — a shebang on its own is not
enough. A script with neither would be linted by CI and skipped by the commit
hook without either of them saying so, so `make lint-sh` and CI both refuse
that state outright rather than let the two quietly disagree.

---

## Notes

Every script was **run against the live subscription** before being committed,
which is the only reason they work. Doing so found four defects that reading
them would not have: `az account show` silently returns no `subscriptionPolicies`
(the quota id lives on the ARM subscription endpoint), Terraform's coloured
output breaks any anchored `grep` so `drift.sh` needs `-no-color`, and both
Azure-querying scripts emitted a raw `ResourceGroupNotFound` instead of saying
the environment simply is not deployed.

Two more were found later, on 2026-08-15, by running `preflight.sh` against a
stubbed `az` with pieces of the environment removed. Both had the same shape —
**a query that did not run, reported as a finding about Azure**:

- With `openssl` absent, the SQL probe built an empty admin password. Azure
  refused the create for complexity and the script reported *"Azure SQL
  provisioning is RESTRICTED in this region"* — the exact signal
  ARCHITECTURE.md §6a moved the whole platform on. `set -e` did not catch it
  because the command substitution sat inside an `if` condition, where `set -e`
  is suspended.
- When `az vm list-usage` failed, a `|| echo "0 0"` fallback reported *"only 0
  vCPU available"*, a hard blocker, for what was really a mistyped region or an
  expired login.

Both now say that the check did not run and that this is not a statement about
Azure. ShellCheck's `check-extra-masked-returns` is enabled in `.shellcheckrc`
to keep the class from coming back.

No script contains a subscription ID, storage account name or resource group
name. All of those are arguments.
