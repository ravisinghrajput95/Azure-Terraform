# Module: `key-vault`

Key Vault with RBAC authorization, a private endpoint, and a firewalled public
endpoint whose exposure is driven by the environment profile.

---

## Control plane vs data plane

This distinction causes most Key Vault confusion, and the module is shaped
around it.

| | Managed by | Subject to network rules |
|---|---|---|
| Creating the vault, setting its ACLs | Control plane | **No** |
| Reading, writing, deleting a secret | Data plane | **Yes** |

So Terraform can create a vault it cannot then put a secret into. The apply
**succeeds**; the failure appears later, when something first reads a secret.

Two preconditions exist purely because of this:

- A vault with **no public endpoint and no private endpoint** is created
  successfully and is unreachable by everything, including Terraform.
- A **private endpoint with no DNS zone group** registers no A record, so the
  vault hostname resolves to its *public* address from inside the VNet —
  failing outright when public access is off, and silently bypassing the
  private path when it is on.

---

## RBAC only

The legacy access policy model is **not exposed by this module at all**.

- Access policies do not compose with Azure RBAC. A vault using them ignores
  role assignments entirely, so a principal holding "Key Vault Administrator"
  still cannot read a secret.
- Policy grants are invisible to `az role assignment list` and to standard
  access reviews, so they accumulate unnoticed.
- They are per-vault, so the same grant is repeated everywhere rather than
  assigned once at a higher scope.

The argument is `rbac_authorization_enabled`. The older
`enable_rbac_authorization` is deprecated in azurerm 4.x.

---

## Usage

