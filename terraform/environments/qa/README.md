# Environment: `qa`

Pre-production environment. **Written, validated and planning — not deployed,
and not deployable on the current subscription.**

This is the first environment in the repository whose configuration is complete
without having been applied, so the distinction matters more than usual: every
claim below about *behaviour* is a claim about a plan, not about a running
system. Nothing here has been verified against a live resource.

`tests/qa.tftest.hcl` is what makes the plan itself checkable. It runs under
`mock_provider` — no credentials, no backend, nothing created — and asserts
what qa adds over dev: Application Gateway ingress rather than a public load
balancer, its subnet never carrying a default route (AppGW v2 reports
permanently unhealthy behind one, with nothing at plan time to suggest why),
the HTTP-only degraded mode when no certificate is supplied and the HTTPS
listener when one is, and an uncapped workspace. It does not prove Azure
accepts the plan; it proves the composition is internally coherent.

---

## Why it is not deployed

Two independent blockers, both measured against the subscription rather than
estimated.

### 1. vCPU quota — the hard one

```
$ az vm list-usage -l centralus
cores        used=2   limit=4
```

The regional limit is **4 vCPU in total**, it applies across every VM family at
once, and dev's AKS node already holds 2. That leaves **2**.

The `profile` module refuses the environment at plan time, before any Azure
call:

```
Environment profile "qa" is not internally coherent:
Peak vCPU footprint is 8 (2 vCPU x 4 instances x 1 tiers) but the
subscription quota is 4. Scale-out would fail silently under load.
```

qa's shape is the reason:

| Pool | Nodes | vCPU |
|---|---|---|
| System (`Standard_D2s_v5`, zones 1–2) | 2 | 4 |
| User pool, autoscaling 1→3 | 1 minimum | 2 |
| **Steady-state minimum** | | **6** |
| **Peak, at autoscale maximum** | | **8** |

Six is the floor and eight is what the guardrail measures, because a maximum
the cluster cannot reach is an autoscaler that stops silently under exactly the
load it exists for. Both exceed 4. On a `FreeTrial` subscription with the
spending limit on, a quota increase **cannot be requested** — upgrading to
Pay-As-You-Go is a prerequisite.

### 2. Cost

`indicative_monthly_cost_usd` from the plan: **~$1,062/month**, against a $200
credit already carrying ~$212/month of dev. The two largest items are
structural rather than trimmable:

| Component | Approx/month | Why it is in qa and not dev |
|---|---|---|
| Application Gateway WAF v2 | ~$260 | dev has no WAF at all; there is no inexpensive tier |
| Azure Bastion **Basic** | ~$140 | dev uses the free Developer SKU, which cannot reach a private cluster properly |
| AKS Standard SKU tier | ~$73 | dev runs Free, which carries **no** control-plane SLA |
| 3 × `Standard_D2s_v5` | ~$210 | dev runs one node |
| SQL `GP_Gen5_2` provisioned | ~$370 | dev runs serverless, which pauses when idle |

Treat these as order-of-magnitude planning figures, per the `profile` module's
own caveat — not a quote.

---

## What would have to change to run it

In rough order of how much they cost you:

1. **Upgrade to Pay-As-You-Go and raise the regional vCPU quota** to at least 8.
   Nothing else unblocks the cluster.
2. Accept the bill, or override the profile to shrink it. A
   `profile_overrides` that drops the user node pool, sets
   `instance_count = 1` and moves Bastion to Developer would fit 2 vCPU — but
   at that point qa is dev with a WAF in front, and the things qa exists to
   test (failover, autoscaling, private ingress) are exactly what was removed.
3. Supply a TLS certificate — see below.

---

## What qa tests that dev cannot

This is the justification for the environment existing, and it is worth being
concrete about, because "another environment" is not a reason on its own.

| Capability | dev | qa |
|---|---|---|
| AKS API server | Public, IP-allowlisted | **Private** |
| Ingress | None — no WAF, no gateway | **Application Gateway WAF v2**, Detection mode |
| Cluster HA | 1 node, 0 zones | 2 nodes across 2 zones |
| Workload isolation | System pool only | Dedicated user node pool |
| Autoscaling | Off — so `cluster_autoscaler_*` metrics publish nothing | **On**, so those alert rules can actually fire |
| Redis | Single node, no SLA | **High availability** — can actually fail over |
| Data planes | Public, IP-restricted | **Private endpoint only** |
| Log ingestion | Capped at 0.5 GB/day, hit daily | **Uncapped** |
| AKS audit logs | `kube-audit` dropped to survive the cap | **Collected** |

The last two are linked and matter: dev cannot keep its Kubernetes API audit
trail, because `kube-audit` alone is roughly twice dev's entire daily ingestion
budget. qa is where a security question gets a complete answer.

---

## Operational consequences of the private posture

