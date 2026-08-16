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

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |
| <a name="provider_time"></a> [time](#provider\_time) | 0.14.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_private_endpoint.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_role_assignment.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [time_sleep.rbac_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_tier"></a> [access\_tier](#input\_access\_tier) | Default blob access tier, "Hot" or "Cool". Cool has lower storage cost and higher access cost, plus an early-deletion charge before 30 days — it loses money for anything read regularly. | `string` | `"Hot"` | no |
| <a name="input_account_kind"></a> [account\_kind](#input\_account\_kind) | "StorageV2" is correct for essentially all new accounts. The legacy Storage and BlobStorage kinds lack features and cannot be upgraded in place without migration. | `string` | `"StorageV2"` | no |
| <a name="input_account_replication_type"></a> [account\_replication\_type](#input\_account\_replication\_type) | Redundancy. Pass the profile's storage\_replication\_type. LRS keeps three copies in one datacentre; ZRS spreads across zones in one region; GZRS adds a paired region. Each step up roughly doubles the storage rate. | `string` | `"LRS"` | no |
| <a name="input_account_tier"></a> [account\_tier](#input\_account\_tier) | "Standard" or "Premium". Premium is SSD-backed with lower latency and is billed on provisioned capacity rather than consumption — it only makes sense for sustained high-IOPS workloads. | `string` | `"Standard"` | no |
| <a name="input_allow_nested_items_to_be_public"></a> [allow\_nested\_items\_to\_be\_public](#input\_allow\_nested\_items\_to\_be\_public) | Whether individual containers may be set to public access. FALSE makes anonymous public blob access impossible ACCOUNT-WIDE regardless of per-container settings — a single switch that forecloses the most common storage data-exposure incident. | `bool` | `false` | no |
| <a name="input_allowed_ip_rules"></a> [allowed\_ip\_rules](#input\_allowed\_ip\_rules) | Public IPv4 addresses or CIDRs permitted to reach the data plane. Azure rejects /31 and /32 suffixes here; supply bare addresses. Private ranges are also rejected — they are meaningless on a public endpoint. | `list(string)` | `[]` | no |
| <a name="input_allowed_subnet_ids"></a> [allowed\_subnet\_ids](#input\_allowed\_subnet\_ids) | Subnet IDs permitted via service endpoint. Requires Microsoft.Storage service endpoints on those subnets. Distinct from the private endpoint path. | `list(string)` | `[]` | no |
| <a name="input_blob_change_feed_enabled"></a> [blob\_change\_feed\_enabled](#input\_blob\_change\_feed\_enabled) | Record an ordered, immutable log of every blob change. Useful for audit and for downstream event processing; billed as stored data. | `bool` | `false` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Days a soft-deleted blob remains recoverable, 1-365. Zero disables soft delete entirely, which makes an accidental delete permanent. | `number` | `7` | no |
| <a name="input_blob_versioning_enabled"></a> [blob\_versioning\_enabled](#input\_blob\_versioning\_enabled) | Keep previous versions of overwritten blobs. Pass the profile's storage\_enable\_versioning. Every version is billed as stored data, so pair it with a lifecycle policy in production. | `bool` | `false` | no |
| <a name="input_container_delete_retention_days"></a> [container\_delete\_retention\_days](#input\_container\_delete\_retention\_days) | Days a soft-deleted container remains recoverable, 1-365. Deleting a container removes every blob in it, so this is the more consequential of the two retention settings. | `number` | `7` | no |
| <a name="input_containers"></a> [containers](#input\_containers) | Map of container name to { access\_type }. access\_type must be "private" unless allow\_nested\_items\_to\_be\_public is true, which it should not be. | <pre>map(object({<br/>    access_type = optional(string, "private")<br/>    metadata    = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_create_private_endpoints"></a> [create\_private\_endpoints](#input\_create\_private\_endpoints) | Whether to create private endpoints. A STATIC boolean: deriving it from `private_endpoint_subnet_id != null` makes for\_each depend on a value unknown until apply, breaking any plan from an empty state. | `bool` | `true` | no |
| <a name="input_cross_tenant_replication_enabled"></a> [cross\_tenant\_replication\_enabled](#input\_cross\_tenant\_replication\_enabled) | Whether object replication to an account in another Entra tenant is permitted. Off by default: it is an exfiltration path that requires no network access at all. | `bool` | `false` | no |
| <a name="input_default_to_oauth_authentication"></a> [default\_to\_oauth\_authentication](#input\_default\_to\_oauth\_authentication) | Make the portal default to Entra ID rather than account keys when browsing data. Cosmetic when keys are disabled, but it stops operators reaching for a key first. | `bool` | `true` | no |
| <a name="input_infrastructure_encryption_enabled"></a> [infrastructure\_encryption\_enabled](#input\_infrastructure\_encryption\_enabled) | Add a second, independent layer of encryption at rest. Cannot be changed after creation. Required by some regimes; otherwise a modest performance cost for defence in depth. | `bool` | `false` | no |
| <a name="input_local_user_enabled"></a> [local\_user\_enabled](#input\_local\_user\_enabled) | Whether SFTP and NFS local users may authenticate. Off unless SFTP is genuinely in use — local users are a second credential system outside Entra ID. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_min_tls_version"></a> [min\_tls\_version](#input\_min\_tls\_version) | Minimum TLS version. TLS1\_2 is the floor; anything lower is rejected by most compliance regimes and by modern clients anyway. | `string` | `"TLS1_2"` | no |
| <a name="input_name"></a> [name](#input\_name) | Storage account name, from naming.storage\_account\_name. Globally unique, 3-24 lowercase alphanumerics, no hyphens. | `string` | n/a | yes |
| <a name="input_network_rules_bypass"></a> [network\_rules\_bypass](#input\_network\_rules\_bypass) | Trusted paths exempt from the rules. "AzureServices" is normally required — without it, diagnostic settings writing to this account, and Azure Backup, are blocked. | `list(string)` | <pre>[<br/>  "AzureServices"<br/>]</pre> | no |
| <a name="input_network_rules_default_action"></a> [network\_rules\_default\_action](#input\_network\_rules\_default\_action) | Action for traffic matching no rule. Must be "Deny" for the IP and subnet rules to mean anything. | `string` | `"Deny"` | no |
| <a name="input_private_dns_zone_ids_by_subresource"></a> [private\_dns\_zone\_ids\_by\_subresource](#input\_private\_dns\_zone\_ids\_by\_subresource) | Map of sub-resource name to its private DNS zone IDs, e.g. { blob = ["/subscriptions/.../privatelink.blob.core.windows.net"] }. Without the zone the endpoint registers no A record and the account resolves to its public address from inside the VNet. | `map(list(string))` | `{}` | no |
| <a name="input_private_endpoint_name_prefix"></a> [private\_endpoint\_name\_prefix](#input\_private\_endpoint\_name\_prefix) | Prefix for private endpoint names; the sub-resource is appended, e.g. "pep-st-cloudcart-dev-eus" becomes "pep-st-cloudcart-dev-eus-blob". | `string` | `null` | no |
| <a name="input_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#input\_private\_endpoint\_subnet\_id) | Subnet for private endpoints. Null skips creation, which is only safe while the public endpoint remains enabled. | `string` | `null` | no |
| <a name="input_private_endpoint_subresources"></a> [private\_endpoint\_subresources](#input\_private\_endpoint\_subresources) | Sub-resources to create private endpoints for: blob, file, queue, table, dfs, web. Each needs its own DNS zone in private\_dns\_zone\_ids\_by\_subresource. | `list(string)` | <pre>[<br/>  "blob"<br/>]</pre> | no |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether the account keeps a public endpoint. Pass the profile's data\_plane\_public\_access\_enabled. When false, only the private endpoint reaches the data plane — including for Terraform. | `bool` | `false` | no |
| <a name="input_rbac_propagation_delay_seconds"></a> [rbac\_propagation\_delay\_seconds](#input\_rbac\_propagation\_delay\_seconds) | Seconds to wait after data-plane role assignments before creating containers. With shared keys disabled, container creation authenticates as the caller's Entra principal, so the role must be effective first — and Azure exposes no API to wait on. Set 0 to disable. | `number` | `45` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "data" lifecycle scope. | `string` | n/a | yes |
| <a name="input_role_assignments"></a> [role\_assignments](#input\_role\_assignments) | Map of assignment key to { principal\_id, role\_definition\_name }. Scoped to this account. With shared keys disabled these grants are the ONLY way to reach data — note that Owner and Contributor are control-plane roles and do NOT confer data access. | <pre>map(object({<br/>    principal_id         = string<br/>    role_definition_name = string<br/>    principal_type       = optional(string, "ServicePrincipal")<br/>    description          = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_shared_access_key_enabled"></a> [shared\_access\_key\_enabled](#input\_shared\_access\_key\_enabled) | Whether the two static account keys may be used. Should be FALSE. Note the consequence: Terraform, the CLI and the portal all fall back to Entra ID for data-plane work, so the caller needs a data-plane RBAC role — being subscription Owner is not sufficient, because Owner grants control-plane rights only. | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_allows_public_blob_access"></a> [allows\_public\_blob\_access](#output\_allows\_public\_blob\_access) | Whether any container in this account could be made anonymously readable. False forecloses the most common storage data-exposure incident account-wide, regardless of per-container settings. |
| <a name="output_container_ids"></a> [container\_ids](#output\_container\_ids) | Map of container name to resource ID. |
| <a name="output_container_names"></a> [container\_names](#output\_container\_names) | Containers created in this account. |
| <a name="output_granted_principal_ids"></a> [granted\_principal\_ids](#output\_granted\_principal\_ids) | Principals holding a role on this account, with the role. With shared keys disabled this is the complete list of who can reach the data — control-plane roles such as Owner do not confer data access. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the storage account. Role assignment scopes and diagnostic settings target this. |
| <a name="output_name"></a> [name](#output\_name) | Storage account name. |
| <a name="output_primary_blob_endpoint"></a> [primary\_blob\_endpoint](#output\_primary\_blob\_endpoint) | Blob service endpoint. Resolves to the private endpoint from inside the VNet and to the firewalled public endpoint elsewhere — the same hostname either way. |
| <a name="output_primary_dfs_endpoint"></a> [primary\_dfs\_endpoint](#output\_primary\_dfs\_endpoint) | Data Lake Gen2 endpoint, present whether or not hierarchical namespace is enabled. |
| <a name="output_private_endpoint_ids"></a> [private\_endpoint\_ids](#output\_private\_endpoint\_ids) | Map of sub-resource to private endpoint resource ID. |
| <a name="output_private_endpoint_ips"></a> [private\_endpoint\_ips](#output\_private\_endpoint\_ips) | Map of sub-resource to the private IP it resolves to inside the VNet. Useful for confirming DNS resolves to the endpoint rather than to the public address. |
| <a name="output_private_endpoint_subresources"></a> [private\_endpoint\_subresources](#output\_private\_endpoint\_subresources) | Sub-resources reachable privately. Anything absent still resolves publicly — a blob endpoint does not make file resolve. |
| <a name="output_reachable_from"></a> [reachable\_from](#output\_reachable\_from) | Who can reach the data plane, in plain language. |
| <a name="output_shared_access_key_enabled"></a> [shared\_access\_key\_enabled](#output\_shared\_access\_key\_enabled) | Whether the static account keys work. False is the intended state: keys are the most frequently leaked Azure credential, and disabling them forces every consumer onto Entra ID. |
<!-- END_TF_DOCS -->
