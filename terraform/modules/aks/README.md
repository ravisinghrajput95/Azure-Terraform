# Module: `aks`

Azure Kubernetes Service cluster, HA-capable, with Entra-only authentication,
network policy, workload identity and Azure CNI Overlay.

Replaces the VM Scale Set tiers.

---

## What changes when tiers move into a cluster

This is the part worth understanding before reading any of the code.

In the VM Scale Set design, the three tiers were **separate subnets** with an
NSG between them. Azure enforced the boundary at the network layer: a packet
from the app subnet to the biz subnet on a port the NSG did not permit was
dropped by the platform, regardless of what either workload did.

In AKS, the tiers become **namespaces in one cluster, on one subnet**. The
boundary is a Kubernetes network policy, enforced by the cluster's own
dataplane. Trust moves from the platform into the cluster.

That is a real reduction in defence depth, and it is why `network_policy` is
**not optional** here — a precondition rejects `null`. Without a policy engine
every pod can reach every other pod regardless of namespace, and the tier
separation the architecture claims does not exist at all.

A second consequence catches people out: under Azure CNI Overlay a pod's
traffic leaving the cluster is **SNATed to its node address**. Any NSG rule
written against the old tier subnets stops matching. In this platform the
private endpoint NSG had to be re-sourced from the AKS node subnet, or every
call from a pod to SQL, Redis, Key Vault or Storage would have hit the deny.

---

## `outbound_type` must match reality

The most confusing failure in this module, so it is worth stating directly.

| Value | Requires | Failure if wrong |
|---|---|---|
| `loadBalancer` | nothing | Creates a second egress path if one exists |
| `userDefinedRouting` | route table already associated, carrying an egress route | `ExistingRouteTableNotAssociatedWithSubnet` |
| `userAssignedNATGateway` | NAT Gateway already on the subnet | — |
| `managedNATGateway` | nothing | AKS creates and owns a NAT Gateway |

`userDefinedRouting` is the **Azure Firewall** topology. Selecting it when a
NAT Gateway provides egress fails at create time with an error naming the route
table rather than the setting.

This platform attaches a NAT Gateway in the `networking` module, so
`userAssignedNATGateway` is correct.

---

## Self-managed egress must be declared to the API server allowlist

The worst failure this module can produce, because Azure reports no error
against the cluster at all.

On a public cluster restricted by `api_server_authorized_ip_ranges`, the nodes
reach the API server over its **public** endpoint, egressing from whatever
address the outbound path gives them. AKS appends that address to the allowlist
automatically **only when it owns the outbound path**:

| `outbound_type` | Egress address owned by | Appended automatically |
|---|---|---|
| `loadBalancer` (managed IPs) | AKS | yes |
| `managedNATGateway` | AKS | yes |
| `userAssignedNATGateway` | you | **no** |
| `userDefinedRouting` | you | **no** |

In the bottom two rows the egress address is yours to declare, via
`node_egress_ip_ranges`. Omit it and the nodes egress from an address their own
API server rejects:

```
cluster provisions ~15 min → kubelet cannot register
  → vmssCSE bootstrap times out, exit code 51
  → AKS deletes and recreates the node, every ~14 minutes, indefinitely
```

`provisioningState` sits at `Updating` and the cluster never converges. The
allowlist **blackholes** unauthorised sources rather than refusing them, so the
only symptom is a curl that transfers zero bytes for two minutes — which is why
this is a precondition rather than something to notice in a plan.

`api_server_authorized_ip_ranges` and `node_egress_ip_ranges` are separate
inputs, merged by the module, so that neither can be silently dropped by
editing the other.

```hcl
outbound_type                   = "userAssignedNATGateway"
api_server_authorized_ip_ranges = [for ip in var.deployer_ip_addresses : "${ip}/32"]
node_egress_ip_ranges           = ["${module.networking.nat_gateway_public_ip}/32"]
```

Note that operator addresses are usually residential and change without notice.
A cluster that was reachable last week can reject you today; that locks out
`kubectl`, but unlike the above it does not harm the cluster.

---

## Azure CNI Overlay

Pods draw addresses from `pod_cidr`, routed inside the cluster; the subnet
holds **node** addresses only.

Classic Azure CNI assigns every pod a subnet address. A `/22` with 1019 usable
addresses supports roughly 16 nodes at 60 pods each — and a subnet cannot be
resized once resources occupy it. Overlay removes that ceiling entirely, which
is why the node subnet here is a `/20` and still ample.

`pod_cidr` and `service_cidr` must not overlap the VNet, each other, or
anything peered. `dns_service_ip` must sit inside `service_cidr`; Azure rejects
a mismatch with a message naming neither value, so a precondition checks it.

---

## Usage