Three things behave differently here, all of them consequences of doing the
correct thing, and all of them the kind of surprise that reads as a fault:

- **`kubectl` only works from inside the VNet.** The cluster is private.
  `az aks get-credentials` succeeds from anywhere; every call after it then
  times out resolving the API server. Use Bastion or a runner on a workload
  subnet. This is why qa runs Bastion Basic rather than the free Developer
  SKU — Developer offers browser sessions only, with no native client
  tunneling.
- **Applies that touch a data plane must run from inside the VNet.** Key Vault
  and Storage are private-endpoint only. Creating the `app-data` container and
  writing any secret are *data*-plane calls: they fail from an operator laptop
  with 403 or a timeout, while every control-plane operation in the same apply
  succeeds. Subscription Owner does not help — a data-plane RBAC role is
  required and is granted in `main.tf`.
- **The TLS certificate is an input, not a resource.** A root module declares
  no resources, so the certificate is created in qa's Key Vault out of band and
  passed as `application_gateway_certificate_secret_id`. Left unset, the
  gateway deploys **HTTP-only** — a deliberate degraded mode so the
  environment can stand up before a certificate exists. The
  `ingress_is_encrypted` output states which mode is live rather than leaving
  it to be discovered.

Also note `waf_posture`: qa runs the WAF in **Detection**, which logs what
Prevention would have blocked and blocks nothing. That is the right starting
point for an untuned managed rule set and the wrong place to stop.

---

## Usage

```bash
terraform init -backend-config=backend.conf
terraform validate
terraform plan -var-file=terraform.tfvars -out=tfplan
```

`backend.conf` and `terraform.tfvars` are gitignored; copy the `.example`
files. The state container `tfstate-qa` exists — it was created when
`bootstrap/` was adopted on 2026-08-14.

A plan on the real quota **fails**, by design, on the profile precondition
above. To exercise the rest of the composition, raise the quota
hypothetically — this changes nothing in Azure:

```bash
terraform plan -var-file=terraform.tfvars -var="subscription_vcpu_quota=8"
```

That plans **146 resources**, including the `application-gateway` module, which
this is the first environment ever to instantiate.

---

## Addressing

`10.20.0.0/16`, spaced from dev's `10.10.0.0/16` and prod's `10.30.0.0/16` so a
future peering cannot collide.

| Subnet | CIDR | Notes |
|---|---|---|
| `AzureBastionSubnet` | `10.20.0.128/26` | Allocated — Bastion Basic occupies it |
| `snet-agw-qa-cus` | `10.20.1.0/24` | Allocated — dev reserves this and leaves it empty |
| `snet-app-qa-cus` | `10.20.4.0/22` | |
| `snet-biz-qa-cus` | `10.20.8.0/22` | |
| `snet-db-qa-cus` | `10.20.12.0/24` | Reserved; PaaS SQL uses a private endpoint |
| `snet-pep-qa-cus` | `10.20.13.0/24` | `NetworkSecurityGroupEnabled` — without it the NSG rules are inert |
| `snet-mgmt-qa-cus` | `10.20.14.0/24` | |
| `snet-aks-qa-cus` | `10.20.16.0/20` | Node addresses only; pods use `pod_cidr` |

Reserved and not allocated: `AzureFirewallSubnet` `10.20.0.0/26`,
`AzureFirewallManagementSubnet` `10.20.0.64/26`, `GatewaySubnet`
`10.20.0.192/26`.

Cluster-internal ranges are `pod_cidr = 10.244.0.0/16` and
`service_cidr = 172.17.0.0/16`, deliberately different from dev's, so peering
the two environments later is a routing decision rather than a renumbering
exercise.

---

## Differences from `dev`'s root module worth knowing

- **No `snet-aks-qa-cus` literals.** dev hardcodes `"snet-aks-dev-cus"`,
  `"nsg-aks-dev-cus"` and a bastion NSG named `"nsg-bastion-dev-eus"` — which
  says `eus` while the environment runs in Central US. qa derives all of them
  from `local.environment` and `module.naming.location_short`.
- **The private endpoint NSG allows 10000, not 6380.** Azure Managed Redis
  listens on 10000; 6380 is the classic Azure Cache for Redis port. dev's rule
  names 6380 and would not match Managed Redis traffic.
- **No `pods-pending` threshold override.** dev needs one because its single
  node leaves two DaemonSet replicas permanently `Pending`. With a user node
  pool that standing backlog should not exist — but that is a prediction, and
  the threshold should be re-measured against the running cluster before it is
  trusted.
- **Both daily-cap alerts are off**, derived from the cap rather than from the
  environment name. qa is uncapped, so the monitor module's preconditions would
  reject them: an uncapped workspace never emits the `OverQuota` record the
  first rule matches, and has no cap for the second to measure against.
