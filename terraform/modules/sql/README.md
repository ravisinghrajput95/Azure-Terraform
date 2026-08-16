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
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_mssql_database.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_database) | resource |
| [azurerm_mssql_firewall_rule.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_firewall_rule) | resource |
| [azurerm_mssql_server.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_server) | resource |
| [azurerm_private_endpoint.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ip_rules"></a> [allowed\_ip\_rules](#input\_allowed\_ip\_rules) | Map of firewall rule name to { start\_ip, end\_ip }. Only meaningful when the public endpoint is enabled. Note that a rule of 0.0.0.0-0.0.0.0 is Azure's special 'allow all Azure services' entry, not a real address, and this module rejects it. | <pre>map(object({<br/>    start_ip = string<br/>    end_ip   = string<br/>  }))</pre> | `{}` | no |
| <a name="input_auto_pause_delay_in_minutes"></a> [auto\_pause\_delay\_in\_minutes](#input\_auto\_pause\_delay\_in\_minutes) | Minutes of inactivity before a serverless database pauses, or -1 to never pause. Minimum 60. Paused databases bill for storage only, which is what makes serverless near-free in a dev environment used a few hours a day. The cost is a cold-start delay of several seconds on the first connection after a pause. | `number` | `60` | no |
| <a name="input_azuread_authentication_only"></a> [azuread\_authentication\_only](#input\_azuread\_authentication\_only) | Disable SQL authentication entirely. Should be TRUE. Setting false reintroduces a password that must be generated, stored and rotated — and that lands in Terraform state in plaintext. | `bool` | `true` | no |
| <a name="input_collation"></a> [collation](#input\_collation) | Database collation. Cannot be changed after creation without recreating the database. | `string` | `"SQL_Latin1_General_CP1_CI_AS"` | no |
| <a name="input_connection_policy"></a> [connection\_policy](#input\_connection\_policy) | "Default" lets Azure choose Redirect inside the region and Proxy outside. "Redirect" is lower latency but requires ports 11000-11999 open to the client. "Proxy" uses only 1433 and works everywhere, at a latency cost. | `string` | `"Default"` | no |
| <a name="input_create_private_endpoint"></a> [create\_private\_endpoint](#input\_create\_private\_endpoint) | Whether to create a private endpoint. A STATIC boolean, for the same reason as the other data modules: a count derived from an unknown subnet ID cannot be resolved at plan time from an empty state. | `bool` | `true` | no |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | Database name. | `string` | n/a | yes |
| <a name="input_entra_administrator_is_group"></a> [entra\_administrator\_is\_group](#input\_entra\_administrator\_is\_group) | Whether the administrator principal is a group. Recorded so the reachability output can flag the single-user case, which is a governance weakness rather than a technical fault. | `bool` | `false` | no |
| <a name="input_entra_administrator_login"></a> [entra\_administrator\_login](#input\_entra\_administrator\_login) | Display name or UPN of the Entra principal that administers the server. For a group, its display name. | `string` | n/a | yes |
| <a name="input_entra_administrator_object_id"></a> [entra\_administrator\_object\_id](#input\_entra\_administrator\_object\_id) | Object ID of the Entra principal that administers the server. STRONGLY prefer a GROUP over an individual: a user object ID ties production database administration to one person's account, which breaks when they leave and cannot be reviewed as a role. | `string` | n/a | yes |
| <a name="input_geo_backup_enabled"></a> [geo\_backup\_enabled](#input\_geo\_backup\_enabled) | Geo Backup Policy flag. Only applicable to DataWarehouse SKUs, and IGNORED<br/>by Azure for every other tier — set it false on a General Purpose database<br/>and Azure keeps reporting true, producing a diff on every plan forever.<br/><br/>The module therefore only sends this for DW\_ SKUs and leaves it unset<br/>otherwise. Actual backup redundancy for normal databases is governed by<br/>storage\_account\_type, which does take effect. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_long_term_retention"></a> [long\_term\_retention](#input\_long\_term\_retention) | Long-term retention durations in ISO 8601, e.g. { weekly = "P4W", monthly = "P12M", yearly = "P5Y", week\_of\_year = 1 }. Only applied when long\_term\_retention\_enabled is true. | <pre>object({<br/>    weekly       = optional(string, "P4W")<br/>    monthly      = optional(string, "P12M")<br/>    yearly       = optional(string, "P5Y")<br/>    week_of_year = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_long_term_retention_enabled"></a> [long\_term\_retention\_enabled](#input\_long\_term\_retention\_enabled) | Whether to keep weekly, monthly and yearly backups beyond the point-in-time window. Pass the profile's sql\_enable\_long\_term\_retention. | `bool` | `false` | no |
| <a name="input_max_size_gb"></a> [max\_size\_gb](#input\_max\_size\_gb) | Maximum database size in GB. | `number` | `32` | no |
| <a name="input_min_capacity"></a> [min\_capacity](#input\_min\_capacity) | Minimum vCores for a serverless database. Only meaningful for GP\_S\_ SKUs. | `number` | `0.5` | no |
| <a name="input_minimum_tls_version"></a> [minimum\_tls\_version](#input\_minimum\_tls\_version) | Minimum TLS version for connections. | `string` | `"1.2"` | no |
| <a name="input_outbound_network_restriction_enabled"></a> [outbound\_network\_restriction\_enabled](#input\_outbound\_network\_restriction\_enabled) | Restrict the server's own outbound connections to approved targets. Relevant when using external data sources or auditing to storage; harmless otherwise. | `bool` | `false` | no |
| <a name="input_private_dns_zone_ids"></a> [private\_dns\_zone\_ids](#input\_private\_dns\_zone\_ids) | Private DNS zone IDs for privatelink.database.windows.net. Without these the endpoint registers no A record and the server resolves to its public address from inside the VNet. | `list(string)` | `[]` | no |
| <a name="input_private_endpoint_name"></a> [private\_endpoint\_name](#input\_private\_endpoint\_name) | Name for the private endpoint. | `string` | `null` | no |
| <a name="input_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#input\_private\_endpoint\_subnet\_id) | Subnet for the private endpoint. Null skips creation, which is only safe while the public endpoint remains enabled. | `string` | `null` | no |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether the server keeps a public endpoint. Pass the profile's data\_plane\_public\_access\_enabled. When false, only the private endpoint reaches the server — including for schema migrations run from a laptop. | `bool` | `false` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "data" lifecycle scope. | `string` | n/a | yes |
| <a name="input_server_name"></a> [server\_name](#input\_server\_name) | Logical server name, from naming.sql\_server\_name. Globally unique. | `string` | n/a | yes |
| <a name="input_server_version"></a> [server\_version](#input\_server\_version) | Logical server version. "12.0" is the only value Azure SQL Database accepts; it does not correspond to a SQL Server product version. | `string` | `"12.0"` | no |
| <a name="input_short_term_retention_days"></a> [short\_term\_retention\_days](#input\_short\_term\_retention\_days) | Point-in-time restore window in days, 1-35. Pass the profile's sql\_backup\_retention\_days. This is the window in which an accidental delete or a bad migration can be undone. | `number` | `7` | no |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | Service objective, e.g. "GP\_S\_Gen5\_1" for serverless, "GP\_Gen5\_2" provisioned, "BC\_Gen5\_4" Business Critical. Pass the profile's sql\_sku\_name. Serverless (GP\_S\_) bills per second of compute and pauses when idle. | `string` | `"GP_S_Gen5_1"` | no |
| <a name="input_storage_account_type"></a> [storage\_account\_type](#input\_storage\_account\_type) | Backup storage redundancy: "Local", "Zone" or "Geo". Geo is the default in Azure and costs meaningfully more; Local is appropriate for dev. | `string` | `"Local"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_zone_redundant"></a> [zone\_redundant](#input\_zone\_redundant) | Spread replicas across availability zones. Pass the profile's sql\_zone\_redundant. Requires Business Critical or Premium — General Purpose serverless does not support it, and Azure rejects the combination. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_administrator_is_individual"></a> [administrator\_is\_individual](#output\_administrator\_is\_individual) | True when the Entra administrator is a named user rather than a group. A governance weakness rather than a technical fault: it ties database administration to one person's account, which breaks when they leave and cannot be reviewed as a role. Prefer a group. |
| <a name="output_auto_pause_delay_in_minutes"></a> [auto\_pause\_delay\_in\_minutes](#output\_auto\_pause\_delay\_in\_minutes) | Minutes of inactivity before pausing, -1 for never, or null on a provisioned SKU. A paused database bills for storage only — the reason serverless is near-free in an environment used a few hours a day. The cost is a cold-start delay of several seconds on the first connection after a pause. |
| <a name="output_azuread_authentication_only"></a> [azuread\_authentication\_only](#output\_azuread\_authentication\_only) | Whether SQL authentication is disabled entirely. True means no password was ever set and none can be used. Note that Azure still records a placeholder administratorLogin value on the server — it is an artefact, not a usable credential, because SQL auth is off. |
| <a name="output_backup_summary"></a> [backup\_summary](#output\_backup\_summary) | Effective backup posture: the point-in-time window, whether long-term retention is on, and where backups are stored. |
| <a name="output_connection_guidance"></a> [connection\_guidance](#output\_connection\_guidance) | How to connect. There is no password because there is no SQL login — applications present a managed identity. |
| <a name="output_database_id"></a> [database\_id](#output\_database\_id) | ARM resource ID of the database. Diagnostic settings target this. |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Database name. |
| <a name="output_is_serverless"></a> [is\_serverless](#output\_is\_serverless) | Whether the database uses the serverless compute model, which bills per second and pauses when idle. |
| <a name="output_private_endpoint_id"></a> [private\_endpoint\_id](#output\_private\_endpoint\_id) | Private endpoint resource ID, or null when none was created. |
| <a name="output_private_endpoint_ip"></a> [private\_endpoint\_ip](#output\_private\_endpoint\_ip) | Private IP the server FQDN resolves to inside the VNet. |
| <a name="output_reachable_from"></a> [reachable\_from](#output\_reachable\_from) | Who can reach the server, in plain language. |
| <a name="output_server_fqdn"></a> [server\_fqdn](#output\_server\_fqdn) | Fully qualified domain name. Resolves to the private endpoint from inside the VNet and to the public endpoint elsewhere — the same hostname either way, so connection strings do not change. |
| <a name="output_server_id"></a> [server\_id](#output\_server\_id) | ARM resource ID of the logical server. |
| <a name="output_server_name"></a> [server\_name](#output\_server\_name) | Logical server name. |
| <a name="output_server_principal_id"></a> [server\_principal\_id](#output\_server\_principal\_id) | System-assigned managed identity of the server. Grant this access when the server must authenticate outbound — to a Key Vault holding a customer-managed TDE key, or to a storage account receiving audit logs. |
| <a name="output_sku_name"></a> [sku\_name](#output\_sku\_name) | Service objective actually deployed. |
<!-- END_TF_DOCS -->
