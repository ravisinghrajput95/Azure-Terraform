# Architecture — cloudcart 3-Tier Platform

Status: **design, pre-implementation**. No Terraform written yet.

---

## 1. Design decisions and trade-offs

Each decision below is recorded with the alternative that was rejected and why.
Where a decision is still open, it is listed in §7.

### 1.1 Single VNet per environment, hub-spoke ready

The brief lists Azure Firewall, Bastion, Application Gateway and all three
workload tiers as one vertical flow, which describes a **single VNet with an
edge/DMZ zone**, not a hub-spoke topology.

We build that, but with two constraints that keep hub-spoke a non-breaking
migration later:

- The `networking` module never assumes the firewall or Bastion live in the
  VNet it creates — their subnet IDs are inputs/outputs, not internal wiring.
- Route tables take a `next_hop_ip` variable rather than reading the firewall
  resource directly, so pointing at a hub firewall is a variable change.

**Rejected:** full hub-spoke from day one. It triples the firewall cost (§1.7),
adds VNet peering and DNS-forwarder complexity, and buys nothing until a second
workload exists. Hub-spoke is correct at the *platform* level, not for a single
application landing zone.

### 1.2 Multiple resource groups per environment, not one

Resource groups are the unit of lifecycle, RBAC scope and deletion blast
radius. Putting a firewall and an autoscaling VMSS in the same RG means the
team that can redeploy compute can also delete the network edge.

| RG | Contents | Lifecycle |
|---|---|---|
| `rg-cloudcart-<env>-<loc>-net` | VNet, subnets, NSGs, route tables, firewall, Bastion, private DNS zones | Slow — changes rarely, tightly controlled |
| `rg-cloudcart-<env>-<loc>-sec` | Key Vault, user-assigned managed identities | Slow — security-team owned |
| `rg-cloudcart-<env>-<loc>-data` | SQL, Redis, storage, private endpoints | Medium — schema/capacity changes |
| `rg-cloudcart-<env>-<loc>-app` | VMSS, ILB, App Gateway, autoscale rules | Fast — deploys with the app |
| `rg-cloudcart-<env>-<loc>-mon` | Log Analytics, action groups, alert rules, Recovery Services vault | Slow — must outlive the resources it observes |

The monitoring RG deliberately sits outside the app RG so that tearing down a
dev app stack does not destroy its own audit trail.

### 1.3 Azure Monitor Agent, never the legacy agent

VM Insights will be delivered through **Azure Monitor Agent (AMA) + Data
Collection Rules**. The Log Analytics agent (MMA/OMS) reached end of support in
August 2024 — any design using `azurerm_virtual_machine_extension` with
`MicrosoftMonitoringAgent`, or the `OmsAgentForLinux` extension, is deploying a
dead product. This is the single most common "deprecated resource" failure in
older Azure Terraform repos.

Concretely: `azurerm_monitor_data_collection_rule` +
`azurerm_monitor_data_collection_rule_association`, with the
`AzureMonitorLinuxAgent` extension on the VMSS.

### 1.4 Diagnostics as a shared module, not copy-paste

Every module needs a diagnostic setting, and every resource type has a
different set of valid log categories. Hardcoding category names per resource
is the main source of "worked last year, fails now" breakage when Azure adds or
renames categories.

The `diagnostics` module takes a resource ID and a workspace ID, reads
`data.azurerm_monitor_diagnostic_categories` for that resource, and generates
`enabled_log` / `metric` blocks dynamically. Every other module calls it. That
is how "no duplicate code" is actually achieved for the cross-cutting concern.

### 1.5 Entra ID-only authentication for SQL — no password to protect

The brief says "no hardcoded secrets." The stronger position is **no secret at
all**. Azure SQL will be configured with `azuread_authentication_only = true`
and an Entra group as the SQL administrator. There is no SQL login, therefore
no password to generate, rotate, store in Key Vault, or leak into state.

Applications authenticate with the tier's user-assigned managed identity.

*If* a SQL login is later required for a legacy component, the fallback is a
`random_password` written to Key Vault — but note this **stores the password in
Terraform state in plaintext**. State is therefore treated as a secret: the
backend storage account gets its own private endpoint, RBAC-only access, and
infrastructure encryption. On recent Terraform + azurerm, write-only arguments
can keep such values out of state entirely; we will verify support for the
specific resource before relying on it rather than assuming.

