# Networking Design — CIDR Plan, NSGs, Routing

---

## 1. Address space allocation

Each environment receives a non-overlapping `/16`. Ranges are spaced so that
environments can never collide during a future VNet peering, VPN or
ExpressRoute connection — the most expensive networking mistake to correct,
because fixing it means rebuilding subnets and every resource in them.

| Block | Assignment | Status |
|---|---|---|
| `10.0.0.0/16` | Reserved — future shared hub (firewall, DNS, ExpressRoute gateway) | Reserved |
| `10.10.0.0/16` | **dev** | Allocated |
| `10.20.0.0/16` | **qa** | Allocated |
| `10.30.0.0/16` | **prod** | Allocated |
| `10.40.0.0/16` | **stage** | Allocated |
| `10.50.0.0/16` – `10.90.0.0/16` | Reserved — future spokes / additional workloads | Reserved |
| `10.100.0.0/16`+ | Reserved — on-premises / partner ranges | Do not allocate |

Deliberately **not** used: `10.1.0.0/16`–`10.9.0.0/16`, left as a buffer under
the hub, and `172.16.0.0/12` / `192.168.0.0/16`, commonly present in on-premises
and VPN client pools.

---

## 2. Subnet plan

The pattern below is identical in every environment; only the second octet
changes (dev `10`, qa `20`, prod `30`, stage `40`). The table shows **prod**.

`stage` takes `10.40` from the reserved range rather than a block adjacent to
`qa`. Prod keeps `10.30` because this document's entire worked subnet plan is
built on it, and renumbering a deployed-shaped address plan to make the list
read in order is churn that buys nothing — CIDR blocks are identifiers, not a
sequence.

| Subnet | CIDR | Size | Usable¹ | NSG | Route table | Notes |
|---|---|---|---|---|---|---|
| `AzureFirewallSubnet` | `10.30.0.0/26` | 64 | 59 | ❌ not supported | ✅ `rt-fw` | Name is fixed by Azure. `/26` is the minimum. |
| `AzureFirewallManagementSubnet` | `10.30.0.64/26` | 64 | 59 | ❌ | ❌ | **Reserved, not deployed.** Required only for forced tunnelling. Held so it never gets taken. |
| `AzureBastionSubnet` | `10.30.0.128/26` | 64 | 59 | ✅ required | ❌ **no 0.0.0.0/0** | Name fixed by Azure. `/26` minimum for Standard SKU. |
| `GatewaySubnet` | `10.30.0.192/26` | 64 | 59 | ❌ | ❌ | **Reserved, not deployed.** For a future VPN/ExpressRoute gateway. |
| `snet-agw` | `10.30.1.0/24` | 256 | 251 | ✅ required | ❌ **no 0.0.0.0/0** | Dedicated to App Gateway. `/24` gives WAF v2 autoscale headroom. |
| `snet-app` | `10.30.4.0/22` | 1024 | 1019 | ✅ | ✅ `rt-workload` | Application tier VMSS. |
| `snet-biz` | `10.30.8.0/22` | 1024 | 1019 | ✅ | ✅ `rt-workload` | Business tier VMSS + internal LB frontend. |
| `snet-db` | `10.30.12.0/24` | 256 | 251 | ✅ | ✅ `rt-workload` | **Reserved.** PaaS SQL reaches the VNet via private endpoint, so no resource lands here today. Held for a future IaaS SQL / managed instance. |
| `snet-pep` | `10.30.13.0/24` | 256 | 251 | ✅ | ✅ `rt-workload` | Private endpoint NICs. One IP consumed per endpoint. |
| `snet-mgmt` | `10.30.14.0/24` | 256 | 251 | ✅ | ✅ `rt-workload` | Jump hosts, build agents, self-hosted runners. |
| — | `10.30.16.0/20` | 4096 | — | — | — | **Free.** Growth: container platform, additional tiers. |
| — | `10.30.32.0/19` … `10.30.128.0/17` | — | — | — | — | **Free.** Over half the `/16` is unallocated on purpose. |

