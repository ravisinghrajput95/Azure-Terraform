################################################################################
# Bastion host
################################################################################

output "id" {
  description = "ARM resource ID of the Bastion host. Diagnostics target this."
  value       = azurerm_bastion_host.this.id
}

output "name" {
  description = "Bastion host name."
  value       = azurerm_bastion_host.this.name
}

output "dns_name" {
  description = "FQDN of the Bastion host. Used by `az network bastion` and by the portal to establish sessions."
  value       = azurerm_bastion_host.this.dns_name
}

output "sku" {
  description = "SKU actually deployed."
  value       = azurerm_bastion_host.this.sku
}

################################################################################
# Network
################################################################################

output "public_ip_address" {
  description = "Public IP of the Bastion host, or null on the Developer SKU, which is a shared regional instance with no dedicated public endpoint."
  value       = local.uses_dedicated_subnet ? azurerm_public_ip.this[0].ip_address : null
}

output "public_ip_id" {
  description = "Public IP resource ID, or null on Developer."
  value       = local.uses_dedicated_subnet ? azurerm_public_ip.this[0].id : null
}

output "private_only_enabled" {
  description = "Whether Azure reports the host as private-only. Computed-only in azurerm 4.x — readable but not settable through Terraform."
  value       = azurerm_bastion_host.this.private_only_enabled
}

output "uses_dedicated_subnet" {
  description = "Whether this SKU consumes AzureBastionSubnet. False on Developer, which attaches by virtual network ID — meaning AzureBastionSubnet stays empty and is held in reserve for a later SKU upgrade."
  value       = local.uses_dedicated_subnet
}

################################################################################
# Capability
#
# Surfaced so the operational limits of the deployed SKU are visible in
# `terraform output` rather than discovered when an operator tries to use a
# feature the SKU does not have.
################################################################################

output "supports_native_client" {
  description = "Whether `az network bastion tunnel` and native RDP/SSH clients work. False on Developer and Basic — those are browser-only."
  value       = local.supports_advanced_features && var.tunneling_enabled
}

output "supports_file_copy" {
  description = "Whether files can be transferred through the session."
  value       = local.supports_advanced_features && var.file_copy_enabled
}

output "capability_notes" {
  description = "Human-readable summary of what this SKU can and cannot do, for operators who did not choose it."
  value = local.is_developer ? join(" ", [
    "Developer SKU: no charge, shared regional instance, browser sessions only.",
    "No native client tunneling, no file copy, no IP connect, no shareable links, no zones, no Kerberos.",
    "Does not use AzureBastionSubnet, so it does not work across peered VNets.",
    "Move to Standard for native client access."
    ]) : local.supports_advanced_features ? join(" ", [
    "${var.sku} SKU: ${var.scale_units} scale units, roughly 20 concurrent sessions each.",
    "Native client tunneling ${var.tunneling_enabled ? "enabled" : "available but disabled"}."
  ]) : "Basic SKU: fixed at 2 instances, browser sessions only. No native client tunneling, file copy, IP connect or shareable links."
}