### 1.6 Subnets as discrete resources — never inline

`azurerm_virtual_network` accepts an inline `subnet` block. Using it *and*
`azurerm_subnet` resources produces permanent drift, where each apply removes
the other's subnets. All subnets will be `azurerm_subnet` resources; the VNet
resource declares address space only. NSG and route table attachment use the
dedicated association resources.

### 1.7 Cost posture differs by environment

This is the biggest financial decision in the brief, and the default reading of
"build all of it in dev, test and prod" is expensive. Approximate list prices,
East US, before data processing charges — **verify against the Azure Pricing
Calculator for your region and agreement**:

| Component | Order of magnitude, per environment, per month |
|---|---|
| Azure Firewall (Standard) | ~$900 + ~$0.016/GB processed |
| Azure Firewall (Premium) | ~$1,200 + data processing |
| Application Gateway WAF v2 | ~$260 minimum + capacity units |
| Azure Bastion (Standard) | ~$140 + outbound data |
| SQL zone-redundant (Business Critical) | Several hundred to low thousands |
| Redis Premium (zone redundant) | ~$400+ |

Running the full stack in three environments is a five-figure monthly bill
dominated by three always-on network appliances that dev and test barely
exercise. The recommendation is in §7, Decision C.

### 1.8 Zone redundancy is not free and not universal

- **VMSS**: `zones = [1,2,3]` with zone balancing — no extra charge, always on.
- **Standard Load Balancer / Public IP**: zone-redundant frontend — no charge.
- **Application Gateway v2**: `zones = [1,2,3]` — no charge, requires v2 SKU.
- **Azure Firewall**: zones are free, but **cross-zone data transfer is billed**.
- **SQL**: zone redundancy requires Premium / Business Critical, or General
  Purpose on supported hardware — a real tier upgrade, not a flag.
- **Redis**: zone redundancy requires the Premium tier.

Not every region offers zones. The `networking` and `vm` modules will take a
`zones` list variable with a validation block rather than hardcoding `[1,2,3]`,
so a non-zonal region degrades to `[]` explicitly instead of failing at apply.

---

## 2. Traffic flow

```
Users ──► Public IP (zone-redundant)
          └─► Application Gateway WAF v2  [snet-agw, zones 1-3]
                └─► App tier VMSS         [snet-app, zones 1-3, no public IP]
                      └─► Internal LB     [snet-biz, zone-redundant frontend]
                            └─► Biz tier VMSS [snet-biz, zones 1-3]
                                  ├─► Private Endpoint ─► Azure SQL
                                  ├─► Private Endpoint ─► Redis
                                  ├─► Private Endpoint ─► Key Vault
                                  └─► Private Endpoint ─► Storage

Operator ─► Azure Bastion [AzureBastionSubnet] ─► VMSS instances (no public IP anywhere)

All egress from app/biz/db/mgmt ──UDR 0.0.0.0/0──► Azure Firewall ──► Internet
```

Two routing rules that break this design if violated, and are the most common
production incidents in this topology:

1. **Never put a `0.0.0.0/0 → firewall` UDR on the Application Gateway subnet.**
   AppGW v2 requires direct outbound access to its control plane. Forcing it
   through the firewall breaks health probes and the gateway goes unhealthy.
2. **Never put a `0.0.0.0/0 → firewall` UDR on `AzureBastionSubnet`.** Bastion
   requires direct outbound connectivity and will fail to provision or drop
   sessions.

Return traffic from the app tier to the App Gateway is intra-VNet, so it uses
the system route and does not create asymmetric routing through the firewall.

---

## 3. Architecture diagram