```hcl
module "aks" {
  source = "../../modules/aks"

  name                = "aks-cloudcart-dev-cus-001"
  dns_prefix          = "cloudcart-dev"
  resource_group_name = module.resource_group.names["app"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_tier = module.profile.profile.aks_sku_tier

  system_node_pool = {
    vm_size                    = module.profile.profile.vm_size
    node_count                 = module.profile.profile.instance_count
    zones                      = module.profile.profile.compute_zones
    only_critical_addons_taint = module.profile.enable_user_node_pool
  }

  user_node_pools = module.profile.enable_user_node_pool ? {
    app = {
      vm_size   = module.profile.profile.vm_size
      min_count = 1
      max_count = 3
      zones     = module.profile.profile.compute_zones
    }
  } : {}

  vnet_subnet_id = module.networking.subnet_ids["snet-aks-dev-cus"]

  network_plugin      = "azure"
  network_plugin_mode = "overlay"
  network_policy      = "azure"
  outbound_type       = "userAssignedNATGateway"

  private_cluster_enabled         = module.profile.aks_private_cluster
  api_server_authorized_ip_ranges = ["203.0.113.4/32"]
  node_egress_ip_ranges           = ["${module.networking.nat_gateway_public_ip}/32"]

  local_account_disabled       = true
  entra_admin_group_object_ids = var.aks_admin_group_object_ids

  workload_identity_enabled  = true
  log_analytics_workspace_id = module.log_analytics.id
}
```

## Key inputs

| Name | Default | Description |
|---|---|---|
| `sku_tier` | `"Free"` | Free carries **no control-plane SLA**. |
| `system_node_pool` | — | Min 2 vCPU / 4 GB per node; `B1s` does not qualify. |
| `user_node_pools` | `{}` | Separates workloads from CoreDNS. |
| `network_policy` | `"azure"` | **Not optional** — see above. |
| `network_plugin_mode` | `"overlay"` | |
| `outbound_type` | `"userAssignedNATGateway"` | Must match reality. |
| `private_cluster_enabled` | `false` | |
| `api_server_authorized_ip_ranges` | `[]` | Operator addresses. Empty on a public cluster = open internet. |
| `node_egress_ip_ranges` | `[]` | The cluster's **own** egress address, merged into the allowlist. Required with self-managed egress — see above. |
| `local_account_disabled` | `true` | |
| `entra_admin_group_object_ids` | `[]` | The only way in when local is disabled. |
| `workload_identity_enabled` | `true` | |
| `run_command_enabled` | `false` | Bypasses network restrictions. |

## Outputs

`id`, `name`, `fqdn`, `kubernetes_version`, `node_resource_group`,
`principal_id`, `kubelet_identity_object_id`, `oidc_issuer_url`,
`key_vault_secrets_provider_identity`, `is_highly_available`,
`availability_summary`, `has_user_node_pools`, `api_server_reachable_from`,
`network_policy`, `local_account_disabled`, `security_summary`

---

## Authentication

`local_account_disabled = true`. The built-in admin account authenticates with
a client certificate that **cannot be rotated, cannot be attributed to a
person, and bypasses Entra ID entirely**.

With it disabled, Entra group membership is the only way in — so a precondition
rejects an empty `entra_admin_group_object_ids`. Otherwise the cluster builds
successfully and **nobody can authenticate**, recoverable only by re-enabling
the local account through the Azure control plane.

A second precondition rejects a public cluster with no IP allowlist. The
Kubernetes API server would be reachable from the entire internet;
authentication still applies, but so does every authentication bypass ever
found in an API server.

---

## Two identities, routinely confused

| Output | What it is | Grant it |
|---|---|---|
| `principal_id` | Control plane identity | Access the cluster itself needs — managing a load balancer in another resource group |
| `kubelet_identity_object_id` | Node identity | **ACR pull.** This is the one that pulls images |

An `AcrPull` assignment on `principal_id` is a common mistake and silently
fails to fix image pulls.

Workloads use **neither**. They use Entra Workload Identity: a federated
service account token, referencing `oidc_issuer_url`. That is what replaces a
VM's managed identity once workloads live in pods, and it is how the app and
biz workloads reach SQL, Key Vault and Storage with no secret.

---

## Availability is reported, not assumed

`is_highly_available` requires **both** at least three nodes and at least three
zones. `availability_summary` renders it in plain language, so a single-node
development cluster never reads as production-shaped:

```
NOT highly available: 1 node(s) across 0 zone(s), Free SKU tier which
carries NO control-plane SLA. A node or zone fault takes the cluster with it.
```

---

## Cost

| Component | Approximate |
|---|---|
| Control plane, Free tier | **$0** — no SLA |
| Control plane, Standard tier | ~$73/month — 99.95% SLA |
| Nodes | Standard VM rates |
| Managed load balancer | ~$18/month when a `Service type=LoadBalancer` exists |

The Free tier is genuinely free, which makes it tempting well past the point it
should be. It has no SLA on the API server: a control plane outage is not
compensated and not committed against.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
