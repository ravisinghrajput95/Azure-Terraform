################################################################################
# Placement
################################################################################

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group. Should be the \"app\" lifecycle scope."
  type        = string
}

variable "location" {
  description = "Azure region, normalised form."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

variable "dns_prefix" {
  description = "DNS prefix for the API server FQDN. Immutable — changing it replaces the cluster."
  type        = string
}

variable "node_resource_group" {
  description = "Name for the Azure-managed resource group holding node VMs, disks and load balancers. AKS creates and owns it; do not put anything in it, because AKS reconciles its contents. Null lets Azure generate a MC_* name."
  type        = string
  default     = null
}

################################################################################
# Version
################################################################################

variable "kubernetes_version" {
  description = "Control plane version. Null takes the region default, which moves — pin it in any environment where an unannounced control plane upgrade would be unwelcome."
  type        = string
  default     = null
}

variable "automatic_upgrade_channel" {
  description = "Automatic upgrade channel: \"patch\", \"stable\", \"rapid\", \"node-image\" or null. \"patch\" applies security patches within the pinned minor version and is the sane default. Null means nothing upgrades and the cluster eventually falls out of support."
  type        = string
  default     = "patch"

  validation {
    condition     = var.automatic_upgrade_channel == null || contains(["patch", "stable", "rapid", "node-image"], coalesce(var.automatic_upgrade_channel, "patch"))
    error_message = "automatic_upgrade_channel must be patch, stable, rapid, node-image or null."
  }
}

variable "sku_tier" {
  description = "\"Free\", \"Standard\" or \"Premium\". Free carries NO control-plane SLA and is limited to a smaller node count. Standard adds the uptime SLA and is the minimum for anything that matters."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

################################################################################
# System node pool
#
# The system pool runs the cluster's own components: CoreDNS, metrics-server,
# the CSI drivers. Azure requires it to exist and to have at least 2 vCPU and
# 4 GB per node — Standard_B1s does not qualify.
################################################################################

variable "system_node_pool" {
  description = <<-EOT
    System node pool configuration.

    `only_critical_addons_taint` adds CriticalAddonsOnly=true:NoSchedule, which
    keeps application workloads off the system pool. Correct wherever a user
    pool exists; impossible where one does not, because then nothing could be
    scheduled at all.
  EOT

  type = object({
    name                       = optional(string, "system")
    vm_size                    = string
    node_count                 = optional(number, 1)
    auto_scaling_enabled       = optional(bool, false)
    min_count                  = optional(number)
    max_count                  = optional(number)
    zones                      = optional(list(string), [])
    os_disk_size_gb            = optional(number, 64)
    os_disk_type               = optional(string, "Managed")
    only_critical_addons_taint = optional(bool, false)
    max_pods                   = optional(number, 60)
  })
}

variable "user_node_pools" {
  description = "Additional node pools for application workloads. Separating workloads from the system pool means a runaway pod cannot starve CoreDNS."
  type = map(object({
    vm_size              = string
    node_count           = optional(number, 1)
    auto_scaling_enabled = optional(bool, true)
    min_count            = optional(number, 1)
    max_count            = optional(number, 3)
    zones                = optional(list(string), [])
    os_disk_size_gb      = optional(number, 64)
    os_disk_type         = optional(string, "Managed")
    max_pods             = optional(number, 60)
    node_labels          = optional(map(string), {})
    node_taints          = optional(list(string), [])
    spot_enabled         = optional(bool, false)
  }))
  default = {}
}

################################################################################
# Networking
#
# Azure CNI Overlay: pods draw addresses from pod_cidr rather than the subnet.
# The alternative, classic Azure CNI, assigns every pod a subnet address — a
# /22 holding 1019 addresses supports roughly 16 nodes at 60 pods each, and the
# subnet cannot be resized once in use. Overlay removes that ceiling entirely.
################################################################################

variable "vnet_subnet_id" {
  description = "Subnet for cluster nodes. With overlay networking this holds node addresses only, not pod addresses."
  type        = string
}

variable "network_plugin" {
  description = "\"azure\" or \"none\". Azure CNI is required for network policy support."
  type        = string
  default     = "azure"
}

variable "network_plugin_mode" {
  description = "\"overlay\" draws pod addresses from pod_cidr instead of the subnet. Null uses classic CNI, which consumes a subnet address per pod and caps cluster size at the subnet size."
  type        = string
  default     = "overlay"
}

variable "network_policy" {
  description = <<-EOT
    Network policy engine: "azure", "calico", "cilium" or null.

    NOT optional in this platform. Moving from VM Scale Sets to AKS moves the
    three-tier boundary from subnets and NSGs into the cluster. Without a
    policy engine, every pod can reach every other pod regardless of namespace,
    and the tier separation the architecture claims does not exist.
  EOT
  type        = string
  default     = "azure"
}

variable "pod_cidr" {
  description = "Address range pods draw from under overlay networking. Must NOT overlap the VNet, any peered network, or the service CIDR — it is routed inside the cluster only."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "Address range for Kubernetes Service ClusterIPs. Must not overlap the VNet or pod_cidr."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Address of the cluster DNS service. Must sit inside service_cidr and is conventionally its .10."
  type        = string
  default     = "172.16.0.10"
}

variable "outbound_type" {
  description = <<-EOT
    How cluster egress is provided. This must MATCH how the subnet actually
    gets out, and the wrong choice fails at create time with an error naming
    the route table rather than the setting:

      loadBalancer            AKS provisions its own public load balancer for
                              egress. Creates a second outbound path if
                              something else already provides one.

      userDefinedRouting      Requires a route table ALREADY associated with
                              the subnet and carrying an egress route. This is
                              the Azure Firewall topology. Selecting it when a
                              NAT Gateway provides egress fails with
                              ExistingRouteTableNotAssociatedWithSubnet.

      userAssignedNATGateway  Uses a NAT Gateway already associated with the
                              subnet. This is the correct value whenever the
                              networking module attached one.

      managedNATGateway       AKS creates and owns a NAT Gateway.
  EOT
  type        = string
  default     = "userAssignedNATGateway"

  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting", "managedNATGateway", "userAssignedNATGateway"], var.outbound_type)
    error_message = "outbound_type must be loadBalancer, userDefinedRouting, managedNATGateway or userAssignedNATGateway."
  }
}

################################################################################
# API server access
################################################################################

variable "private_cluster_enabled" {
  description = "Make the API server reachable only from inside the VNet. The correct posture — and it means kubectl works only from the VNet or through Bastion, so an operator laptop loses direct access."
  type        = bool
  default     = false
}

variable "api_server_authorized_ip_ranges" {
  description = "Public CIDRs permitted to reach the API server. Only meaningful on a public cluster. An empty list on a public cluster leaves the Kubernetes control plane open to the entire internet. Operator addresses only — the cluster's own egress address belongs in node_egress_ip_ranges."
  type        = list(string)
  default     = []
}

variable "node_egress_ip_ranges" {
  description = <<-EOT
    Public CIDRs the cluster's own nodes egress from, merged into the API server
    allowlist.

    Required whenever the API server is public, restricted by an allowlist, and
    egress is self-managed (outbound_type userDefinedRouting or
    userAssignedNATGateway). AKS appends the cluster's egress address to the
    allowlist automatically ONLY when it owns the outbound path itself
    (loadBalancer with managed IPs, or managedNATGateway). With a user-assigned
    NAT Gateway or a UDR it does not, and nothing in the plan says so.

    Omitting it produces a cluster that provisions for ~15 minutes and then
    crash-loops: kubelet cannot reach its own API server, the vmssCSE bootstrap
    times out with exit code 51, and AKS deletes and recreates the node roughly
    every 14 minutes indefinitely. The allowlist blackholes unauthorised sources
    rather than refusing them, so the only symptom is a curl that transfers zero
    bytes.
  EOT
  type        = list(string)
  default     = []
}

################################################################################
# Identity and authentication
################################################################################

variable "local_account_disabled" {
  description = "Disable the cluster's built-in local admin account. TRUE is the correct posture: that account authenticates with a client certificate that cannot be rotated, cannot be attributed to a person, and bypasses Entra ID entirely. Requires Entra RBAC to be configured, or nobody can authenticate."
  type        = bool
  default     = true
}

variable "entra_admin_group_object_ids" {
  description = <<-EOT
    Entra GROUP object IDs granted cluster-admin through the AKS AAD profile.

    These must be groups. AKS binds them as Kubernetes `Group` subjects, matched
    against the `groups` claim in the caller's token. A USER object ID here is
    accepted by Azure, creates a binding, and never matches anything — a user's
    own object ID appears in the `oid` claim, never in `groups`. Terraform
    cannot tell the two apart without a directory lookup, so this cannot be
    validated here; grant individual users through cluster_admin_principal_ids
    instead.
  EOT
  type        = list(string)
  default     = []
}

variable "cluster_admin_principal_ids" {
  description = <<-EOT
    Object IDs granted cluster-admin through AZURE RBAC, by role assignment of
    "Azure Kubernetes Service RBAC Cluster Admin" at the cluster scope.

    This is the path azure_rbac_enabled actually describes, and unlike
    entra_admin_group_object_ids it accepts users, groups and service
    principals alike.

    Worth knowing: subscription Owner and Contributor do NOT grant Kubernetes
    API access. Both carry `dataActions: []`, and Kubernetes authorisation
    lives entirely in dataActions. An Owner who cannot run kubectl is the
    expected behaviour, not a misconfiguration.
  EOT
  type        = set(string)
  default     = []
}

variable "azure_rbac_enabled" {
  description = "Use Azure RBAC for Kubernetes authorisation, so access is granted through Azure role assignments rather than in-cluster RoleBindings. Makes cluster access visible to the same access review as everything else."
  type        = bool
  default     = true
}

variable "workload_identity_enabled" {
  description = "Enable Entra Workload Identity, letting pods authenticate as a managed identity through a federated service account token. This is what replaces a VM's managed identity when workloads move into pods — and it is how the app and biz workloads reach SQL, Key Vault and Storage without a secret."
  type        = bool
  default     = true
}

variable "oidc_issuer_enabled" {
  description = "Publish an OIDC issuer URL. Required by workload identity."
  type        = bool
  default     = true
}

################################################################################
# Add-ons and hardening
################################################################################

variable "log_analytics_workspace_id" {
  description = "Workspace for Container Insights. Null disables the add-on, which means no container logs or node metrics — the cluster is then observable only through kubectl."
  type        = string
  default     = null
}

variable "azure_policy_enabled" {
  description = "Enable the Azure Policy add-on, which applies Gatekeeper constraints to admission. This is how a rule such as \"no privileged containers\" becomes enforceable rather than documented."
  type        = bool
  default     = true
}

variable "key_vault_secrets_provider_enabled" {
  description = "Enable the Key Vault CSI driver so pods mount secrets from Key Vault rather than holding Kubernetes Secrets, which are only base64-encoded at rest by default."
  type        = bool
  default     = true
}

variable "image_cleaner_enabled" {
  description = "Periodically remove unused images from nodes, including vulnerable ones that no longer run anything."
  type        = bool
  default     = true
}

variable "run_command_enabled" {
  description = "Allow `az aks command invoke`, which runs arbitrary commands in the cluster through the Azure control plane. Convenient for reaching a private cluster, and a control-plane path that bypasses network restrictions entirely — so it should be a deliberate choice."
  type        = bool
  default     = false
}

variable "cost_analysis_enabled" {
  description = "Surface per-namespace cost allocation in Cost Management. Requires the Standard or Premium SKU tier."
  type        = bool
  default     = false
}

################################################################################
# Autoscaler
################################################################################

variable "auto_scaler_profile" {
  description = "Cluster autoscaler tuning. scale_down_unneeded is how long a node must be idle before removal — short values save money and cause churn."
  type = object({
    balance_similar_node_groups   = optional(bool, true)
    expander                      = optional(string, "random")
    scale_down_unneeded           = optional(string, "10m")
    scale_down_delay_after_add    = optional(string, "10m")
    skip_nodes_with_local_storage = optional(bool, false)
    skip_nodes_with_system_pods   = optional(bool, true)
  })
  default = {}
}

variable "maintenance_window_hours" {
  description = "Hours of the day (UTC) when automatic upgrades may run. Empty means Azure chooses, which can be during business hours."
  type        = list(number)
  default     = []
}
