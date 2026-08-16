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

### `entra_admin_group_object_ids` takes GROUPS. A user object ID is accepted and never matches.

The name says group and Azure means it. AKS binds each entry as a Kubernetes
**group** subject, matched against the `groups` claim of the caller's token. A
*user* object ID is a well-formed GUID, so Azure accepts it, the cluster
provisions, the portal shows an admin configured — and the binding matches
nobody, because a user's own object ID never appears in their own `groups`
claim.

Combined with `local_account_disabled = true`, that is a cluster with no way
in. It is not recoverable by fixing the variable either: Azure rejects clearing
the field outright.

```
Operation resetAADProfile is not allowed for AKS cluster with Azure AD integration
```

The field can only be **replaced** with a real group, never emptied.

Make the trap visible with the token itself — this is the check worth running,
because it shows what the API server actually sees:

```console
$ kubectl auth whoami
ATTRIBUTE    VALUE
Username     dbe58829-...          # the user
Groups       [f544f25d-... system:authenticated]
```

The object ID configured as an "admin group" is the one in `Username`. It is
absent from `Groups`. That is the whole failure, in four lines.

### The access path that works is Azure RBAC, not the admin group

`aad_rbac_enabled = true` routes authorization through Azure RBAC, where access
comes from a **role assignment**, not from group membership:

```bash
az role assignment create \
  --assignee <user-or-group-object-id> \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope <cluster-resource-id>
```

Owner and Contributor do **not** grant this. They carry `dataActions: []`, so
they permit managing the cluster resource and confer no `kubectl` access
whatsoever. This surprises people who have full control of the subscription and
still get `Forbidden` — the control plane and the data plane are separate
permission systems.

**Verified end to end against dev on 2026-08-14**, not inferred from a plan:
`kubectl get nodes` and `get pods -A` return live data, and a namespace was
created, read back and deleted. `can-i` confirms `get secrets` cluster-wide,
`create deployments`, `delete namespaces` and `create clusterrolebindings`.

Two notes for whoever runs this next:

- `kubectl auth can-i --list` is **not** a valid way to check access here. Azure
  RBAC is a webhook authorizer and cannot enumerate its own rules, so the list
  comes back looking almost empty even for a full cluster admin. It emits
  `webhook authorizer does not support user rule resolution` and people read the
  short list as a denial. Test a concrete verb instead.
- `kubelogin convert-kubeconfig -l azurecli` reuses an existing `az` session, so
  no interactive device-code login is needed on a machine that is already
  signed in.

Because the working grant is a role assignment, the inert user object ID still
sitting in `entra_admin_group_object_ids` grants nothing to anyone and is
harmless. Replacing it with a directory role that *does* appear in the `groups`
claim — Global Administrator resolves as one — would restore a second,
much broader admin path that bypasses the scoped, auditable role assignment.
Leave it inert.

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

### The addons fill the node before any workload exists

Measured on dev, 2026-08-14, on its single `Standard_D2s_v4`:

```
cpu requests: 1826m (96% of allocatable)     memory: 3200Mi (48%)
```

Two addon pods have been `Pending` since the cluster was built, both
`Insufficient cpu`: the second `azure-wi-webhook-controller-manager` replica and
`eraser-controller-manager`. Nothing is wrong with them — there is no room.

The addons enabled here are not free in the way "managed addon" suggests.
Gatekeeper/Azure Policy, `ama-logs`, the secrets-store CSI driver, workload
identity, CNS and NPM together reserve almost the whole node. **A workload
deployed to dev today will sit `Pending` forever**, and the cluster will report
`Succeeded` and `Running` throughout.

