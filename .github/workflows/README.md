# CI/CD

Two workflows. Neither applies anything — this pipeline validates, lints,
scans, prices, documents and detects drift. Applies remain a deliberate human
action.

| Workflow | Trigger | Purpose |
|---|---|---|
| [`terraform-ci.yml`](terraform-ci.yml) | PR, push to main | fmt, validate, unit tests, TFLint, Trivy + Checkov, terraform-docs, Infracost, plan |
| [`terraform-drift.yml`](terraform-drift.yml) | **Manual only** — the daily schedule is commented out | Read-only plan per environment; opens/updates a GitHub issue on drift |

---

## Authentication: OIDC, not a stored secret

Both workflows authenticate with **workload identity federation**. GitHub mints
a short-lived token per run and Azure validates it against a federated
credential scoped to this repository.

There is **no service principal secret in repository secrets** — nothing to
leak, nothing to rotate, and nothing that keeps working if the repository is
compromised.

### One-time setup

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
APP_NAME="github-cloudcart-terraform"
REPO="ravisinghrajput95/Azure-Terraform"

# 1. App registration and service principal
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID"
OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# 2. Federated credentials — one per trigger context.
#    A pull_request credential does NOT cover pushes to main, and a branch
#    credential does not cover the scheduled drift run. Missing one produces
#    an authentication failure that looks like a permissions problem.
for SUBJECT in \
  "repo:${REPO}:pull_request" \
  "repo:${REPO}:ref:refs/heads/main"
do
  NAME=$(echo "$SUBJECT" | tr ':/' '--')
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${NAME}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done

# 3. Roles.
#    Reader is enough to PLAN. Contributor is only needed if this identity will
#    also apply — grant the narrower role until that is actually true.
az role assignment create --assignee "$OBJECT_ID" \
  --role Reader --scope "/subscriptions/${SUBSCRIPTION_ID}"

# 4. State access. The backend uses Entra authentication, not account keys,
#    so a data-plane role is required — Reader on the subscription does NOT
#    grant it.
STATE_SA_ID=$(az storage account show \
  -n <state-storage-account> -g <state-resource-group> --query id -o tsv)
az role assignment create --assignee "$OBJECT_ID" \
  --role "Storage Blob Data Contributor" --scope "$STATE_SA_ID"

