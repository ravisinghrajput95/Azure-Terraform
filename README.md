# Azure-Terraform

Enterprise-grade, multi-environment Azure infrastructure built with Terraform:
a three-tier application platform behind a WAF, with all data services reachable
only through private endpoints, all egress via a controlled path, and no public
IP on any compute resource.

```
bootstrap/           Phase 0 — the state backend, on local state by necessity
terraform/
├── docs/            architecture, networking and deployment documentation
├── environments/    one root module per environment (dev, qa, stage, prod)
└── modules/         21 reusable modules
Makefile             every check CI runs, plus plan/apply per environment
```

**Start here:** [`terraform/README.md`](terraform/README.md)

```bash
pre-commit install      # the CI checks, at commit time
make check              # fmt-check, validate, test, lint
make plan ENV=dev       # needs credentials
```

| Document | Contents |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Conventions that are load-bearing rather than stylistic, and the failures behind them |
| [`SECURITY.md`](SECURITY.md) | Reporting, security posture, and the weaknesses deliberately accepted |
| [`bootstrap/README.md`](bootstrap/README.md) | Why the backend runs on local state, and how to adopt the existing one by import |
| [`terraform/docs/ARCHITECTURE.md`](terraform/docs/ARCHITECTURE.md) | Design decisions and rejected alternatives, traffic flow, Zero Trust control mapping, cost analysis |
| [`terraform/docs/NETWORKING.md`](terraform/docs/NETWORKING.md) | CIDR allocation, subnet plan, NSG rule matrix, routing, private DNS, CAF naming |
| [`terraform/docs/DEPLOYMENT.md`](terraform/docs/DEPLOYMENT.md) | Module dependency graph, deployment phases, gates, rollback characteristics |

---

## Standards

| Area | Standard |
|---|---|
| Provider | `azurerm ~> 4.0`, exact patch locked in a committed `.terraform.lock.hcl` |
| Terraform | `>= 1.9` |
| Naming | Azure CAF abbreviations via the `naming` module — no literal resource names in calling code |
| Tagging | Mandatory governance tags enforced by validation |
| Secrets | None in code or state — managed identity and Entra ID authentication throughout |
| State | Remote `azurerm` backend, one state file per environment |
| Frameworks | Azure Well-Architected Framework, Azure CAF, HashiCorp Style Guide |

---

## Retired: the original `cloudcart` configuration

The repository root previously held an earlier deployment — a Linux VM and an
AKS cluster on `azurerm ~> 3.117`, with its own state backend.

It has been removed. It was never successfully applied: the `cloudcart`
resource group contained only its own state storage account, with no VNet, VM
or cluster, so there was nothing to migrate. The new tree under `terraform/`
supersedes it on `azurerm ~> 4.0`.

The old code remains in git history if it is ever needed:

```bash
git log --oneline --all -- modules/ main.tf
git show <commit>:main.tf
```

**AKS is not currently part of the new platform.** The three-tier design uses
VM Scale Sets. If a container platform is wanted, it belongs as its own module
with its own subnet — the address plan reserves `10.x.16.0/20` for exactly that.