This is a consequence of the 4 vCPU quota, not a defect: a 2 vCPU node cannot
host this addon set plus an application. It is recorded because the failure
presents as "my deployment does nothing" with a healthy-looking cluster. The
fix is capacity — a second node pool, a larger SKU, or dropping addons — all of
which need quota this subscription does not have.

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
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_kubernetes_cluster.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_role_assignment.cluster_admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_api_server_authorized_ip_ranges"></a> [api\_server\_authorized\_ip\_ranges](#input\_api\_server\_authorized\_ip\_ranges) | Public CIDRs permitted to reach the API server. Only meaningful on a public cluster. An empty list on a public cluster leaves the Kubernetes control plane open to the entire internet. Operator addresses only — the cluster's own egress address belongs in node\_egress\_ip\_ranges. | `list(string)` | `[]` | no |
| <a name="input_auto_scaler_profile"></a> [auto\_scaler\_profile](#input\_auto\_scaler\_profile) | Cluster autoscaler tuning. scale\_down\_unneeded is how long a node must be idle before removal — short values save money and cause churn. | <pre>object({<br/>    balance_similar_node_groups   = optional(bool, true)<br/>    expander                      = optional(string, "random")<br/>    scale_down_unneeded           = optional(string, "10m")<br/>    scale_down_delay_after_add    = optional(string, "10m")<br/>    skip_nodes_with_local_storage = optional(bool, false)<br/>    skip_nodes_with_system_pods   = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_automatic_upgrade_channel"></a> [automatic\_upgrade\_channel](#input\_automatic\_upgrade\_channel) | Automatic upgrade channel: "patch", "stable", "rapid", "node-image" or null. "patch" applies security patches within the pinned minor version and is the sane default. Null means nothing upgrades and the cluster eventually falls out of support. | `string` | `"patch"` | no |
| <a name="input_azure_policy_enabled"></a> [azure\_policy\_enabled](#input\_azure\_policy\_enabled) | Enable the Azure Policy add-on, which applies Gatekeeper constraints to admission. This is how a rule such as "no privileged containers" becomes enforceable rather than documented. | `bool` | `true` | no |
| <a name="input_azure_rbac_enabled"></a> [azure\_rbac\_enabled](#input\_azure\_rbac\_enabled) | Use Azure RBAC for Kubernetes authorisation, so access is granted through Azure role assignments rather than in-cluster RoleBindings. Makes cluster access visible to the same access review as everything else. | `bool` | `true` | no |
| <a name="input_cluster_admin_principal_ids"></a> [cluster\_admin\_principal\_ids](#input\_cluster\_admin\_principal\_ids) | Object IDs granted cluster-admin through AZURE RBAC, by role assignment of<br/>"Azure Kubernetes Service RBAC Cluster Admin" at the cluster scope.<br/><br/>This is the path azure\_rbac\_enabled actually describes, and unlike<br/>entra\_admin\_group\_object\_ids it accepts users, groups and service<br/>principals alike.<br/><br/>Worth knowing: subscription Owner and Contributor do NOT grant Kubernetes<br/>API access. Both carry `dataActions: []`, and Kubernetes authorisation<br/>lives entirely in dataActions. An Owner who cannot run kubectl is the<br/>expected behaviour, not a misconfiguration. | `set(string)` | `[]` | no |
| <a name="input_cost_analysis_enabled"></a> [cost\_analysis\_enabled](#input\_cost\_analysis\_enabled) | Surface per-namespace cost allocation in Cost Management. Requires the Standard or Premium SKU tier. | `bool` | `false` | no |
| <a name="input_dns_prefix"></a> [dns\_prefix](#input\_dns\_prefix) | DNS prefix for the API server FQDN. Immutable — changing it replaces the cluster. | `string` | n/a | yes |
| <a name="input_dns_service_ip"></a> [dns\_service\_ip](#input\_dns\_service\_ip) | Address of the cluster DNS service. Must sit inside service\_cidr and is conventionally its .10. | `string` | `"172.16.0.10"` | no |
| <a name="input_entra_admin_group_object_ids"></a> [entra\_admin\_group\_object\_ids](#input\_entra\_admin\_group\_object\_ids) | Entra GROUP object IDs granted cluster-admin through the AKS AAD profile.<br/><br/>These must be groups. AKS binds them as Kubernetes `Group` subjects, matched<br/>against the `groups` claim in the caller's token. A USER object ID here is<br/>accepted by Azure, creates a binding, and never matches anything — a user's<br/>own object ID appears in the `oid` claim, never in `groups`. Terraform<br/>cannot tell the two apart without a directory lookup, so this cannot be<br/>validated here; grant individual users through cluster\_admin\_principal\_ids<br/>instead. | `list(string)` | `[]` | no |
| <a name="input_image_cleaner_enabled"></a> [image\_cleaner\_enabled](#input\_image\_cleaner\_enabled) | Periodically remove unused images from nodes, including vulnerable ones that no longer run anything. | `bool` | `true` | no |
| <a name="input_key_vault_secrets_provider_enabled"></a> [key\_vault\_secrets\_provider\_enabled](#input\_key\_vault\_secrets\_provider\_enabled) | Enable the Key Vault CSI driver so pods mount secrets from Key Vault rather than holding Kubernetes Secrets, which are only base64-encoded at rest by default. | `bool` | `true` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Control plane version. Null takes the region default, which moves — pin it in any environment where an unannounced control plane upgrade would be unwelcome. | `string` | `null` | no |
| <a name="input_local_account_disabled"></a> [local\_account\_disabled](#input\_local\_account\_disabled) | Disable the cluster's built-in local admin account. TRUE is the correct posture: that account authenticates with a client certificate that cannot be rotated, cannot be attributed to a person, and bypasses Entra ID entirely. Requires Entra RBAC to be configured, or nobody can authenticate. | `bool` | `true` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | Workspace for Container Insights. Null disables the add-on, which means no container logs or node metrics — the cluster is then observable only through kubectl. | `string` | `null` | no |
| <a name="input_maintenance_window_hours"></a> [maintenance\_window\_hours](#input\_maintenance\_window\_hours) | Hours of the day (UTC) when automatic upgrades may run. Empty means Azure chooses, which can be during business hours. | `list(number)` | `[]` | no |
| <a name="input_name"></a> [name](#input\_name) | Cluster name. | `string` | n/a | yes |
| <a name="input_network_plugin"></a> [network\_plugin](#input\_network\_plugin) | "azure" or "none". Azure CNI is required for network policy support. | `string` | `"azure"` | no |
| <a name="input_network_plugin_mode"></a> [network\_plugin\_mode](#input\_network\_plugin\_mode) | "overlay" draws pod addresses from pod\_cidr instead of the subnet. Null uses classic CNI, which consumes a subnet address per pod and caps cluster size at the subnet size. | `string` | `"overlay"` | no |
| <a name="input_network_policy"></a> [network\_policy](#input\_network\_policy) | Network policy engine: "azure", "calico", "cilium" or null.<br/><br/>NOT optional in this platform. Moving from VM Scale Sets to AKS moves the<br/>three-tier boundary from subnets and NSGs into the cluster. Without a<br/>policy engine, every pod can reach every other pod regardless of namespace,<br/>and the tier separation the architecture claims does not exist. | `string` | `"azure"` | no |
| <a name="input_node_egress_ip_ranges"></a> [node\_egress\_ip\_ranges](#input\_node\_egress\_ip\_ranges) | Public CIDRs the cluster's own nodes egress from, merged into the API server<br/>allowlist.<br/><br/>Required whenever the API server is public, restricted by an allowlist, and<br/>egress is self-managed (outbound\_type userDefinedRouting or<br/>userAssignedNATGateway). AKS appends the cluster's egress address to the<br/>allowlist automatically ONLY when it owns the outbound path itself<br/>(loadBalancer with managed IPs, or managedNATGateway). With a user-assigned<br/>NAT Gateway or a UDR it does not, and nothing in the plan says so.<br/><br/>Omitting it produces a cluster that provisions for ~15 minutes and then<br/>crash-loops: kubelet cannot reach its own API server, the vmssCSE bootstrap<br/>times out with exit code 51, and AKS deletes and recreates the node roughly<br/>every 14 minutes indefinitely. The allowlist blackholes unauthorised sources<br/>rather than refusing them, so the only symptom is a curl that transfers zero<br/>bytes. | `list(string)` | `[]` | no |
| <a name="input_node_resource_group"></a> [node\_resource\_group](#input\_node\_resource\_group) | Name for the Azure-managed resource group holding node VMs, disks and load balancers. AKS creates and owns it; do not put anything in it, because AKS reconciles its contents. Null lets Azure generate a MC\_* name. | `string` | `null` | no |
| <a name="input_oidc_issuer_enabled"></a> [oidc\_issuer\_enabled](#input\_oidc\_issuer\_enabled) | Publish an OIDC issuer URL. Required by workload identity. | `bool` | `true` | no |
| <a name="input_outbound_type"></a> [outbound\_type](#input\_outbound\_type) | How cluster egress is provided. This must MATCH how the subnet actually<br/>gets out, and the wrong choice fails at create time with an error naming<br/>the route table rather than the setting:<br/><br/>  loadBalancer            AKS provisions its own public load balancer for<br/>                          egress. Creates a second outbound path if<br/>                          something else already provides one.<br/><br/>  userDefinedRouting      Requires a route table ALREADY associated with<br/>                          the subnet and carrying an egress route. This is<br/>                          the Azure Firewall topology. Selecting it when a<br/>                          NAT Gateway provides egress fails with<br/>                          ExistingRouteTableNotAssociatedWithSubnet.<br/><br/>  userAssignedNATGateway  Uses a NAT Gateway already associated with the<br/>                          subnet. This is the correct value whenever the<br/>                          networking module attached one.<br/><br/>  managedNATGateway       AKS creates and owns a NAT Gateway. | `string` | `"userAssignedNATGateway"` | no |
| <a name="input_pod_cidr"></a> [pod\_cidr](#input\_pod\_cidr) | Address range pods draw from under overlay networking. Must NOT overlap the VNet, any peered network, or the service CIDR — it is routed inside the cluster only. | `string` | `"192.168.0.0/16"` | no |
| <a name="input_private_cluster_enabled"></a> [private\_cluster\_enabled](#input\_private\_cluster\_enabled) | Make the API server reachable only from inside the VNet. The correct posture — and it means kubectl works only from the VNet or through Bastion, so an operator laptop loses direct access. | `bool` | `false` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "app" lifecycle scope. | `string` | n/a | yes |
| <a name="input_run_command_enabled"></a> [run\_command\_enabled](#input\_run\_command\_enabled) | Allow `az aks command invoke`, which runs arbitrary commands in the cluster through the Azure control plane. Convenient for reaching a private cluster, and a control-plane path that bypasses network restrictions entirely — so it should be a deliberate choice. | `bool` | `false` | no |
| <a name="input_service_cidr"></a> [service\_cidr](#input\_service\_cidr) | Address range for Kubernetes Service ClusterIPs. Must not overlap the VNet or pod\_cidr. | `string` | `"172.16.0.0/16"` | no |
| <a name="input_sku_tier"></a> [sku\_tier](#input\_sku\_tier) | "Free", "Standard" or "Premium". Free carries NO control-plane SLA and is limited to a smaller node count. Standard adds the uptime SLA and is the minimum for anything that matters. | `string` | `"Free"` | no |
| <a name="input_system_node_pool"></a> [system\_node\_pool](#input\_system\_node\_pool) | System node pool configuration.<br/><br/>`only_critical_addons_taint` adds CriticalAddonsOnly=true:NoSchedule, which<br/>keeps application workloads off the system pool. Correct wherever a user<br/>pool exists; impossible where one does not, because then nothing could be<br/>scheduled at all. | <pre>object({<br/>    name                       = optional(string, "system")<br/>    vm_size                    = string<br/>    node_count                 = optional(number, 1)<br/>    auto_scaling_enabled       = optional(bool, false)<br/>    min_count                  = optional(number)<br/>    max_count                  = optional(number)<br/>    zones                      = optional(list(string), [])<br/>    os_disk_size_gb            = optional(number, 64)<br/>    os_disk_type               = optional(string, "Managed")<br/>    only_critical_addons_taint = optional(bool, false)<br/>    max_pods                   = optional(number, 60)<br/>  })</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_user_node_pools"></a> [user\_node\_pools](#input\_user\_node\_pools) | Additional node pools for application workloads. Separating workloads from the system pool means a runaway pod cannot starve CoreDNS. | <pre>map(object({<br/>    vm_size              = string<br/>    node_count           = optional(number, 1)<br/>    auto_scaling_enabled = optional(bool, true)<br/>    min_count            = optional(number, 1)<br/>    max_count            = optional(number, 3)<br/>    zones                = optional(list(string), [])<br/>    os_disk_size_gb      = optional(number, 64)<br/>    os_disk_type         = optional(string, "Managed")<br/>    max_pods             = optional(number, 60)<br/>    node_labels          = optional(map(string), {})<br/>    node_taints          = optional(list(string), [])<br/>    spot_enabled         = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_vnet_subnet_id"></a> [vnet\_subnet\_id](#input\_vnet\_subnet\_id) | Subnet for cluster nodes. With overlay networking this holds node addresses only, not pod addresses. | `string` | n/a | yes |
| <a name="input_workload_identity_enabled"></a> [workload\_identity\_enabled](#input\_workload\_identity\_enabled) | Enable Entra Workload Identity, letting pods authenticate as a managed identity through a federated service account token. This is what replaces a VM's managed identity when workloads move into pods — and it is how the app and biz workloads reach SQL, Key Vault and Storage without a secret. | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_admin_access_summary"></a> [admin\_access\_summary](#output\_admin\_access\_summary) | How an operator actually authenticates to the API server, in plain language. Reported because a cluster nobody can reach looks identical to one that works until someone tries. |
| <a name="output_api_server_authorized_ip_ranges"></a> [api\_server\_authorized\_ip\_ranges](#output\_api\_server\_authorized\_ip\_ranges) | The allowlist actually applied to the API server: operator addresses merged with the cluster's own egress address. Reported because the second half is invisible in the calling configuration and its absence crash-loops the node pool rather than failing the apply. |
| <a name="output_api_server_reachable_from"></a> [api\_server\_reachable\_from](#output\_api\_server\_reachable\_from) | Who can reach the Kubernetes API server, in plain language. |
| <a name="output_availability_summary"></a> [availability\_summary](#output\_availability\_summary) | Plain-language availability posture. |
| <a name="output_cluster_admin_principal_ids"></a> [cluster\_admin\_principal\_ids](#output\_cluster\_admin\_principal\_ids) | Principals holding Azure RBAC cluster-admin on this cluster. Distinct from entra\_admin\_group\_object\_ids, which binds Kubernetes GROUP subjects and silently matches nothing when given a user object ID. |
| <a name="output_fqdn"></a> [fqdn](#output\_fqdn) | API server FQDN. On a private cluster this resolves only inside the VNet. |
| <a name="output_has_user_node_pools"></a> [has\_user\_node\_pools](#output\_has\_user\_node\_pools) | Whether workloads run on a pool separate from the system components. False means a runaway pod shares a node with CoreDNS. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the cluster. Diagnostic settings and role assignments target this. |
| <a name="output_is_highly_available"></a> [is\_highly\_available](#output\_is\_highly\_available) | Whether the cluster is genuinely HA: at least three nodes across at least three availability zones. Reported rather than assumed, so a single-node development cluster never reads as production-shaped. |
| <a name="output_key_vault_secrets_provider_identity"></a> [key\_vault\_secrets\_provider\_identity](#output\_key\_vault\_secrets\_provider\_identity) | Object ID of the Key Vault CSI driver's identity, or null when the add-on is disabled. Grant this Key Vault Secrets User so pods can mount secrets rather than holding Kubernetes Secrets, which are only base64-encoded at rest. |
| <a name="output_kubelet_identity_object_id"></a> [kubelet\_identity\_object\_id](#output\_kubelet\_identity\_object\_id) | Kubelet identity, distinct from the control plane identity. This is the one that pulls images, so an ACR pull role assignment goes here rather than on principal\_id — a common and confusing mix-up. |
| <a name="output_kubernetes_version"></a> [kubernetes\_version](#output\_kubernetes\_version) | Control plane version actually running, which may be ahead of the pinned version if an upgrade channel applied a patch. |
| <a name="output_local_account_disabled"></a> [local\_account\_disabled](#output\_local\_account\_disabled) | Whether the built-in local admin account is disabled. True means Entra group membership is the only way in, and the unrotatable, unattributable cluster certificate cannot be used. |
| <a name="output_name"></a> [name](#output\_name) | Cluster name. |
| <a name="output_network_policy"></a> [network\_policy](#output\_network\_policy) | Policy engine enforcing pod-to-pod rules. This is what carries the tier boundary now that it no longer lives in NSGs between subnets. |
| <a name="output_node_resource_group"></a> [node\_resource\_group](#output\_node\_resource\_group) | Azure-managed resource group holding node VMs, disks and load balancers. AKS owns and reconciles it — anything placed there by hand is liable to be removed. |
| <a name="output_oidc_issuer_url"></a> [oidc\_issuer\_url](#output\_oidc\_issuer\_url) | OIDC issuer URL. A federated identity credential on a user-assigned identity references this plus a service account subject, which is what lets a pod authenticate as that identity with no secret. |
| <a name="output_principal_id"></a> [principal\_id](#output\_principal\_id) | Control plane managed identity. Grant this access when the cluster itself must reach an Azure resource — attaching an ACR, or managing a load balancer in another resource group. |
| <a name="output_security_summary"></a> [security\_summary](#output\_security\_summary) | Consolidated posture, so the interacting settings can be reviewed without reading the configuration. |
<!-- END_TF_DOCS -->