¹ Azure reserves 5 addresses in every subnet: network address, default gateway,
two for DNS, and broadcast. A `/26` yields 59 usable, not 64.

**Why the tiers get `/22` and not `/24`:** a VMSS scaling to 200 instances with
rolling upgrades transiently consumes more than 200 addresses. A `/24` (251
usable) leaves no room for a surge upgrade at scale, and resizing a subnet
in use is not possible — it requires emptying it first.

**Why `snet-pep` is `/24` for a handful of endpoints:** private endpoints
accumulate quietly. Each new PaaS service adds one. 251 is cheap insurance;
the address space is not scarce.

---

## 3. NSG rule matrix

Every workload NSG is default-deny inbound. Rules below are the explicit
allows, priority-ordered. Sources use Application Security Groups or subnet
prefixes — never `*`.

### `nsg-agw` — Application Gateway subnet

| Pri | Dir | Action | Source | Dest port | Rationale |
|---|---|---|---|---|---|
| 100 | In | Allow | `GatewayManager` | 65200-65535 | **Mandatory.** AppGW v2 control plane. Omitting this makes the gateway permanently unhealthy — the single most common WAF v2 deployment failure. |
| 110 | In | Allow | `AzureLoadBalancer` | * | Health probes. |
| 120 | In | Allow | `Internet` | 443 | Public HTTPS listener. |
| 130 | In | Allow | `Internet` | 80 | Only if HTTP→HTTPS redirect is enabled; otherwise omitted. |
| 4096 | In | Deny | `*` | * | Explicit default-deny. |

### `nsg-bastion` — `AzureBastionSubnet`

Azure mandates this exact rule set; Bastion will not provision without it.

| Pri | Dir | Action | Source / Dest | Port | Rationale |
|---|---|---|---|---|---|
| 100 | In | Allow | `Internet` | 443 | Operator HTTPS to Bastion. |
| 110 | In | Allow | `GatewayManager` | 443 | Control plane. |
| 120 | In | Allow | `AzureLoadBalancer` | 443 | Health probes. |
| 130 | In | Allow | `VirtualNetwork` | 8080, 5701 | Bastion data-plane internal. |
| 100 | Out | Allow | `VirtualNetwork` | 22, 3389 | Bastion → target VMs. |
| 110 | Out | Allow | `AzureCloud` | 443 | Dependencies. |
| 120 | Out | Allow | `VirtualNetwork` | 8080, 5701 | Data plane. |
| 130 | Out | Allow | `Internet` | 80 | Certificate revocation checks. |

### `nsg-app` — application tier

| Pri | Dir | Action | Source | Dest port | Rationale |
|---|---|---|---|---|---|
| 100 | In | Allow | `snet-agw` | 443 | **Only** the gateway may reach the app tier. |
| 110 | In | Allow | `AzureLoadBalancer` | * | Health probes. |
| 120 | In | Allow | `AzureBastionSubnet` | 22 | Operator SSH via Bastion only. |
| 4096 | In | Deny | `*` | * | Default-deny. |

### `nsg-biz` — business tier

| Pri | Dir | Action | Source | Dest port | Rationale |
|---|---|---|---|---|---|
| 100 | In | Allow | `snet-app` | 8443 | App tier → business tier via ILB. |
| 110 | In | Allow | `AzureLoadBalancer` | * | Health probes. |
| 120 | In | Allow | `AzureBastionSubnet` | 22 | Operator access. |
| 4096 | In | Deny | `*` | * | Default-deny. |

The business tier is **not** reachable from `snet-agw`. Skipping a tier is a
lateral-movement path; the NSG makes the three-tier boundary real rather than
diagrammatic.

### `nsg-pep` — private endpoint subnet

| Pri | Dir | Action | Source | Dest port | Rationale |
|---|---|---|---|---|---|
| 100 | In | Allow | `snet-app`, `snet-biz` | 1433, 6380, 443 | SQL, Redis TLS, Key Vault/Storage. |
| 4096 | In | Deny | `*` | * | Default-deny. |

Requires `private_endpoint_network_policies = "Enabled"` on the subnet —
historically NSGs were ignored on private endpoint subnets, and the setting
must be switched on for these rules to take effect.

