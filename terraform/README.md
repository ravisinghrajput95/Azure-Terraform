# cloudcart — Enterprise 3-Tier Platform on Azure

Production-grade, multi-environment Azure infrastructure built with Terraform.
Three-tier application topology on AKS, with all data services reachable only
through private endpoints, controlled egress, and no public IP on any compute
resource.

> **Status: NOTHING IS DEPLOYED.** dev was decommissioned on 2026-08-14; qa, stage
> and prod are written and have never been applied. 22 modules built. 19 are instantiated
> by dev's root module; `application-gateway` and `load-balancer` are written
> but not deployed by dev — AKS provisions its own load balancer. Compute is
> AKS — see [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §6b for what moving
> the tier boundary from subnets into a cluster changes, and why dev's cluster
> is deliberately not highly available.

### Environment status

| Env | CIDR | State | Blocker |
|---|---|---|---|
| `dev` | `10.10.0.0/16` | **Decommissioned 2026-08-14.** Was deployed and verified — 149 resources, no drift — then destroyed to stop spend. Rebuildable from this repo | — |
| `qa` | `10.20.0.0/16` | **Written, validates, plans** (146 resources). Never applied | Needs 6 vCPU steady / 8 peak against a regional limit of 4, and ~$1,062/month. See [`environments/qa/README.md`](environments/qa/README.md) |
| `stage` | `10.40.0.0/16` | **Written, validates, plans** (143 resources). Never applied | 10 vCPU steady / 16 peak vs a limit of 4, and ~$2,148/month — of which the firewall is ~$913. See [`environments/stage/README.md`](environments/stage/README.md) |
| `prod` | `10.30.0.0/16` | **Written, validates, plans** (146 resources). Never applied | 24 vCPU steady / 80 peak, ~$3,242/month. See [`environments/prod/README.md`](environments/prod/README.md) |

`stage` and `prod` both egress through an **Azure Firewall** rather than a NAT
Gateway — that is what `stage` exists to validate, and the `firewall` module
was written for them. Like the environments themselves it has **never been
applied**: ~$913/month Standard, ~$1,278 Premium. See
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §6c for why dev and qa use a NAT
Gateway instead, and therefore have no egress filtering at all.

**`dev` is the only environment that has ever run, and it no longer does.** It
was deployed, verified against the Azure API, and then destroyed on 2026-08-14:
134 resources removed, the Key Vault purged, all 4 regional vCPU released, and
the state backend left intact so it can be rebuilt.

Everything else — three environments and the `firewall` module — is
configuration that plans and has never touched Azure. That is recorded in each
README rather than left to be assumed from the fact that the code is complete.

---

## Documentation

Architecture, networking and deployment docs live at
[`docs/`](../docs) in the repository root.

| Document | Contents |
|---|---|
| [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) | Design decisions and rejected alternatives, traffic flow, architecture diagram, Zero Trust control mapping, cost analysis, open decisions |
| [`../docs/NETWORKING.md`](../docs/NETWORKING.md) | CIDR allocation, subnet plan, NSG rule matrix, routing, private DNS, CAF naming convention |
| [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md) | Module dependency graph, critical path, six-phase deployment order, gates, rollback characteristics |

---

## Repository structure

```
terraform/
├── environments/                One root module per environment
│   ├── dev/                     10.10.0.0/16
│   ├── qa/                      10.20.0.0/16
│   ├── stage/                   10.40.0.0/16
│   └── prod/                    10.30.0.0/16
│
└── modules/
    ├── naming                   CAF naming — pure computation, no resources
    ├── tags                     Mandatory tag map with validation
    ├── profile                  Per-environment capability flags and sizing
    ├── resource-group           Lifecycle-scoped resource groups
    ├── networking               VNet and subnets
    ├── nsg                      Network security groups and associations
    ├── route-table              UDRs and subnet associations
    ├── private-dns              Private DNS zones and VNet links
    ├── firewall                 Azure Firewall, policy, rule collections
    ├── bastion                  Azure Bastion
    ├── log-analytics            Log Analytics workspace
    ├── diagnostics              Shared diagnostic-settings helper
    ├── managed-identity         User-assigned identities and RBAC
    ├── key-vault                Key Vault, RBAC, private endpoint
    ├── storage                  Storage account, private endpoints
    ├── sql                      Azure SQL, Entra-only auth, private endpoint
    ├── redis                    Azure Cache for Redis, private endpoint
    ├── load-balancer            Internal and public load balancers (unused since AKS)
    ├── application-gateway      Application Gateway WAF v2
    ├── aks                      Kubernetes cluster (replaces vm)
    ├── monitor                  Alerts and action groups
    └── recovery-services        Recovery Services vault and backup policies
```

`vm` and `autoscale` are **empty placeholder directories**, not modules — both
were superseded by AKS (ARCHITECTURE.md §6b).

`firewall` is written but **has never been applied**, because Azure Firewall is
~$913/month against a $200 credit. `dev` and `qa` therefore egress through a
NAT Gateway (~$35/month) with `outbound_type = "userAssignedNATGateway"` and no
egress filtering at all; `stage` and `prod` use the firewall with
`userDefinedRouting`, and have never run.

Each environment root module is a thin composition layer: it wires modules
together and supplies variables. It contains no resource blocks of its own.

Every module ships `main.tf`, `variables.tf`, `outputs.tf`, `locals.tf` and
`versions.tf`.

---

## Standards

| Area | Standard |
|---|---|
| Provider | `azurerm ~> 4.0`, exact patch locked in a committed `.terraform.lock.hcl` |
| Terraform | `>= 1.9` |
| Naming | Azure CAF abbreviations via the `naming` module — no literal resource names in calling code |
| Tagging | Mandatory tags enforced by `validation` blocks in the `tags` module |
| Iteration | `for_each` over maps, never `count` on named resources |
| Secrets | None in code or state — managed identity and Entra-only auth by default |
| State | Remote `azurerm` backend, one state file per environment, partial config at `init` |
| Frameworks | Azure Well-Architected Framework, Azure CAF, HashiCorp Style Guide |

---

## Getting started

Terraform state lives in an Azure Storage account that must be bootstrapped
before first use — see [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md) §2, Phase 0.

```bash
cd terraform/environments/dev

terraform init -backend-config=backend.conf
terraform validate
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

`backend.conf` and `terraform.tfvars` hold environment-specific values and
credentials. Both are gitignored.

---

## Subscription constraints encountered

This platform is deployed on an Azure FreeTrial subscription, which imposed
three restrictions that shaped real decisions rather than being worked around:

| Constraint | Consequence |
|---|---|
| Azure SQL provisioning blocked in East US | Whole platform moved to Central US. See ARCHITECTURE.md §6a. |
| `Standard_B2s` not permitted in the subscription | AKS nodes use `Standard_D2s_v4`. The only cheap permitted size is ARM, which would require arm64 images. |
| 4 total regional vCPUs, not raisable on FreeTrial | dev's AKS cluster is a single node and explicitly not HA. Three nodes across three zones is 6 vCPU. |

Each is recorded where the decision was made rather than only here, because the
reasoning matters more than the outcome.