echo "AZURE_CLIENT_ID:       $APP_ID"
echo "AZURE_TENANT_ID:       $(az account show --query tenantId -o tsv)"
echo "AZURE_SUBSCRIPTION_ID: $SUBSCRIPTION_ID"
```

### Repository configuration

**Variables** (Settings → Secrets and variables → Actions → Variables). These
are identifiers, not secrets — a client ID is public information under OIDC.

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |
| `TFSTATE_RESOURCE_GROUP` | Resource group holding the state account |
| `TFSTATE_STORAGE_ACCOUNT` | State storage account name |

**Secrets**

| Secret | Required | Purpose |
|---|---|---|
| `INFRACOST_API_KEY` | Optional | Cost estimation. The job self-skips when absent, so forks still work. |

---

## What each job protects against

**`fmt` / `validate`** — runs with `-backend=false`, so it needs no credentials
and gives the fastest signal. Validates every module and environment
independently.

**`test`** — `terraform test` against every module, every environment and the
bootstrap: anything with a `tests/` directory. Each test file declares
`mock_provider`, so the whole job runs with no credentials, no backend and no
resource created; it needs no Azure secrets and works on forks.

The environment suites are the ones worth knowing about. Module tests check a
module against its own contract; the environment suites check the wiring
between modules — that the value one emits is the value the next needs, and
that the profile's decisions reach the resources they govern. For qa, stage and
prod that is the only verification there is, since none of the three can be
applied on the current subscription.

The bootstrap suite is the inverse case: Phase 0 is the one configuration that
is deployed, and the only one on local state. Its resources are declared in the
root module rather than composed from modules, so unlike an environment suite
it can name them in `expect_failures` and test its preconditions in place.

**`shellcheck`** — lints every shell script, then runs
`scripts/tests/test-scripts.sh`, which asserts the invariants that stop a
silent no-op passing for a pass: `set -euo pipefail`, a shebang, and the
executable bit that decides whether the pre-commit hook lints a file or skips
it. Both refuse to report success over an empty file set.

**`tflint`** — catches what `validate` cannot. `validate` checks syntax and
types against the provider schema; it does not know that a VM size might not
exist, that a variable is declared and never used, or that a name breaks an
Azure length limit. The azurerm ruleset validates SKU and VM size names, which
converts a twenty-minutes-into-an-apply failure into a lint error.

**`security-scan`** — Trivy and Checkov. They overlap but not completely: Trivy
is faster and catches provider-level misconfiguration, Checkov has deeper
Azure-specific policy coverage. Results upload as SARIF so findings appear
inline on the PR rather than buried in a log.

The build blocks only on **CRITICAL**. Everything below is reported for triage.
A scanner that fails the build on every advisory gets muted, and a muted
scanner protects nothing.

**`docs`** — terraform-docs regenerates the input and output tables inside each
module README, between `BEGIN_TF_DOCS` markers. The prose around them is
hand-written and untouched. On a PR this **fails** rather than auto-committing:
a commit from CI re-triggers the workflow and muddies the history.

**`cost`** — Infracost prices the plan and comments the delta. It answers "what
does this change cost", which is otherwise discovered on next month's bill.

**`plan`** — the only job needing Azure. A plan is read-only but takes a state
**lock**, which is why both workflows use concurrency groups: two runs against
one environment otherwise deadlock.

---

## Drift detection

**The daily schedule is currently commented out.** `dev` was decommissioned on
2026-08-14, `qa`, `stage` and `prod` have never been applied, and no OIDC
variables are configured — so every 06:00 run failed at `azure/login` and said
nothing about drift. This workflow's own rule is that a scheduled job failing
against a nonexistent environment trains people to ignore it, and that is what
it had become. Re-enable the `cron` in `terraform-drift.yml` once an
environment is deployed and the variables below are set.

When enabled, it runs daily and opens a GitHub issue when reality has diverged.

Drift matters because it is usually evidence of something else — a portal
change made during an incident and never brought back into code, an Azure
Policy mutating a property, or a service changing a default. Each is worth
knowing about within a day rather than at the next apply, when the plan
proposes to silently undo it.

Three design choices keep the signal trustworthy:

- **One issue per environment, updated rather than duplicated.** A job that
  opens a new issue every morning gets filtered to trash within a week.
- **The issue closes automatically when the plan comes back clean.** An issue
  that stays open after the fix teaches people to ignore it.
- **`error` is distinguished from `drift`.** Exit code 1 means the plan failed;
  exit code 2 means genuine drift. Conflating them either hides failures or
  cries wolf.

The workflow **never applies**. Reconcile by updating the configuration to
match intent, then applying deliberately — not by applying over drift without
understanding what moved.

---

## Running the checks locally

```bash
terraform fmt -recursive terraform/

for d in terraform/modules/*/ terraform/environments/*/; do
  (cd "$d" && terraform init -backend=false >/dev/null && terraform validate)
done

for d in terraform/modules/*/; do
  [ -d "${d}tests" ] && (cd "$d" && terraform init -backend=false >/dev/null && terraform test)
done

tflint --init && tflint --recursive
trivy config terraform/
checkov -d terraform/ --framework terraform
```

---

## Deliberately absent: an apply job

There is no automated apply, and that is a decision rather than an omission.

This platform's `route-table` module can take an environment offline in
seconds, with no health check and no automatic rollback. `key-vault` purge
protection is irreversible. A destroy against `sql` loses data that a plan
summarises as one line.

The pipeline is built so that a human approving an apply has already seen the
plan, the cost delta and the security findings. Adding `terraform apply` on
merge would remove the one step where someone reads them.

When an apply job is eventually wanted, it should use a GitHub **Environment**
with required reviewers, and consume the exact `tfplan` artefact the reviewer
approved — never re-plan at apply time, because the world may have changed
between the two.