---

## 4. Routing

| Route table | Applied to | Routes |
|---|---|---|
| `rt-workload` | `snet-app`, `snet-biz`, `snet-db`, `snet-pep`, `snet-mgmt` | `0.0.0.0/0` → `VirtualAppliance` @ firewall private IP |
| `rt-fw` | `AzureFirewallSubnet` | `0.0.0.0/0` → `Internet` (explicit, prevents accidental loop) |
| *(none)* | `snet-agw` | See §2 of ARCHITECTURE.md — a default route here breaks AppGW v2. |
| *(none)* | `AzureBastionSubnet` | A default route here breaks Bastion. |

`disable_bgp_route_propagation` is enabled on `rt-workload` so a future
ExpressRoute/VPN gateway cannot advertise a route that bypasses the firewall.

---

## 5. Private DNS zones

One zone per service, each linked to the VNet with auto-registration
**disabled** (VMSS instances must not self-register into a zone reserved for
private endpoints).

| Zone | Service |
|---|---|
| `privatelink.database.windows.net` | Azure SQL |
| `privatelink.redis.cache.windows.net` | Azure Cache for Redis |
| `privatelink.vaultcore.azure.net` | Key Vault |
| `privatelink.blob.core.windows.net` | Storage — blob |
| `privatelink.file.core.windows.net` | Storage — file (if used) |

Each private endpoint registers its A record through
`private_dns_zone_group`, so DNS is managed by the platform rather than by
hand-maintained records.

**Zone placement:** the zones live in the networking RG, not the data RG.
Deleting the data tier must not orphan the DNS zones that other services and
future endpoints share.

---

## 6. Naming convention

Azure CAF abbreviations, pattern `<abbr>-<workload>-<env>-<loc>-<instance>`:

| Resource | Pattern | Example |
|---|---|---|
| Resource group | `rg-` | `rg-cloudcart-prod-eus-net` |
| Virtual network | `vnet-` | `vnet-cloudcart-prod-eus-001` |
| Subnet | `snet-` | `snet-app-prod-eus` |
| Network security group | `nsg-` | `nsg-app-prod-eus` |
| Route table | `rt-` | `rt-workload-prod-eus` |
| Public IP | `pip-` | `pip-agw-prod-eus-001` |
| Azure Firewall | `afw-` | `afw-cloudcart-prod-eus-001` |
| Bastion | `bas-` | `bas-cloudcart-prod-eus-001` |
| Application Gateway | `agw-` | `agw-cloudcart-prod-eus-001` |
| Load balancer (internal) | `lbi-` | `lbi-biz-prod-eus-001` |
| VM scale set | `vmss-` | `vmss-app-prod-eus-001` |
| Key Vault | `kv-` | `kv-cloudcart-prod-a1b2` |
| Storage account | `st` (no separators) | `stcloudcartprodeus001` |
| SQL server / database | `sql-` / `sqldb-` | `sql-cloudcart-prod-eus-001` |
| Redis | `redis-` | `redis-cloudcart-prod-eus-001` |
| Log Analytics | `log-` | `log-cloudcart-prod-eus-001` |
| Managed identity | `id-` | `id-app-prod-eus-001` |
| Private endpoint | `pep-` | `pep-sql-prod-eus-001` |
| Recovery Services vault | `rsv-` | `rsv-cloudcart-prod-eus-001` |
| Data collection rule | `dcr-` | `dcr-vminsights-prod-eus` |

Globally-unique names (storage, Key Vault, SQL server, Redis) get a
deterministic short suffix derived from the subscription and workload, so
names are stable across applies but do not collide between environments or
tenants. Storage accounts are constrained to 3–24 lowercase alphanumerics —
the `naming` module enforces this with a `validation` block rather than
letting the API reject it 30 seconds into an apply.

Location abbreviations: `eastus` → `eus`, `eastus2` → `eus2`,
`westeurope` → `weu`, `northeurope` → `neu`, `centralindia` → `inc`,
`southeastasia` → `sea`. Unknown regions fail validation rather than silently
producing a malformed name.
