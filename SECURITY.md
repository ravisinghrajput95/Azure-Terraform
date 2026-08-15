# Security

## Reporting a vulnerability

Report privately through [GitHub Security
Advisories](https://github.com/ravisinghrajput95/Azure-Terraform/security/advisories/new)
rather than opening an issue. Please do not disclose publicly until a fix is
available.

This is a personal infrastructure project with no SLA. Expect a best-effort
response.

---

## Scope

This repository contains **infrastructure-as-code only** — no application code
and no runtime.

In scope:

- Terraform that provisions an insecure resource: a permissive NSG rule, a
  public data plane, a missing private endpoint, weak TLS.
- Defaults that are insecure when a module is used as documented.
- Secrets committed to the repository.
- CI workflow weaknesses — injectable inputs, over-broad permissions, an
  unpinned action that could be hijacked.

Out of scope:

- Azure platform vulnerabilities. Report those to
  [MSRC](https://msrc.microsoft.com/report).
- Any deployed environment. None is currently running; `dev` was a personal
  sandbox with no data and was decommissioned on 2026-08-14.
- Cost. An expensive default is a bug, not a vulnerability.

---

## Security posture

Design rationale is in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §4.

| Control | How |
|---|---|
| No secrets in code or state | Entra-only SQL auth, managed identity, workload identity. No SQL login exists, so there is no password to rotate or leak. |
| No public compute | Zero public IPs on nodes. Operator access via Bastion. |
| No public data plane | SQL, Redis, Storage and Key Vault use private endpoints. |
| Identity over keys | Key Vault RBAC not access policies; storage shared keys disabled; Redis access keys disabled. |
| Controlled egress | Every workload subnet egresses through one declared path — NAT Gateway in dev and qa, Azure Firewall in stage and prod. |
| Tier isolation | Kubernetes network policy. See ARCHITECTURE.md §6b for what moving this boundary from NSGs into the cluster costs. |
| Auditability | Diagnostic settings on every resource into Log Analytics. |
| Scanning | Trivy and Checkov on every push, results to GitHub Security. |

---

## Known weaknesses, deliberately accepted

Documented rather than quietly carried. Each is a dev-environment trade with a
stated reason.

> **No environment is currently deployed.** `dev` was decommissioned on
> 2026-08-14. The trades below describe the configuration, which is unchanged
> and would apply again on a rebuild — they are not descriptions of live
> exposure today.

| Weakness | Why | Where |
|---|---|---|
| Key Vault purge protection **off** in dev, qa and stage | Cannot be disabled once on, and vault names are deterministic — so one teardown strands the name for the full retention and the environment cannot be rebuilt. | `profile` |
| Data-plane public access **on** in dev, IP-restricted | With it off, an operator laptop cannot read a secret at all, so no deployment could be verified without a jump host. `default_action` is Deny. | `profile` |
| AKS API server **public** in dev, IP-restricted | A private cluster puts `kubectl` inside the VNet only. The allowlist holds the operator address and the NAT Gateway egress address. | `aks` |
| Cluster-admin granted to a **user**, not a group | Confirmed 2026-08-14: this tenant contains **zero** Entra groups, so there is nothing to grant to. The grant is a scoped, auditable Azure RBAC role assignment at cluster scope. A governance weakness anywhere with a real directory. | `terraform.tfvars` |
| No egress filtering or inspection | Azure Firewall is ~$900/month against a $200 credit, so no firewall has ever run. `dev` and `qa` egress through an unfiltered NAT Gateway and a compromised pod can reach any internet address. `stage` and `prod` compose the `firewall` module, but neither has ever been applied, so its rules have never been evaluated by Azure. See ARCHITECTURE.md §6c. | `firewall`, never applied |
| **State storage account reachable from any address** | Entra ID is the only gate: `shared_access_key_enabled = false`, so there is no key and every read is an RBAC decision attributable to a principal. But there is no network rule, no private endpoint and no infrastructure encryption, and state holds resource IDs, connection metadata and any value a provider marked sensitive and still had to persist. An IP allowlist would break the CI plan job — GitHub-hosted runners change address per run — and a private endpoint needs a VNet outliving every environment plus self-hosted runners to reach it. Accepted rather than asserted away; ARCHITECTURE.md §1.5 previously claimed all three controls existed. `infrastructure_encryption_enabled` is create-only, so adopting it means replacing the account and migrating every environment's state. | `bootstrap` |
| **Kubernetes API audit logging OFF in dev** | `kube-audit` and `kube-audit-admin` are 995 MB/day against a 512 MB/day cap — 97% of dev's entire ingestion budget, twice over. The workspace was hitting the cap daily and dropping everything that arrived after, which is unrecoverable and blinds every alert rule at once. Excluding only `kube-audit` leaves 78.4% of cap, permanently against the 80% warning line. Measured 2026-08-14, not estimated. **Restore `kube-audit-admin` first** if the cap is ever raised — it is the non-get/list subset and carries most of the security value at a third of the volume. | `dev` root |

### Closed

| Was | Closed |
|---|---|
| Shared key access **enabled** on the state account — an 88-character key granted total control of every environment's state, bypassing RBAC and attributable to no one | 2026-08-14. `allowSharedKeyAccess = false`. Key auth now rejected; Entra reads, writes and locking verified via `terraform plan`. |
| Blob soft delete **disabled** on the state account | 2026-08-14. 30 days, on blobs *and* containers — container deletion takes every blob with it regardless of the blob policy. |

Production guardrails in the `profile` module reject a `prod` environment that
is not HA, not private, on the Free SKU tier, or without backup, alerting,
purge protection and resource locks — so none of the above can reach production
by inheritance.

---

## State is a secret

Terraform state holds resource IDs, connection metadata, and any value a
provider marked sensitive but still had to persist.

- Remote backend, one container per environment, Entra authentication.
- Versioning enabled, so a corrupted push is recoverable.
- `*.tfstate` gitignored, plus a pre-commit hook.
- `backend.conf` and `terraform.tfvars` gitignored.

If state is ever committed, treat every credential it references as
compromised and rotate. Rewriting history is not sufficient — assume it was
cloned.
