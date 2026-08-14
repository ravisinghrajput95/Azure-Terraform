################################################################################
# Identity
################################################################################

output "id" {
  description = "Firewall resource ID."
  value       = azurerm_firewall.this.id
}

output "name" {
  description = "Firewall name."
  value       = azurerm_firewall.this.name
}

output "policy_id" {
  description = "Firewall policy resource ID. Attach a child policy or a second firewall to this."
  value       = azurerm_firewall_policy.this.id
}

################################################################################
# Addresses
################################################################################

output "private_ip_address" {
  description = "The firewall's private IP. THIS is the value a route table's VirtualAppliance next hop needs — the route-table module takes it as next_hop_ip so the two can be applied independently."
  value       = try(azurerm_firewall.this.ip_configuration[0].private_ip_address, null)
}

output "public_ip_address" {
  description = "The firewall's public egress address. This is the source address the internet sees for every workload routed through it, and the value an external allowlist needs."
  value       = azurerm_public_ip.this.ip_address
}

output "public_ip_address_id" {
  description = "ID of the data-plane public IP created by this module."
  value       = azurerm_public_ip.this.id
}

################################################################################
# Posture
#
# Reported rather than assumed. Every degraded state below is one the portal
# displays as a healthy, correctly provisioned firewall.
################################################################################

output "is_zone_redundant" {
  description = "Whether the firewall spans at least two availability zones. A single zone is a zonal deployment with no redundancy, which reads like zone-awareness and is not."
  value       = local.is_zone_redundant
}

output "rule_collection_count" {
  description = "Number of rule collections across all three types."
  value       = local.total_collections
}

output "rule_count" {
  description = "Total individual rules."
  value       = local.rule_count
}

output "threat_intelligence_enforces" {
  description = "True only when threat_intelligence_mode is \"Deny\". \"Alert\" logs malicious traffic and lets it through, which is protection that reports as enabled and blocks nothing."
  value       = local.threat_intel_enforces
}

output "intrusion_detection_enforces" {
  description = "True only when IDPS is set to \"Deny\" on a Premium firewall. \"Alert\" logs signature matches and allows them."
  value       = local.idps_enforces && var.sku_tier == "Premium"
}

output "security_summary" {
  description = "Consolidated posture in plain language, so the interacting settings can be reviewed without reading the configuration."
  value = join(" ", compact([
    "${var.sku_tier} tier, ${local.total_collections} rule collection(s), ${local.rule_count} rule(s).",
    local.is_zone_redundant ? "Zone redundant across ${length(var.zones)} zones (cross-zone data transfer is billed)." : "NOT zone redundant: ${length(var.zones)} zone(s).",
    local.threat_intel_enforces ? "Threat intelligence BLOCKS." : "WARNING: threat intelligence is \"${var.threat_intelligence_mode}\" — it does not block.",
    var.intrusion_detection_mode == null ? "No IDPS configured." : (
      var.sku_tier == "Premium" && var.intrusion_detection_mode == "Deny"
      ? "IDPS blocks signature matches."
      : "WARNING: IDPS is \"${var.intrusion_detection_mode}\" — it does not block."
    ),
    var.dns_proxy_enabled ? "DNS proxy on." : "DNS proxy OFF — FQDNs in network rules cannot resolve.",
    !local.has_any_rules ? "WARNING: NO RULES. This firewall denies everything; as an egress next hop it blackholes all outbound traffic while reporting healthy." : "",
    length(local.broad_network_allows) > 0 && local.has_application_rules ? "WARNING: broad network Allow rules shadow the application rules below them: ${join(", ", local.broad_network_allows)}." : "",
  ]))
}

################################################################################
# Cost
################################################################################

output "indicative_monthly_cost_usd" {
  description = "ORDER-OF-MAGNITUDE monthly estimate at approximate US list price for the deployment hours alone. Data processing is roughly $0.016/GB ON TOP of this, and cross-zone transfer is extra again. Not a budget figure — verify against the Azure Pricing Calculator."
  value       = local.indicative_monthly_cost_usd
}
