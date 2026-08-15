# scripts

Four checks. Each one exists because its absence caused a real failure in this
repository, and each one answers a question `terraform plan` cannot.

They are read-only apart from `preflight.sh --probe-sql`, which creates and
immediately deletes a throwaway SQL server. None of them applies anything.

| Script | Answers |
|---|---|
| [`preflight.sh`](preflight.sh) | Can this subscription actually host this environment? |
| [`check-ingestion.sh`](check-ingestion.sh) | How close is a workspace to its daily cap, and has it been hit? |
| [`verify-aks-access.sh`](verify-aks-access.sh) | Can anyone actually reach the cluster? |
| [`drift.sh`](drift.sh) | Does Azure still match the code, per environment? |

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

## Notes

Every script was **run against the live subscription** before being committed,
which is the only reason they work. Doing so found four defects that reading
them would not have: `az account show` silently returns no `subscriptionPolicies`
(the quota id lives on the ARM subscription endpoint), Terraform's coloured
output breaks any anchored `grep` so `drift.sh` needs `-no-color`, and both
Azure-querying scripts emitted a raw `ResourceGroupNotFound` instead of saying
the environment simply is not deployed.

No script contains a subscription ID, storage account name or resource group
name. All of those are arguments.
