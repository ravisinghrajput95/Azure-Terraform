# Module: `storage`

Storage account with shared access keys disabled, anonymous access foreclosed
account-wide, a private endpoint per sub-resource, and a firewalled public
endpoint driven by the environment profile.

---

## Shared access keys are the point

Storage account keys are the **most frequently leaked Azure credential**:

- Static, and they never expire
- Cannot be scoped to a container, a prefix, or an operation
- Grant complete control of the account to anyone holding one
- End up in connection strings, CI variables, `appsettings.json`, and support
  tickets

`shared_access_key_enabled = false` is the single highest-value control on a
storage account, and it is the default here.

**It has a consequence worth stating plainly.** Every data-plane caller —
Terraform, the CLI, the portal — then authenticates with Entra ID and needs a
**data-plane role**. Control-plane roles do not help:

> A subscription **Owner** with no data role receives **403** on a container
> list.

The roles that work are `Storage Blob Data Owner`, `Storage Blob Data
Contributor` and `Storage Blob Data Reader`. A precondition catches the
combination "containers requested + keys disabled + no data-plane grant",
which otherwise fails mid-apply with an authorisation error naming neither the
missing role nor the reason.

The provider also needs `storage_use_azuread = true`, or it tries to fetch a
key that does not exist.

---

## Usage

```hcl
module "storage" {
  source = "../../modules/storage"

  name                = module.naming.storage_account_name
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  account_replication_type = module.profile.profile.storage_replication_type
  blob_versioning_enabled  = module.profile.profile.storage_enable_versioning

  shared_access_key_enabled = false

  public_network_access_enabled = module.profile.data_plane_public_access_enabled
  network_rules_default_action  = "Deny"
  allowed_ip_rules              = var.deployer_ip_addresses

  private_endpoint_subnet_id    = module.networking.subnet_ids["snet-pep-dev-eus"]
  private_endpoint_name_prefix  = "pep-st-cloudcart-dev-eus"
  private_endpoint_subresources = ["blob"]

  private_dns_zone_ids_by_subresource = {
    blob = [module.private_dns.zone_ids_by_service["blob"]]
  }

  role_assignments = {
    app = {
      principal_id         = module.managed_identity.principal_ids["app"]
      role_definition_name = "Storage Blob Data Contributor"
    }
  }

  containers = { "app-data" = {} }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | 3–24 lowercase alphanumerics. |
| `resource_group_name` | `string` | — | The `data` scope. |
| `location`, `tags` | | — | |
| `account_tier` | `string` | `"Standard"` | |
| `account_replication_type` | `string` | `"LRS"` | From `profile`. |
| `account_kind` | `string` | `"StorageV2"` | Legacy kinds not offered. |
| `access_tier` | `string` | `"Hot"` | |
| `shared_access_key_enabled` | `bool` | `false` | See above. |
| `default_to_oauth_authentication` | `bool` | `true` | |
| `local_user_enabled` | `bool` | `false` | SFTP/NFS local users. |
| `min_tls_version` | `string` | `"TLS1_2"` | Only value accepted. |
| `allow_nested_items_to_be_public` | `bool` | `false` | Account-wide. |
| `cross_tenant_replication_enabled` | `bool` | `false` | Exfiltration path. |
| `infrastructure_encryption_enabled` | `bool` | `false` | Immutable after create. |
| `blob_versioning_enabled` | `bool` | `false` | From `profile`. |
| `blob_change_feed_enabled` | `bool` | `false` | |
| `blob_delete_retention_days` | `number` | `7` | |
| `container_delete_retention_days` | `number` | `7` | |
| `public_network_access_enabled` | `bool` | `false` | From `profile`. |
| `network_rules_default_action` | `string` | `"Deny"` | |
| `network_rules_bypass` | `list(string)` | `["AzureServices"]` | |
| `allowed_ip_rules` | `list(string)` | `[]` | Bare addresses only. |
| `allowed_subnet_ids` | `list(string)` | `[]` | |
| `private_endpoint_subnet_id` | `string` | `null` | |
| `private_endpoint_subresources` | `list(string)` | `["blob"]` | |
| `private_dns_zone_ids_by_subresource` | `map(list(string))` | `{}` | |
| `private_endpoint_name_prefix` | `string` | `null` | |
| `role_assignments` | `map(object)` | `{}` | Scoped to this account. |
| `containers` | `map(object)` | `{}` | |
| `rbac_propagation_delay_seconds` | `number` | `45` | |

## Outputs

`id`, `name`, `primary_blob_endpoint`, `primary_dfs_endpoint`,
`container_names`, `container_ids`, `private_endpoint_ids`,
`private_endpoint_ips`, `private_endpoint_subresources`,
`shared_access_key_enabled`, `allows_public_blob_access`, `reachable_from`,
`granted_principal_ids`

**Access keys and connection strings are deliberately not exported.** They are
inert when keys are disabled, and exporting them would push a static,
non-expiring, unscopable credential into every consuming module's state and
plan output. If a legacy component genuinely needs one, read it deliberately
with `terraform state show`.

---

## One private endpoint per sub-resource

`blob`, `file`, `queue`, `table`, `dfs` and `web` are **separate endpoints with
separate private DNS zones**. A blob endpoint does not make file resolve
privately — this catches people out regularly, and the symptom is that one
service works privately while another silently uses the public path.

A precondition rejects any requested sub-resource with no matching DNS zone,
because an endpoint without a zone group registers no A record and the account
resolves to its **public** address from inside the VNet.

---

## Other defaults that are security decisions

**`allow_nested_items_to_be_public = false`** forecloses anonymous public blob
access **account-wide**, regardless of what any container sets. One switch that
removes the most common storage data-exposure incident.

**`cross_tenant_replication_enabled = false`** — object replication to an
account in another Entra tenant is an exfiltration path that requires no
network access at all.

**`local_user_enabled = false`** — SFTP/NFS local users are a second credential
system outside Entra ID.

**Private RFC1918 addresses are rejected in `allowed_ip_rules`** by validation,
because Azure rejects them too: a public endpoint never sees a private source
address. Use `allowed_subnet_ids` or the private endpoint.

---

## RBAC propagation

Entra ID role assignments are eventually consistent. A data-plane grant made at
second zero is frequently not effective when container creation uses it moments
later, and the resulting 403 is indistinguishable from a genuinely missing
permission.

`rbac_propagation_delay_seconds` (default 45) inserts a wait between the role
assignments and the containers. A timer, not a fix.

---

## Cost

| Component | Approximate |
|---|---|
| Account | Free; billed on stored data and transactions |
| Private endpoint | ~$7.30/month each + data processed |
| Blob versioning | Every version billed as stored data |

Versioning without a lifecycle policy is the usual cause of a storage bill that
grows without anyone adding data.

---

## Deployed state

`dev`:

```
shared access keys       disabled
public blob access       foreclosed account-wide
min TLS                  1.2
replication              LRS
public endpoint          Deny by default, operator IP allowed
private endpoint         blob
containers               app-data
```

Grants: `app` and `biz` identities hold **Storage Blob Data Contributor**; the
deploying operator holds **Storage Blob Data Owner**.
