# cloudcart — Enterprise 3-Tier Platform on Azure

Production-grade, multi-environment Azure infrastructure built with Terraform.
Three-tier application topology behind a WAF, with all data services reachable
only through private endpoints, all egress forced through Azure Firewall, and
no public IP on any compute resource.

> **Status: design phase.** The architecture, network plan and repository
> skeleton are complete. No Terraform has been written yet — modules are built
> one at a time, each reviewed before the next begins.

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Design decisions and rejected alternatives, traffic flow, architecture diagram, Zero Trust control mapping, cost analysis, open decisions |
| [`docs/NETWORKING.md`](docs/NETWORKING.md) | CIDR allocation, subnet plan, NSG rule matrix, routing, private DNS, CAF naming convention |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Module dependency graph, critical path, six-phase deployment order, gates, rollback characteristics |

---

## Repository structure

```
terraform/
├── docs/                        Architecture, networking and deployment docs
│
├── environments/                One root module per environment
│   ├── dev/                     10.10.0.0/16
│   ├── test/                    10.20.0.0/16
│   └── prod/                    10.30.0.0/16
│
└── modules/
    ├── naming                   CAF naming — pure computation, no resources
    ├── tags                     Mandatory tag map with validation
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
    ├── load-balancer            Internal load balancer
    ├── application-gateway      Application Gateway WAF v2
    ├── vm                       VM Scale Sets
    ├── autoscale                Autoscale settings
    ├── monitor                  Alerts and action groups
    └── recovery-services        Recovery Services vault and backup policies
```

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
before first use — see [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) §2, Phase 0.

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

## Relationship to the repository root

The repository root contains an earlier `cloudcart` deployment (VM + AKS) on
`azurerm ~> 3.117` with its own live state. It is a separate architecture on a
different provider major version and is **not** consumed by this tree. Whether
it is frozen, migrated or folded in as a fourth tier is open — see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §7, Decision A.
