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
# on; a default would guarantee a share of the estate reads "unknown".
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
  default     = "medium"
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
  description = <<-EOT
    Total regional vCPU quota, from `az vm list-usage --location <region>`. The
    profile module asserts the peak compute footprint fits inside it.

    On this subscription the limit is 4 for the whole region and cannot be
    raised without upgrading to Pay-As-You-Go — and dev already consumes 2 of
    them. stage's peak footprint is 16 (eight Standard_D2s_v5 at the autoscale
    ceiling), so this environment CANNOT be applied here. See README.md.

    The default below is this subscription's real quota rather than stage's
    requirement, which means the default does not plan — deliberately, so the
    refusal is the first thing an apply reports. tests/stage.tftest.hcl passes
    16 to exercise the composition, and asserts the 16 separately so this note
    cannot quietly go stale.
  EOT
  type        = number
  default     = 4
}

################################################################################
# Profile overrides
################################################################################

variable "profile_overrides" {
  description = "Overrides applied on top of the qa profile. See modules/profile/README.md for the full attribute list."
  type        = any
  default     = {}
}

################################################################################
# Firewall
################################################################################

variable "firewall_private_ip" {
  description = "Private IP of the Azure Firewall, used as the VirtualAppliance next hop for the workload route table. Only consumed when the profile's egress_strategy is \"firewall\"; qa uses a NAT Gateway and leaves this null. Taken as a variable rather than read from the firewall module so that route tables can be applied before, or independently of, the firewall."
  type        = string
  default     = null
}

################################################################################
# Data-plane access
#
# qa sets data_plane_public_access_enabled = false in its profile, so unlike
# dev these addresses do NOT open the Key Vault, Storage or SQL data planes —
# those are private-endpoint only here. The list is still consumed for SQL
# firewall rules, which are inert while public access is disabled, and is kept
# so enabling public access temporarily is a profile override rather than a
# code change.
################################################################################

variable "deployer_ip_addresses" {
  description = "Public IPv4 addresses permitted to reach data planes where public access is enabled. Largely inert in qa, which is private-endpoint only. Azure rejects /31 and /32 suffixes here; supply bare addresses."
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
  description = "Object IDs granted cluster-admin through Azure RBAC. Accepts users, groups and service principals alike, unlike the group list above. Note that subscription Owner does NOT grant kubectl access — it carries no dataActions, and Kubernetes authorisation lives entirely there."
  type        = list(string)
  default     = []
}

################################################################################
# Observability
################################################################################

variable "aks_excluded_log_categories" {
  description = <<-EOT
    AKS diagnostic log categories NOT collected in this environment.

    EMPTY in qa, deliberately. dev excludes `kube-audit` and `kube-audit-admin`
    because they are ~995 MB/day against a 512 MB/day cap and were causing
    daily data loss. qa's profile sets log_daily_quota_gb = -1, so there is no
    cap to exhaust and no reason to drop the API server audit trail — which is
    the log you want when reproducing a security question in a test
    environment.

    Ingestion is then billed rather than capped. In an environment whose whole
    purpose is validating a security topology, dropping the log that records
    who did what would defeat the exercise.
  EOT
  type        = list(string)
  default     = []
}

################################################################################
# Application Gateway
################################################################################

variable "application_gateway_certificate_secret_id" {
  description = <<-EOT
    Key Vault secret ID of the TLS certificate the Application Gateway serves.

    Supplied as an input rather than created here because a root module is a
    composition layer and declares no resources of its own. Create the
    certificate in the environment's Key Vault out of band, then pass its
    secret ID.

    When null the gateway is deployed with an HTTP listener only, and the
    HTTPS listener and its redirect are omitted. That is a deliberate
    degraded mode so the environment can be stood up before a certificate
    exists — it is reported by the `ingress_is_encrypted` output rather than
    left to be discovered.
  EOT
  type        = string
  default     = null
}
