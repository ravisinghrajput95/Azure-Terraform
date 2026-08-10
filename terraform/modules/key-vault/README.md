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