```hcl
module "key_vault" {
  source = "../../modules/key-vault"

  name                = module.naming.key_vault_name
  resource_group_name = module.resource_group.names["sec"]
  location            = module.resource_group.location
  tags                = module.tags.tags
  tenant_id           = data.azurerm_client_config.current.tenant_id

  purge_protection_enabled   = module.profile.profile.key_vault_purge_protection
  soft_delete_retention_days = module.profile.profile.key_vault_soft_delete_retention_days

  public_network_access_enabled = module.profile.data_plane_public_access_enabled
  network_acls_default_action   = "Deny"
  allowed_ip_rules              = var.deployer_ip_addresses

  private_endpoint_subnet_id = module.networking.subnet_ids["snet-pep-dev-eus"]
  private_endpoint_name      = "pep-kv-cloudcart-dev-eus-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["keyvault"]]

  role_assignments = {
    app = {
      principal_id         = module.managed_identity.principal_ids["app"]
      role_definition_name = "Key Vault Secrets User"
    }
  }

  depends_on = [module.managed_identity]
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | From `naming.key_vault_name`. |
| `resource_group_name` | `string` | — | The `sec` scope. |
| `location`, `tags`, `tenant_id` | | — | |
| `sku_name` | `string` | `"standard"` | `premium` adds HSM-backed keys. |
| `purge_protection_enabled` | `bool` | `false` | **Irreversible.** See below. |
| `soft_delete_retention_days` | `number` | `7` | 7–90. |
| `public_network_access_enabled` | `bool` | `false` | From `profile`. |
| `network_acls_default_action` | `string` | `"Deny"` | |
| `network_acls_bypass` | `string` | `"AzureServices"` | |
| `allowed_ip_rules` | `list(string)` | `[]` | Bare addresses, no `/32`. |
| `allowed_subnet_ids` | `list(string)` | `[]` | Service-endpoint path. |
| `private_endpoint_subnet_id` | `string` | `null` | |
| `private_endpoint_name` | `string` | `null` | |
| `private_dns_zone_ids` | `list(string)` | `[]` | |
| `role_assignments` | `map(object)` | `{}` | Scoped to this vault. |
| `enabled_for_*` | `bool` | `false` | Platform integrations. |

## Outputs

`id`, `name`, `vault_uri`, `tenant_id`, `private_endpoint_id`,
`private_endpoint_ip`, `public_network_access_enabled`,
`public_access_is_firewalled`, `reachable_from`,
`public_endpoint_locked_shut`, `purge_protection_enabled`,
`soft_delete_retention_days`, `role_assignment_ids`, `granted_principal_ids`

---

## Purge protection is irreversible

Azure provides **no way to turn it off** once enabled. With it on, a deleted
vault's *name* stays reserved until the retention period expires — and because
`naming` produces a deterministic name, the environment cannot be rebuilt for
up to 90 days.

That is correct for production, where the risk being managed is permanent loss
of keys. It is wrong for dev, where destroy/recreate is the primary cost
control on a credit-limited subscription. The `profile` module sets it
accordingly, and a production guardrail rejects turning it off in prod.

---

## Network posture

`reachable_from` renders the effective posture in plain language, because it
depends on three interacting settings and is the most common Key Vault support
question:

```
Private endpoint from inside the VNet. Public endpoint restricted to
1 IP rule(s) and 0 subnet(s). Trusted Azure services bypass the rules.
```

Two misconfigurations are rejected at plan time:

**`default_action = "Allow"` with rules configured.** This reads as an
allowlist and is not one — default Allow permits every source not explicitly
denied, so the rules have no effect at all.

**`allowed_ip_rules` containing `/31` or `/32`.** Azure rejects those suffixes
in Key Vault IP rules specifically. Supply a bare address.

`public_endpoint_locked_shut` reports the case where a public endpoint exists,
denies by default, and has no rules — legitimate when a private endpoint
carries everything, but usually a forgotten allowlist.

---

## Role assignments

Created here, **scoped to this vault**, so a grant dies with the vault rather
than outliving it as an orphaned assignment against a deleted scope.

`principal_type` is declared rather than looked up. Azure otherwise queries
Entra ID to determine the type, and that query is exactly what fails for a
principal created moments earlier in the same apply.

Common roles:

| Role | Grants |
|---|---|
| `Key Vault Secrets User` | Read secrets. Correct for an application. |
| `Key Vault Secrets Officer` | Manage secrets, not keys or certificates. |
| `Key Vault Administrator` | Full data-plane control. Operators only. |

Applications get **Secrets User** — read-only. An application that can delete a
secret can take out its own tier and every other consumer of that secret.

---

## Cost

| Component | Approximate |
|---|---|
| Vault (standard) | Free, plus ~$0.03 per 10,000 operations |
| Private endpoint | ~$7.30/month + data processed |

The private endpoint is essentially the entire cost.

---

## Deployed state

`dev` — RBAC authorization, purge protection off, 7-day soft delete, private
endpoint in `snet-pep-dev-eus`, public endpoint denying by default with the
operator IP allowed.

Grants: `app` and `biz` identities hold **Key Vault Secrets User**; the
deploying operator holds **Key Vault Administrator**.

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
| [azurerm_key_vault.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_private_endpoint.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_role_assignment.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ip_rules"></a> [allowed\_ip\_rules](#input\_allowed\_ip\_rules) | Public IPv4 addresses or CIDRs permitted to reach the data plane. Only meaningful when public\_network\_access\_enabled is true. Note that Azure rejects /31 and /32 suffixes here — supply a bare address for a single host. | `list(string)` | `[]` | no |
| <a name="input_allowed_subnet_ids"></a> [allowed\_subnet\_ids](#input\_allowed\_subnet\_ids) | Subnet IDs permitted to reach the data plane through a service endpoint. Distinct from the private endpoint path — this is for subnets reaching the PUBLIC endpoint over the Microsoft backbone, and requires Microsoft.KeyVault service endpoints on those subnets. | `list(string)` | `[]` | no |
| <a name="input_create_private_endpoint"></a> [create\_private\_endpoint](#input\_create\_private\_endpoint) | Whether to create a private endpoint. A STATIC boolean, deliberately: deriving this from `private_endpoint_subnet_id != null` makes count depend on a value that is unknown until apply, which fails any plan from an empty state — so the module would work incrementally and break for a fresh environment. | `bool` | `true` | no |
| <a name="input_enabled_for_deployment"></a> [enabled\_for\_deployment](#input\_enabled\_for\_deployment) | Allow virtual machines to retrieve certificates stored as secrets. Needed only for VM certificate provisioning. | `bool` | `false` | no |
| <a name="input_enabled_for_disk_encryption"></a> [enabled\_for\_disk\_encryption](#input\_enabled\_for\_disk\_encryption) | Allow Azure Disk Encryption to retrieve and unwrap keys. | `bool` | `false` | no |
| <a name="input_enabled_for_template_deployment"></a> [enabled\_for\_template\_deployment](#input\_enabled\_for\_template\_deployment) | Allow ARM template deployments to reference secrets. Rarely needed alongside Terraform, and it widens the set of principals that can read the vault indirectly. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Key Vault name, from naming.key\_vault\_name. Globally unique, 3-24 characters. | `string` | n/a | yes |
| <a name="input_network_acls_bypass"></a> [network\_acls\_bypass](#input\_network\_acls\_bypass) | "AzureServices" permits trusted Microsoft services to reach the vault regardless of the rules — required for disk encryption, Storage CMK and App Service certificate references. "None" is stricter and breaks those integrations. | `string` | `"AzureServices"` | no |
| <a name="input_network_acls_default_action"></a> [network\_acls\_default\_action](#input\_network\_acls\_default\_action) | Action for traffic matching no rule. Must be "Deny" in any environment that matters: "Allow" makes the IP and subnet rules decorative, since everything not explicitly denied is permitted. | `string` | `"Deny"` | no |
| <a name="input_private_dns_zone_ids"></a> [private\_dns\_zone\_ids](#input\_private\_dns\_zone\_ids) | Private DNS zone IDs for privatelink.vaultcore.azure.net, from the private-dns module. Without these the endpoint exists but registers no A record, and the vault name resolves to its public address from inside the VNet. | `list(string)` | `[]` | no |
| <a name="input_private_endpoint_name"></a> [private\_endpoint\_name](#input\_private\_endpoint\_name) | Name for the private endpoint. | `string` | `null` | no |
| <a name="input_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#input\_private\_endpoint\_subnet\_id) | Subnet for the vault's private endpoint. Null skips creation, which is only safe when the public endpoint remains enabled. | `string` | `null` | no |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether the vault keeps a public endpoint. When false, the vault is reachable ONLY from inside the VNet via private endpoint — including by Terraform, which means a runner outside the network cannot manage secrets. Pass the profile's data\_plane\_public\_access\_enabled. | `bool` | `false` | no |
| <a name="input_purge_protection_enabled"></a> [purge\_protection\_enabled](#input\_purge\_protection\_enabled) | Whether a soft-deleted vault can be purged before its retention period<br/>expires.<br/><br/>ENABLING THIS IS IRREVERSIBLE. Azure provides no way to turn it off once<br/>set. With it on, a deleted vault's NAME is unusable until retention<br/>expires — and because the naming module produces a deterministic name,<br/>that means the environment cannot be rebuilt for up to 90 days.<br/><br/>Correct for production, where the risk being managed is permanent loss of<br/>keys. Wrong for dev, where the destroy/recreate cycle is the primary cost<br/>control on a credit-limited subscription. | `bool` | `false` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "sec" lifecycle scope — the vault is security-team owned and outlives the compute that reads from it. | `string` | n/a | yes |
| <a name="input_role_assignments"></a> [role\_assignments](#input\_role\_assignments) | Map of assignment key to { principal\_id, role\_definition\_name }. Scoped to this vault, so grants die with it rather than outliving it as orphans. Common roles: "Key Vault Secrets User" to read, "Key Vault Secrets Officer" to manage, "Key Vault Administrator" for full data-plane control. | <pre>map(object({<br/>    principal_id         = string<br/>    role_definition_name = string<br/>    principal_type       = optional(string, "ServicePrincipal")<br/>    description          = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | "standard" or "premium". Premium adds HSM-backed keys and costs meaningfully more per key operation. Standard is correct unless a compliance regime specifically requires FIPS 140-2 Level 2 hardware protection. | `string` | `"standard"` | no |
| <a name="input_soft_delete_retention_days"></a> [soft\_delete\_retention\_days](#input\_soft\_delete\_retention\_days) | Days a deleted vault is recoverable, 7-90. Also the period its name stays reserved. Short in dev so a rebuild is not blocked; long in production so an accidental deletion is recoverable. | `number` | `7` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Entra ID tenant the vault belongs to, from data.azurerm\_client\_config. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_granted_principal_ids"></a> [granted\_principal\_ids](#output\_granted\_principal\_ids) | Principal IDs holding a role on this vault, with the role granted. A single artefact for reviewing who can read the secrets. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the vault. Role assignment scopes and diagnostic settings target this. |
| <a name="output_name"></a> [name](#output\_name) | Vault name. |
| <a name="output_private_endpoint_id"></a> [private\_endpoint\_id](#output\_private\_endpoint\_id) | Private endpoint resource ID, or null when none was created. |
| <a name="output_private_endpoint_ip"></a> [private\_endpoint\_ip](#output\_private\_endpoint\_ip) | Private IP the vault resolves to from inside the VNet. Useful for confirming DNS is actually resolving to the endpoint rather than to the public address. |
| <a name="output_public_access_is_firewalled"></a> [public\_access\_is\_firewalled](#output\_public\_access\_is\_firewalled) | True when a public endpoint exists but denies by default, so only the configured IP and subnet rules reach it. False when there is no public endpoint, or when it is open. |
| <a name="output_public_endpoint_locked_shut"></a> [public\_endpoint\_locked\_shut](#output\_public\_endpoint\_locked\_shut) | True when a public endpoint exists, denies by default, and has no rules at all — so nothing reaches it. Legitimate when a private endpoint carries all traffic, but usually means the allowlist was forgotten. |
| <a name="output_public_network_access_enabled"></a> [public\_network\_access\_enabled](#output\_public\_network\_access\_enabled) | Whether a public endpoint exists at all. |
| <a name="output_purge_protection_enabled"></a> [purge\_protection\_enabled](#output\_purge\_protection\_enabled) | Whether purge protection is on. IRREVERSIBLE once enabled: Azure provides no way to switch it off, and the vault NAME stays reserved for the full retention period after deletion — so a deterministic-name environment cannot be rebuilt until it expires. |
| <a name="output_reachable_from"></a> [reachable\_from](#output\_reachable\_from) | Human-readable summary of who can reach the data plane. The most common Key Vault support question, answered without reading the configuration. |
| <a name="output_role_assignment_ids"></a> [role\_assignment\_ids](#output\_role\_assignment\_ids) | Map of assignment key to role assignment ID, all scoped to this vault. |
| <a name="output_soft_delete_retention_days"></a> [soft\_delete\_retention\_days](#output\_soft\_delete\_retention\_days) | Days a deleted vault stays recoverable, and its name reserved. |
| <a name="output_tenant_id"></a> [tenant\_id](#output\_tenant\_id) | Tenant the vault belongs to. |
| <a name="output_vault_uri"></a> [vault\_uri](#output\_vault\_uri) | Data-plane URI, e.g. https://kv-cloudcart-dev-a1b2.vault.azure.net/. Applications use this unchanged whether they reach it publicly or through the private endpoint — the private DNS zone makes the same hostname resolve privately from inside the VNet. |
<!-- END_TF_DOCS -->
