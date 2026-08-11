################################################################################
# Gateway
################################################################################

output "id" {
  description = "ARM resource ID of the gateway. Diagnostic settings target this."
  value       = azurerm_application_gateway.this.id
}

output "name" {
  description = "Gateway name."
  value       = azurerm_application_gateway.this.name
}

output "public_ip_address" {
  description = "Public ingress address. This is the address a DNS record should point at."
  value       = azurerm_public_ip.this.ip_address
}

output "public_ip_id" {
  description = "Public IP resource ID."
  value       = azurerm_public_ip.this.id
}

################################################################################
# Backend pools
#
# A scale set attaches itself to a pool by ID, so the pool is created empty and
# populated by the vm module.
################################################################################

output "backend_pool_ids" {
  description = "Map of pool name to ID. Pass the relevant ID to the vm module's scale set network configuration."
  value = {
    for pool in azurerm_application_gateway.this.backend_address_pool :
    pool.name => pool.id
  }
}

################################################################################
# WAF
################################################################################

output "waf_policy_id" {
  description = "WAF policy resource ID, or null on the Standard_v2 SKU."
  value       = local.is_waf ? azurerm_web_application_firewall_policy.this[0].id : null
}

output "waf_mode" {
  description = "\"Detection\" logs what would have been blocked; \"Prevention\" blocks it. Detection is a tuning mode, not a security posture — a gateway left in Detection is a WAF that has never blocked anything."
  value       = local.is_waf ? var.waf_mode : null
}

output "waf_exclusion_count" {
  description = "Number of WAF rule exclusions in force. Every exclusion is a hole; a growing count is worth reviewing, because exclusions are added under incident pressure and rarely removed afterwards."
  value       = local.is_waf ? length(var.waf_exclusions) : null
}

################################################################################
# Posture
################################################################################

output "is_zone_redundant" {
  description = "Whether the gateway spans availability zones. False means a zone outage takes ingress with it — and since v2 supports zones at no extra charge, false in production is almost always an oversight."
  value       = length(var.zones) > 1
}

output "settings_without_probe" {
  description = "Backend HTTP settings with no explicit probe. These fall back to Azure's default probe against \"/\", which returns 404 on most applications and marks every backend unhealthy while the application is fine."
  value       = local.settings_without_probe
}

output "capacity_range" {
  description = "Autoscale bounds. max_capacity is the ceiling on ingress throughput — a gateway at maximum queues and then sheds traffic while the backend sits idle, which reads as an application problem."
  value       = "${var.min_capacity} to ${var.max_capacity} capacity units"
}

output "uses_key_vault_certificate" {
  description = "Whether TLS is served from a Key Vault-referenced certificate. True means the certificate is never in Terraform state and rotation is a vault operation rather than a redeploy."
  value       = local.has_certificate
}
