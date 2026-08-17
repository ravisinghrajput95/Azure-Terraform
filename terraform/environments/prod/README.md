# Environment: `prod`

Full production grade. **Written, validates and plans — never applied, and not
appropriate to apply on this subscription even if it fitted.**

Every claim here is a claim about a plan. Nothing in this environment has run,
and neither has the `firewall` module it depends on.

`tests/prod.tftest.hcl` is therefore the whole of prod's verification. It plans
this composition under `mock_provider` — no credentials, no backend, nothing
created — and asserts that the controls prod exists to carry are actually
wired rather than merely configured: management locks present, egress forced
through the firewall by a real `0.0.0.0/0` route, the WAF in Prevention rather
than Detection, and no daily cap on the workspace. It also pins the peak
footprint at 80 vCPU, which is the number that keeps this environment
undeployable here. It does not prove Azure accepts the plan.

---

## Why it is not deployed

**Quota.** The `profile` module refuses it before any Azure call:

```
Peak vCPU footprint is 80 (4 vCPU x 20 instances x 1 tiers) but the
subscription quota is 4.
```

Steady state is **24 vCPU** — three `Standard_D4s_v5` system nodes plus three
user nodes — against a regional limit of 4, with dev holding 2.

**Cost.** `indicative_monthly_cost_usd` from the plan: **~$3,242/month**.

Neither number is the real argument. A FreeTrial subscription with the spending
limit on is disabled when the credit runs out; running production on
infrastructure that stops rather than bills is not a cost problem, it is an
availability one.

---

## What prod adds over stage

stage already validates the firewall topology, the UDRs and the egress rules on
the Standard tier. prod's additions are the ones that cannot be validated more
cheaply:

| | stage | prod |
|---|---|---|
| Firewall | Standard | **Premium — IDPS in Deny mode**, TLS inspection available |
| Compute | 3 × `D2s_v5`, user pool 2→6 | 3 × `D4s_v5`, user pool 3→10 |
| SQL | `BC_Gen5_2` | `BC_Gen5_4` |
| Redis | `Balanced_B1` HA | `Balanced_B3` HA |
| Key Vault purge protection | **off** | **ON — irreversible** |
| Resource locks | off | **on** (`net`, `sec`, `data`) |
| Defender for Cloud | off | **on** |
| Backup retention | 35 days | 90 days |

IDPS is set to **`Deny`**, not `Alert`. Alert logs signature matches and lets
them through, which reports as enabled while blocking nothing — the difference
between an IDPS and an IDPS-shaped log stream. The `firewall` module rejects
IDPS on any tier below Premium, because naming a capability the deployed tier
cannot provide is worse than omitting it.

---

## Two things behave differently here, and both are irreversible-adjacent

### Purge protection changes the provider, not just the vault

prod is the only environment with `key_vault_purge_protection = true`, and it
is the only environment whose `providers.tf` sets:

```hcl
purge_soft_delete_on_destroy = false
```

The two are mutually exclusive by definition. Purge protection exists to make
the vault unpurgeable for its full retention; a provider configured to purge on
destroy is asking Azure to do something it will refuse.

dev, qa and stage all purge on destroy, because their vault names are
deterministic and protection would block rebuilding them for 90 days. prod is
not rebuilt on a whim, and a vault that can be destroyed and immediately purged
is a vault whose keys can be destroyed and immediately purged.

**Purge protection cannot be turned off once on.** Enabling it is a one-way
door, which is exactly why every other environment declines it.

### Resource locks make `terraform destroy` fail

`enable_resource_locks = true` puts `CanNotDelete` locks on the `net`, `sec`
and `data` resource groups. That is the point, and it means a destroy of those
scopes fails until the lock is removed by hand — deliberately a separate,
deliberate action rather than a flag on the same command.

---

## The guardrails are the feature

The `profile` module rejects a prod that is not highly available, not private,
on the Free SKU tier, or missing backup, alerting, purge protection or resource
locks. They fail the plan with the **full list** rather than one at a time.

`enforce_production_guardrails = false` is the only way past them, and it should
carry a documented reason. The guardrails exist because every weakness accepted
in dev — public API server, no purge protection, no locks, a capped workspace,
audit logging dropped — is individually reasonable there and individually
unacceptable here, and inheritance is how they would arrive.

---

## Usage

```bash
terraform init -backend-config=backend.conf
terraform plan -var-file=terraform.tfvars                          # fails on quota, by design
terraform plan -var-file=terraform.tfvars -var="subscription_vcpu_quota=80"
```

The second form plans **146 resources** and changes nothing in Azure. The state
container `tfstate-prod` exists — it predates this configuration and was
adopted when `bootstrap/` was imported.

---

## Addressing

`10.30.0.0/16`, with the same shape as stage.

| Subnet | CIDR |
|---|---|
| `AzureFirewallSubnet` | `10.30.0.0/26` |
| `AzureBastionSubnet` | `10.30.0.128/26` |
| `snet-agw-prod-cus` | `10.30.1.0/24` |
| `snet-app-prod-cus` | `10.30.4.0/22` |
| `snet-biz-prod-cus` | `10.30.8.0/22` |
| `snet-db-prod-cus` | `10.30.12.0/24` |
| `snet-pep-prod-cus` | `10.30.13.0/24` |
| `snet-mgmt-prod-cus` | `10.30.14.0/24` |
| `snet-aks-prod-cus` | `10.30.16.0/20` |

---

## What would still be missing on the day this deployed

Worth stating, because a complete-looking configuration invites the assumption
that it is:

- **The Application Gateway backend pool is empty.** It points at the AKS
  ingress controller's internal load balancer, which does not exist until
  something is deployed into the cluster. An empty pool is a visible gap; a
  guessed address would be a silent misroute.
- **The TLS certificate is an input.** Unset, the gateway is HTTP-only and
  `ingress_is_encrypted` says so — which would be an absurd posture for
  production and is reported rather than prevented, because the alternative is
  an environment that cannot stand up before its certificate exists.
- **`recovery-services` protects nothing.** The vault and policies deploy; AKS
  backup is a different resource family entirely.
- **DDoS Network Protection is off.** It is ~$2,900/month per tenant and
  belongs at tenant level, enabled once, not per environment.
