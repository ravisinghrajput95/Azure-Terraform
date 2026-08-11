################################################################################
# Load balancer
################################################################################

output "id" {
  description = "ARM resource ID of the load balancer. Diagnostic settings target this."
  value       = azurerm_lb.this.id
}

output "name" {
  description = "Load balancer name."
  value       = azurerm_lb.this.name
}

output "type" {
  description = "\"internal\" or \"public\"."
  value       = var.type
}

################################################################################
# Frontend
################################################################################

output "frontend_ip_address" {
  description = "The address clients connect to: the private frontend address for an internal load balancer, the public IP for a public one."
  value       = local.is_public ? azurerm_public_ip.this[0].ip_address : azurerm_lb.this.frontend_ip_configuration[0].private_ip_address
}

output "public_ip_id" {
  description = "Public IP resource ID, or null for an internal load balancer."
  value       = local.is_public ? azurerm_public_ip.this[0].id : null
}

################################################################################
# Backend pools
#
# A scale set consumes these IDs to attach itself. The pool does not enumerate
# its members, which is what lets instances come and go during a rolling
# upgrade without a Terraform change.
################################################################################

output "backend_pool_ids" {
  description = "Map of pool name to ID. Pass the relevant ID to the vm module's scale set network configuration."
  value       = { for name, pool in azurerm_lb_backend_address_pool.this : name => pool.id }
}

output "probe_ids" {
  description = "Map of probe name to ID."
  value       = { for name, probe in azurerm_lb_probe.this : name => probe.id }
}

################################################################################
# Health check quality
#
# Surfaced because a load balancer that reports healthy while every request
# fails is worse than one that is obviously down.
################################################################################

output "tcp_only_probes" {
  description = "Probes checking only that a TCP port accepts connections. A hung process keeps accepting connections, so these report healthy while every request times out. Prefer an Http or Https probe with a request_path wherever the backend speaks HTTP."
  value       = local.tcp_only_probes
}

output "probe_detection_seconds" {
  description = "Map of probe name to how long a failed instance keeps receiving traffic — interval_in_seconds multiplied by probe_threshold."
  value       = local.probe_detection_seconds
}

output "unused_backend_pools" {
  description = "Pools no rule sends traffic to. A scale set attached to one of these sits healthy and idle, receiving nothing."
  value       = local.unused_pools
}

output "orphaned_probes" {
  description = "Probes no rule references. Inert — usually a rename that missed one side."
  value       = local.orphaned_probes
}

################################################################################
# Outbound
################################################################################

output "outbound_snat_disabled" {
  description = "Whether load balancing rules perform outbound SNAT. Disabled in this platform: egress is the NAT Gateway's job, and a second undeclared egress path competes for a much smaller SNAT port allocation, which surfaces as intermittent outbound failures under load."
  value       = local.is_public ? var.disable_outbound_snat : null
}