```mermaid
flowchart TB
    Users(["Users / Internet"])
    Ops(["Operators"])

    subgraph SUB["Azure Subscription — Environment"]

        subgraph RGNET["rg-...-net"]
            direction TB
            subgraph VNET["VNet 10.x.0.0/16"]
                direction TB

                subgraph EDGE["Edge / Platform subnets"]
                    AFW["Azure Firewall<br/>AzureFirewallSubnet /26"]
                    BAS["Azure Bastion Standard<br/>AzureBastionSubnet /26"]
                    AGW["App Gateway WAF v2<br/>snet-agw /24 — zones 1,2,3"]
                end

                subgraph TIERS["Workload subnets"]
                    APP["App tier VMSS<br/>snet-app /22 — zones 1,2,3"]
                    ILB["Internal Load Balancer<br/>Standard, zone-redundant"]
                    BIZ["Business tier VMSS<br/>snet-biz /22 — zones 1,2,3"]
                    MGMT["Management<br/>snet-mgmt /24"]
                end

                subgraph PEP["snet-pep /24 — Private Endpoints"]
                    PESQL["PE: SQL"]
                    PERDS["PE: Redis"]
                    PEKV["PE: Key Vault"]
                    PEST["PE: Storage"]
                end
            end
            PDNS["Private DNS Zones<br/>database.windows.net<br/>redis.cache.windows.net<br/>vaultcore.azure.net<br/>blob.core.windows.net"]
        end

        subgraph RGDATA["rg-...-data"]
            SQL["Azure SQL Database<br/>public access disabled<br/>Entra-only auth"]
            RDS["Azure Cache for Redis<br/>public access disabled"]
            ST["Storage Account<br/>public access disabled<br/>shared keys disabled"]
        end

        subgraph RGSEC["rg-...-sec"]
            KV["Key Vault<br/>RBAC, purge protection"]
            MI["User-Assigned<br/>Managed Identities"]
        end

        subgraph RGMON["rg-...-mon"]
            LAW["Log Analytics Workspace"]
            MON["Azure Monitor<br/>alerts + action groups"]
            RSV["Recovery Services Vault"]
        end
    end

    Users --> AGW
    Ops --> BAS
    BAS -.-> APP
    BAS -.-> BIZ
    AGW --> APP
    APP --> ILB
    ILB --> BIZ
    BIZ --> PESQL
    BIZ --> PERDS
    BIZ --> PEKV
    BIZ --> PEST
    PESQL --> SQL
    PERDS --> RDS
    PEKV --> KV
    PEST --> ST
    PDNS -.resolves.-> PEP
    APP -.egress via UDR.-> AFW
    BIZ -.egress via UDR.-> AFW
    AFW --> Users
    MI -.RBAC.-> KV
    MI -.RBAC.-> ST
    MI -.Entra auth.-> SQL
    APP -.diagnostics.-> LAW
    BIZ -.diagnostics.-> LAW
    SQL -.diagnostics.-> LAW
    AGW -.diagnostics.-> LAW
    AFW -.diagnostics.-> LAW
    KV -.diagnostics.-> LAW
    LAW --> MON
    RSV -.backup.-> APP
    RSV -.backup.-> BIZ
```

---

## 4. Security model — Zero Trust mapping

| Control | Implementation |
|---|---|
| No implicit network trust | NSG on every workload subnet, default-deny inbound; tier-to-tier rules are explicit and directional |
| No public compute | Zero public IPs on VMSS; operator access only via Bastion; no SSH/RDP from internet |
| No public data plane | SQL, Redis, Storage, Key Vault all `public_network_access_enabled = false` + private endpoint |
| Identity, not secrets | User-assigned managed identity per tier; Entra-only SQL auth; Key Vault RBAC (not access policies) |
| Least privilege | Per-tier identities with scoped role assignments — app tier cannot read biz tier's secrets |
| Encryption in transit | TLS 1.2 minimum on storage/SQL/Redis; WAF terminates TLS with a Key Vault certificate |
| Egress control | All workload subnets default-route to Azure Firewall; explicit FQDN/network rules |
| Perimeter inspection | WAF v2 in Prevention mode with OWASP managed rule set |
| Auditability | Diagnostic settings on every resource → Log Analytics; activity logs exported |
| Key management | Key Vault with soft-delete + purge protection enabled (irreversible once on — deliberate) |
| Defender-ready | Resources emit the categories Defender for Cloud plans consume; enabling the plans is a subscription-level decision left as a variable |

**Explicitly out of scope unless requested:** customer-managed keys for SQL TDE
and storage encryption. They add a Key Vault dependency loop (the vault must
exist and be reachable before the data resource, and its deletion bricks the
data) that deserves its own decision rather than being switched on silently.

---

## 5. Terraform standards applied

- **Provider pinning**: `azurerm ~> 4.0` with the exact patch locked by
  `.terraform.lock.hcl` (committed). Azure provider v4 requires an explicit
  `subscription_id` and changes resource-provider registration behaviour — the
  existing v3 config in this repo does not carry over unchanged.
