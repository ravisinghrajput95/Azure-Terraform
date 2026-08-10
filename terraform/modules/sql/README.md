# Module: `sql`

Azure SQL logical server and database with **Entra ID authentication only** — no
SQL login exists — a private endpoint, and profile-driven tier, backup and
network settings.

---

## There is no password

This module does not accept `administrator_login` or
`administrator_login_password`, and never sets them.

"No hardcoded secrets" is the usual goal. This is stronger: **the secret does
not exist.**

- No password is generated, so none is written to Terraform state in plaintext
- None is stored in Key Vault, so none needs rotating
- None appears in a connection string, a CI variable, or a support ticket
- None can leak, because there is nothing to leak

Applications authenticate with the managed identities from the
`managed-identity` module:

```
Server=<fqdn>;Database=<db>;Authentication=Active Directory Managed Identity;
User Id=<client_id_of_user_assigned_identity>;Encrypt=true;
```

**The trade-off is real and worth stating.** Access is then governed entirely
by Entra ID group membership, which lives outside this repository. Granting
someone database access becomes a directory operation, not a Terraform change —
better for security, worse for auditability-from-code. Choose it knowingly.

If a SQL login is genuinely unavoidable for a legacy component, the provider
offers `administrator_login_password_wo` — a write-only argument that keeps the
value out of state. That is the right fallback. Having no login at all is
better still.

---

## Usage

```hcl
module "sql" {
  source = "../../modules/sql"

  server_name         = module.naming.sql_server_name
  database_name       = module.naming.names.sql_database
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  entra_administrator_login     = "sql-admins"
  entra_administrator_object_id = azuread_group.sql_admins.object_id
  entra_administrator_is_group  = true
  azuread_authentication_only   = true

  sku_name                    = module.profile.profile.sql_sku_name
  zone_redundant              = module.profile.profile.sql_zone_redundant
  short_term_retention_days   = module.profile.profile.sql_backup_retention_days
  long_term_retention_enabled = module.profile.profile.sql_enable_long_term_retention

  public_network_access_enabled = module.profile.data_plane_public_access_enabled

  private_endpoint_subnet_id = module.networking.subnet_ids["snet-pep-dev-eus"]
  private_endpoint_name      = "pep-sql-cloudcart-dev-eus-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["sql"]]
}
```

## Key inputs

| Name | Default | Description |
|---|---|---|
| `entra_administrator_login` / `_object_id` | — | **Prefer a group.** |
| `entra_administrator_is_group` | `false` | Drives the governance output. |
| `azuread_authentication_only` | `true` | Leave true. |
| `sku_name` | `"GP_S_Gen5_1"` | From `profile`. |
| `zone_redundant` | `false` | Requires BC/Premium. |
| `auto_pause_delay_in_minutes` | `60` | Serverless only, min 60 or `-1`. |
| `min_capacity` | `0.5` | Serverless only. |
| `storage_account_type` | `"Local"` | Backup redundancy. |
| `short_term_retention_days` | `7` | 1–35, PITR window. |
| `long_term_retention_enabled` | `false` | Weekly/monthly/yearly. |
| `public_network_access_enabled` | `false` | From `profile`. |
| `allowed_ip_rules` | `{}` | Firewall rules. |
| `private_endpoint_*` | | |

## Outputs

`server_id`, `server_name`, `server_fqdn`, `server_principal_id`,
`database_id`, `database_name`, `sku_name`, `is_serverless`,
`auto_pause_delay_in_minutes`, `connection_guidance`, `private_endpoint_id`,
`private_endpoint_ip`, `azuread_authentication_only`,
`administrator_is_individual`, `reachable_from`, `backup_summary`

---

## Serverless economics

`GP_S_Gen5_1` bills **per second of compute** and pauses after the configured
idle delay. A paused database bills for storage only.

For an environment used a few hours a day, that is the difference between a
few dollars a month and a few hundred. The cost is a **cold start of several
seconds** on the first connection after a pause — fine for dev, usually
unacceptable for a user-facing production tier, which is why the profile moves
prod to `BC_Gen5_4`.

Minimum auto-pause delay is 60 minutes. `-1` disables pausing.

---

## Two rejected wildcards

**`0.0.0.0` – `0.0.0.0` firewall rule.** Azure's "Allow Azure services" entry
is not an address range: it permits every Azure resource in **every tenant**,
including other customers'. It is one of the most common Azure SQL exposures,
and variable validation rejects it outright.

**Zone redundancy on General Purpose.** Requires Business Critical or Premium.
Azure rejects the combination with an error naming the *property* rather than
the SKU, so a precondition catches it first and explains which is wrong.

---

## Preconditions

| Check | Failure it prevents |
|---|---|
| Not both endpoints disabled | Server created fine, unreachable by every client including migrations |
| Private endpoint requires DNS zone | FQDN resolves to the **public** address from inside the VNet |
| Zone redundancy requires BC/Premium | Azure error naming the property, not the SKU |
| Geo backup requires geo backup storage | Rejected after provisioning begins |

---

## Governance

`administrator_is_individual` reports `true` when the Entra administrator is a
named user rather than a group.

That is a **governance weakness, not a technical fault** — it ties database
administration to one person's account, which breaks when they leave and cannot
be reviewed as a role. It is surfaced rather than blocked, because in a
personal or trial subscription there may be no group to use.

---

## Cost

| SKU | Approximate |
|---|---|
| `GP_S_Gen5_1` serverless, paused | Storage only, a few dollars/month |
| `GP_S_Gen5_1` serverless, active | ~$0.14/vCore-hour |
| `GP_Gen5_2` provisioned | ~$370/month |
| `BC_Gen5_4` Business Critical | ~$930/month |
| Private endpoint | ~$7.30/month |

Long-term retention and geo-redundant backup storage both add materially, and
neither is enabled in dev.

---

## Deployed state

`dev` — `GP_S_Gen5_1` serverless, 60-minute auto-pause, 0.5 minimum vCores,
32 GB, Local backup storage, 7-day point-in-time restore, Entra-only
authentication, private endpoint in `snet-pep-dev-eus`, public endpoint
restricted to the operator IP.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
