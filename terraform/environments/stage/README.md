# Environment: `stage`

Pre-production environment. **Written, validates and plans — never applied, and
not deployable on the current subscription.**

Everything below is a claim about a plan. Nothing here has run, and `stage`
carries a second layer of that: the `firewall` module its egress depends on has
never been applied either, anywhere.

---

## The reason stage exists

`qa` already covers a private cluster, WAF ingress, HA and private data planes.
stage adds the one thing qa cannot: **egress through an Azure Firewall instead
of a NAT Gateway.**

| | dev / qa | stage |
|---|---|---|
| Egress | NAT Gateway, ~$35/month | **Azure Firewall Standard, ~$913/month** |
| Filtering | None — any pod reaches any address | **FQDN and network rules, default deny** |
| Routing | No UDR; NAT Gateway attaches to the subnet | **`0.0.0.0/0` → firewall private IP** |
| AKS `outbound_type` | `userAssignedNATGateway` | **`userDefinedRouting`** |
| WAF mode | Detection (qa) | **Prevention** |
| SQL | GP / serverless | **BC_Gen5_2, zone redundant, LTR on** |
| Storage | LRS | **GZRS** |
| Cluster | 2 nodes / 2 zones (qa) | **3 nodes / 3 zones** |

The profile is explicit that the topology, the UDRs and the egress rules are
what stage validates — the tier below Premium is deliberate, because routing
and the rule model are identical across Standard and Premium. What stage does
*not* validate is inspection: IDPS and TLS inspection are Premium-only and
belong to prod.

---

## Why it is not deployed

**Quota.** The `profile` module refuses it before any Azure call:

```
Peak vCPU footprint is 16 (2 vCPU x 8 instances x 1 tiers) but the
subscription quota is 4.
```

Steady state is 10 vCPU (three `Standard_D2s_v5` system nodes plus two user
nodes); 16 is the autoscale peak. The regional limit is 4, and dev holds 2.

**Cost.** `indicative_monthly_cost_usd` from the plan: **~$2,148/month**, of
which the firewall alone is ~$913.

---

## Egress is the part that is easy to get wrong

Three things had to change together, and getting any one of them wrong
produces a cluster that never converges rather than an error that says why.

1. **`outbound_type = "userDefinedRouting"`**, not `userAssignedNATGateway`.
   The wrong value fails at create with
   `ExistingRouteTableNotAssociatedWithSubnet` — an error naming the route
   table rather than the setting.
2. **The route table must already carry `0.0.0.0/0` → firewall and be
   associated with the node subnet** before the first node starts. `depends_on`
   on the AKS module makes that ordering explicit rather than hoping the graph
   gets there first.
3. **The firewall must already permit the bootstrap traffic.** A firewall
   denies by default. Nodes that cannot reach the control plane, MCR or the
   Ubuntu repositories fail `vmssCSE`, and AKS deletes and recreates them every
   ~14 minutes indefinitely — the crash-loop in `ARCHITECTURE.md` §6b, from a
   different cause.

The rules in `main.tf` are therefore not illustrative. A missing FQDN is a
cluster that never comes up.

Note also what the network rule collection deliberately **does not** contain: a
broad Allow on 443. Azure evaluates every network rule before any application
rule, so one would make the FQDN allow-lists unreachable while leaving them
visible and correct-looking. The `firewall` module rejects that combination.

---

## Also inherited from qa, and still true here

- **`kubectl` only works from inside the VNet** — the cluster is private.
- **Applies touching a data plane must run from inside the VNet** — Key Vault
  and Storage are private-endpoint only.
- **The TLS certificate is an input, not a resource.** Unset, the gateway
  deploys HTTP-only and `ingress_is_encrypted` says so. In an environment
  running the WAF in **Prevention**, shipping it HTTP-only would be an odd
  combination — the WAF blocks what it matches, on traffic that was never
  encrypted.

---

## Usage

```bash
terraform init -backend-config=backend.conf
terraform plan -var-file=terraform.tfvars                          # fails on quota, by design
terraform plan -var-file=terraform.tfvars -var="subscription_vcpu_quota=16"
```

The second form plans **143 resources** and changes nothing in Azure. The state
container `tfstate-stage` exists — created when `bootstrap/` was adopted.

---

## Addressing

`10.40.0.0/16`. Unlike dev and qa, `AzureFirewallSubnet` is **allocated**.

| Subnet | CIDR |
|---|---|
| `AzureFirewallSubnet` | `10.40.0.0/26` |
| `AzureBastionSubnet` | `10.40.0.128/26` |
| `snet-agw-stage-cus` | `10.40.1.0/24` |
| `snet-app-stage-cus` | `10.40.4.0/22` |
| `snet-biz-stage-cus` | `10.40.8.0/22` |
| `snet-db-stage-cus` | `10.40.12.0/24` |
| `snet-pep-stage-cus` | `10.40.13.0/24` |
| `snet-mgmt-stage-cus` | `10.40.14.0/24` |
| `snet-aks-stage-cus` | `10.40.16.0/20` |

Reserved, not allocated: `AzureFirewallManagementSubnet` `10.40.0.64/26` —
needed only for the Basic tier or forced tunnelling — and `GatewaySubnet`
`10.40.0.192/26`.

No subnet associates a NAT Gateway; `enable_nat_gateway` is false in the
profile. A NAT Gateway attached to a subnet takes precedence over a UDR, so the
two are alternatives rather than layers.
