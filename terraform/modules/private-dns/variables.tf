################################################################################
# Placement
#
# Private DNS zones are global resources — they take no location. They live in
# the networking resource group rather than the data group so that destroying
# the data tier does not orphan zones that other services and future endpoints
# share.
################################################################################

variable "resource_group_name" {
  description = "Resource group for the zones. Should be the \"net\" lifecycle scope: zones outlive the individual data services that register into them."
  type        = string
}

variable "tags" {
  description = "Tags from the tags module."
  type        = map(string)
}

################################################################################
# Zones
#
# Zones are selected by SERVICE KEY, not by zone name. A privatelink zone name
# has to match exactly what Azure expects for the service, and a typo is
# silently harmless-looking: the zone is created, the private endpoint's DNS
# zone group finds no matching zone, no A record is registered, and the client
# falls back to public DNS — resolving the service to its PUBLIC address from
# inside the VNet.
#
# The private endpoint exists, the NSG allows it, the architecture diagram is
# correct, and traffic leaves the VNet. Selecting by key removes the class of
# error entirely.
################################################################################

variable "services" {
  description = "Service keys to create privatelink zones for. Valid keys: sql, sql_mi, blob, file, queue, table, dfs, web_storage, keyvault, redis, redis_enterprise, cosmos_sql, servicebus, eventhub, acr, aks, app_service, monitor, automation, signalr, search, appconfig, backup, storage_sync."
  type        = list(string)
  default     = []

  validation {
    condition     = length(distinct(var.services)) == length(var.services)
    error_message = "services must not contain duplicates."
  }
}

variable "location_hint" {
  description = "Normalised region name, required only when requesting a service whose privatelink zone embeds a region: sql_mi, aks and backup. For example SQL Managed Instance uses privatelink.<region>.database.windows.net. Leave null when none of those services are requested."
  type        = string
  default     = null

  validation {
    condition     = var.location_hint == null || can(regex("^[a-z0-9]+$", coalesce(var.location_hint, "x")))
    error_message = "location_hint must be a normalised region name: lowercase alphanumerics only, e.g. \"eastus\"."
  }
}

variable "additional_zones" {
  description = "Raw privatelink zone names for services not covered by the service-key table. Use sparingly — a typo here has no error path and results in a private endpoint that silently resolves to a public address. Prefer extending the module's table."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for zone in var.additional_zones : can(regex("^[a-z0-9.-]+$", zone))])
    error_message = "Zone names must be lowercase and contain only letters, digits, dots and hyphens."
  }
}

################################################################################
# Virtual network links
################################################################################

variable "virtual_network_ids" {
  description = "Map of link name to virtual network ID. Every zone is linked to every VNet listed. Without a link, a zone exists but is invisible to the VNet's resolver, and private endpoint names resolve publicly."
  type        = map(string)

  validation {
    condition     = length(var.virtual_network_ids) > 0
    error_message = "At least one virtual network must be linked, or the zones would resolve for nobody."
  }
}

variable "registration_enabled" {
  description = <<-EOT
    Whether VMs in the linked VNet auto-register their own A records in these
    zones.

    Left FALSE, and it should stay false for privatelink zones. Two reasons:

      1. A privatelink zone holds records Azure manages on behalf of private
         endpoints. VM records do not belong in it, and a VM registering a name
         that collides with a service record breaks resolution for everyone.

      2. Azure permits at most ONE registration-enabled link per virtual
         network across ALL zones. Spending it on a privatelink zone means it
         is unavailable for a genuine VM-registration zone later.
  EOT
  type        = bool
  default     = false
}

variable "resolution_policy" {
  description = "Behaviour when a name is not found in the zone. \"NxDomainRedirect\" falls back to public DNS for unmatched names, which is required when a linked VNet also needs to resolve public names in the same suffix. Null uses the Azure default."
  type        = string
  default     = null

  validation {
    condition     = var.resolution_policy == null || contains(["Default", "NxDomainRedirect"], coalesce(var.resolution_policy, "Default"))
    error_message = "resolution_policy must be \"Default\", \"NxDomainRedirect\", or null."
  }
}
