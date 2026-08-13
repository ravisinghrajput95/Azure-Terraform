################################################################################
# Cluster
################################################################################

output "id" {
  description = "ARM resource ID of the cluster. Diagnostic settings and role assignments target this."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "fqdn" {
  description = "API server FQDN. On a private cluster this resolves only inside the VNet."
  value       = var.private_cluster_enabled ? azurerm_kubernetes_cluster.this.private_fqdn : azurerm_kubernetes_cluster.this.fqdn
}

output "kubernetes_version" {
  description = "Control plane version actually running, which may be ahead of the pinned version if an upgrade channel applied a patch."
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "Azure-managed resource group holding node VMs, disks and load balancers. AKS owns and reconciles it — anything placed there by hand is liable to be removed."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

################################################################################
# Identity
################################################################################

output "principal_id" {
  description = "Control plane managed identity. Grant this access when the cluster itself must reach an Azure resource — attaching an ACR, or managing a load balancer in another resource group."
  value       = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

output "kubelet_identity_object_id" {
  description = "Kubelet identity, distinct from the control plane identity. This is the one that pulls images, so an ACR pull role assignment goes here rather than on principal_id — a common and confusing mix-up."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL. A federated identity credential on a user-assigned identity references this plus a service account subject, which is what lets a pod authenticate as that identity with no secret."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "key_vault_secrets_provider_identity" {
  description = "Object ID of the Key Vault CSI driver's identity, or null when the add-on is disabled. Grant this Key Vault Secrets User so pods can mount secrets rather than holding Kubernetes Secrets, which are only base64-encoded at rest."
  value       = var.key_vault_secrets_provider_enabled ? azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id : null
}

################################################################################
# Availability
################################################################################

output "is_highly_available" {
  description = "Whether the cluster is genuinely HA: at least three nodes across at least three availability zones. Reported rather than assumed, so a single-node development cluster never reads as production-shaped."
  value       = local.is_highly_available
}

output "availability_summary" {
  description = "Plain-language availability posture."
  value = local.is_highly_available ? (
    "${local.system_effective_min} nodes across ${local.system_zone_count} zones with the ${var.sku_tier} SKU tier."
    ) : (
    "NOT highly available: ${local.system_effective_min} node(s) across ${local.system_zone_count} zone(s), ${var.sku_tier} SKU tier${var.sku_tier == "Free" ? " which carries NO control-plane SLA" : ""}. A node or zone fault takes the cluster with it."
  )
}

output "has_user_node_pools" {
  description = "Whether workloads run on a pool separate from the system components. False means a runaway pod shares a node with CoreDNS."
  value       = local.has_user_pools
}

################################################################################
# Security posture
################################################################################

output "api_server_reachable_from" {
  description = "Who can reach the Kubernetes API server, in plain language."
  value = var.private_cluster_enabled ? (
    "Private endpoint only — kubectl works from inside the VNet or through Bastion, not from an operator machine."
    ) : (
    "Public endpoint restricted to ${length(var.api_server_authorized_ip_ranges)} IP range(s)."
  )
}

output "network_policy" {
  description = "Policy engine enforcing pod-to-pod rules. This is what carries the tier boundary now that it no longer lives in NSGs between subnets."
  value       = var.network_policy
}

output "local_account_disabled" {
  description = "Whether the built-in local admin account is disabled. True means Entra group membership is the only way in, and the unrotatable, unattributable cluster certificate cannot be used."
  value       = azurerm_kubernetes_cluster.this.local_account_disabled
}

output "security_summary" {
  description = "Consolidated posture, so the interacting settings can be reviewed without reading the configuration."
  value = join(" ", compact([
    var.private_cluster_enabled ? "Private API server." : "Public API server with ${length(var.api_server_authorized_ip_ranges)} allowed range(s).",
    var.local_account_disabled ? "Local admin account disabled; Entra ID only." : "WARNING: local admin account is ENABLED.",
    var.network_policy != null ? "Network policy: ${var.network_policy}." : "WARNING: no network policy — every pod can reach every other pod.",
    var.workload_identity_enabled ? "Workload identity enabled." : "Workload identity disabled.",
    var.azure_policy_enabled ? "Azure Policy admission control enabled." : "",
    var.run_command_enabled ? "WARNING: run_command is enabled, a control-plane path that bypasses network restrictions." : "",
  ]))
}