- **Terraform version**: `>= 1.9` floor for the validation and `moved` features
  used; a higher floor if write-only arguments are adopted (§1.5).
- **Naming**: dedicated `naming` module implementing Azure CAF abbreviations,
  so no resource name is ever a literal string in a calling module.
- **Tags**: dedicated `tags` module producing a merged, validated tag map —
  mandatory tags enforced by `validation` blocks, not convention.
- **Validation**: every module input that has a bounded domain (SKU, tier,
  CIDR, zone list, environment) gets a `validation` block. Failures surface at
  plan time, not after 20 minutes of apply.
- **No `count` for optionality on named resources**: `for_each` over maps, so
  adding a subnet does not re-index and destroy unrelated ones.
- **Outputs**: every module exports IDs consumed downstream plus a small number
  of human-useful values; sensitive outputs marked `sensitive`.
- **State**: remote azurerm backend, one state file per environment, partial
  backend config supplied at `init`.

---

## 6. Module build order

Foundation first, then the resources that everything else reports into, then
the network, then data, then compute, then observability wiring.

| # | Module | Depends on | Why here |
|---|---|---|---|
| 1 | `naming` | — | Pure computation, no provider calls. Everything consumes it. |
| 2 | `tags` | — | Same. |
| 3 | `resource-group` | naming, tags | The container everything lands in. |
| 4 | `log-analytics` | 3 | Must exist before any diagnostic setting can target it. |
| 5 | `diagnostics` | 4 | Shared helper — built early so modules 6+ can call it. |
| 6 | `networking` | 3 | VNet + subnets; the address space everything binds to. |
| 7 | `nsg` | 6 | Attaches to subnets. |
| 8 | `route-table` | 6 | Needs subnets; firewall IP injected later as a variable. |
| 9 | `firewall` | 6, 8 | Provides the next-hop the route tables point at. |
| 10 | `private-dns` | 6 | Zones + VNet links, required before any private endpoint resolves. |
| 11 | `managed-identity` | 3 | Identities must exist before RBAC on vault/storage. |
| 12 | `key-vault` | 6, 10, 11 | Private endpoint + RBAC assignments. |
| 13 | `storage` | 6, 10, 11 | Same shape as key-vault. |
| 14 | `bastion` | 6 | Independent of workload; enables operator access early. |
| 15 | `sql` | 6, 10, 11 | Private endpoint + Entra admin. |
| 16 | `redis` | 6, 10 | Private endpoint. |
| 17 | `load-balancer` | 6 | Internal LB for the business tier. |
| 18 | `application-gateway` | 6, 12 | Needs the vault for its TLS certificate. |
| 19 | `vm` | 6, 7, 11, 17, 18 | VMSS for both tiers; last because it consumes everything. |
| 20 | `autoscale` | 19 | Scale rules target the VMSS. |
| 21 | `recovery-services` | 3, 19 | Backup policies for the scale sets. |
| 22 | `monitor` | 4, and all | Alerts reference resources that must already exist. |

Modules 1–2 are additions to your original list. A "naming convention module"
and "tags module" appear in your Terraform Standards section but not in the
repository structure — they are foundational, so they are listed explicitly.

---

## 7. Open decisions — needed before module 1

**Decision A — Relationship to the existing `cloudcart` config.**
The repository root already holds a working VM + AKS deployment on azurerm
v3.117, with live state in an Azure Storage backend. The new `terraform/` tree
is a different architecture on a different provider major version. Options:
keep both (root config frozen, new tree greenfield), migrate and retire the
root config, or fold AKS into the new design as a fourth tier.

**Decision B — Topology.** Single VNet per environment as designed above, or
hub-spoke with a shared hub carrying firewall and Bastion.

**Decision C — Environment cost posture.** Full parity across dev/test/prod is
roughly a five-figure monthly bill. The pragmatic alternative: prod gets
firewall + WAF + Bastion + zone-redundant data tier; dev/test share a single
hub firewall (or use NAT Gateway for egress, ~$35/month), run WAF v2 without
zone redundancy, and use non-zone-redundant SQL/Redis tiers. Module code is
identical; only `terraform.tfvars` differs.

**Decision D — State granularity.** One state file per environment (matches
your `environments/{dev,test,prod}` layout, simple, but a single plan touches
all 22 modules), or layered state per environment (`00-platform`, `10-data`,
`20-app`) for smaller blast radius and faster plans at the cost of cross-layer
data sources.
