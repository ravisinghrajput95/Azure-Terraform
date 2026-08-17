################################################################################
# Subscription
################################################################################

variable "subscription_id" {
  description = "Target Azure subscription ID. Required explicitly by azurerm 4.x — it no longer falls back to the CLI's active subscription silently, which prevents applying to whichever subscription happened to be selected."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

################################################################################
# Identity of this deployment
################################################################################

variable "workload" {
  description = "Workload identifier, used by both naming and tags."
  type        = string
  default     = "cloudcart"
}

variable "location" {
  description = "Azure region. Central US, because Azure SQL provisioning is restricted in East US on this subscription — see docs/ARCHITECTURE.md §6a."
  type        = string
  default     = "centralus"
}

################################################################################
# Governance
#
# No defaults. These are the tags cost reporting and incident response query
# on; a default would guarantee a share of the estate reads \"unknown\".
################################################################################

variable "owner" {
  description = "Email of the team accountable for this environment."
  type        = string
}

variable "alert_email_address" {
  description = "Where alert notifications are delivered. Defaults to owner, which is already an accountable address — set this only where alerts should go somewhere the ownership tag should not, such as a shared rota mailbox."
  type        = string
  default     = null
}

variable "cost_center" {
  description = "Chargeback code."
  type        = string
}

variable "criticality" {
  description = "Business criticality: low, medium, high or mission-critical."
  type        = string
  default     = "low"
}

variable "data_classification" {
  description = "Data sensitivity: public, internal, confidential or restricted."
  type        = string
  default     = "internal"
}

################################################################################
# Capacity
################################################################################

variable "subscription_vcpu_quota" {
  description = "Total regional vCPU quota, from `az vm list-usage --location <region>`. The profile module asserts the peak compute footprint fits inside it. On this subscription (FreeTrial, spending limit on) the limit is 4 and cannot be raised without upgrading to Pay-As-You-Go."
  type        = number
  default     = 4
}

################################################################################
# Profile overrides
################################################################################

variable "profile_overrides" {
  description = "Overrides applied on top of the dev profile. Left empty, the free-tier-safe defaults apply. See modules/profile/README.md for the full attribute list."
  type        = any
  default     = {}
}

################################################################################
# Firewall
################################################################################

variable "firewall_private_ip" {
  description = "Private IP of the Azure Firewall, used as the VirtualAppliance next hop for the workload route table. Only consumed when the profile's egress_strategy is \"firewall\"; dev uses a NAT Gateway and leaves this null. Taken as a variable rather than read from the firewall module so that route tables can be applied before, or independently of, the firewall."
  type        = string
  default     = null
}

################################################################################
# Data-plane access
################################################################################

variable "deployer_ip_addresses" {
  description = "Public IPv4 addresses permitted to reach the Key Vault and Storage data planes. Required in dev, where secrets must be manageable from an operator machine outside the VNet — a private endpoint is only reachable from inside it, so with no allowlist Terraform itself could not write a secret. Azure rejects /31 and /32 suffixes here; supply bare addresses."
  type        = list(string)
  default     = []
}

################################################################################
# SQL administration
################################################################################

variable "sql_entra_admin_login" {
  description = "Display name or UPN of the Entra principal administering the SQL server. Defaults to the deploying user, which is acceptable in a personal subscription and is a governance weakness anywhere else — prefer a group so administration is a role rather than a person."
  type        = string
  default     = null
}

variable "sql_entra_admin_object_id" {
  description = "Object ID of the Entra SQL administrator. Defaults to the deploying user."
  type        = string
  default     = null
}

variable "sql_entra_admin_is_group" {
  description = "Whether the SQL administrator principal is a group rather than an individual."
  type        = bool
  default     = false
}

################################################################################
# Kubernetes administration
################################################################################

variable "aks_admin_group_object_ids" {
  description = "Entra GROUP object IDs granted cluster-admin through the AKS AAD profile. Must be groups: AKS binds them as Kubernetes Group subjects matched against the token's `groups` claim, so a user object ID here binds successfully and never matches anything. Individual people belong in aks_cluster_admin_principal_ids."
  type        = list(string)
  default     = []
}

variable "aks_cluster_admin_principal_ids" {
  description = "Object IDs granted cluster-admin through Azure RBAC. Accepts users, groups and service principals alike, unlike the group list above. A personal subscription with no Entra group uses this; anywhere with a directory should prefer a group. Note that subscription Owner does NOT grant kubectl access — it carries no dataActions, and Kubernetes authorisation lives entirely there."
  type        = list(string)
  default     = []
}

################################################################################
# Observability
################################################################################

variable "log_analytics_daily_cap_reset_hour_utc" {
  description = <<-EOT
    The UTC hour at which this workspace's daily ingestion cap resets.

    NOT midnight — this workspace resets at 11:00 UTC. The value defines the
    window the cap-warning query sums over, and a wrong one produces a query
    Azure accepts and reports healthy while summing the wrong period.

    Verify before changing:

      az monitor log-analytics workspace show \
        -g rg-cloudcart-dev-cus-mon -n log-cloudcart-dev-cus-001 \
        --query workspaceCapping.quotaNextResetTime -o tsv
  EOT
  type        = number
  default     = 11

  validation {
    condition     = var.log_analytics_daily_cap_reset_hour_utc >= 0 && var.log_analytics_daily_cap_reset_hour_utc <= 23
    error_message = "Must be an hour from 0 to 23."
  }
}

variable "aks_excluded_log_categories" {
  description = <<-EOT
    AKS diagnostic log categories NOT collected in this environment.

    This is a deliberate security trade made for a capped dev workspace, not a
    cleanup. Measured over 24h on 2026-08-14, against a 512 MB/day cap:

      kube-audit                627.36 MB   61.0%
      kube-audit-admin          368.00 MB   35.8%
      everything else            33.53 MB    3.3%
      TOTAL                    1028.89 MB   = 201% of cap

    The workspace was hitting its cap daily and dropping whatever arrived
    after, which is unrecoverable and blinds every alert rule at the same time.

    Excluding only `kube-audit` leaves 401 MB/day, or 78.4% of the cap —
    permanently pressed against the 80% warning threshold. An alert that fires
    constantly is as useless as one that never fires, so that is not a fix.
    Excluding both leaves ~6.5% and real headroom.

    WHAT IS LOST: Kubernetes API server audit logging. `kube-audit-admin` is
    the reduced form (non-get/list operations) and is the one worth restoring
    first if the cap is ever raised. Recorded in SECURITY.md.

    Environments with an uncapped workspace should pass [] and collect
    everything — profile forces log_daily_quota_gb = -1 outside dev.
  EOT
  type        = list(string)
  default     = ["kube-audit", "kube-audit-admin"]
}
