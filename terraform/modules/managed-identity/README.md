# Module: `managed-identity`

User-assigned managed identities, one per compute tier, plus optional role
assignments.

Built in Phase 3 before Key Vault and Storage, because those modules' role
assignments reference these principal IDs.

---

## Two decisions that matter more than the code

### User-assigned, not system-assigned

A system-assigned identity is created and destroyed **with its resource**.
Every scale set replacement produces a **new principal ID**, which invalidates
every role assignment and Key Vault grant pointing at the old one.

So a routine instance refresh silently removes the application's access to its
own secrets. The scale set comes back healthy, the NSG is unchanged, and the
app fails to start with an authorisation error that has no obvious cause.

A user-assigned identity has a lifecycle independent of the compute that
assumes it. Permissions are granted once and survive replacement, and the same
identity can be shared by a scale set and the pipeline that deploys to it.

### One identity per tier, not one shared

Network isolation without identity isolation makes the NSG boundary
decorative. If the app and business tiers share an identity, anything that
reaches the app tier inherits the business tier's entire access footprint —
including its database credentials and its secrets.

The three-tier boundary has to exist at both layers or it exists at neither.

---

## Usage

```hcl
module "managed_identity" {
  source = "../../modules/managed-identity"

  resource_group_name = module.resource_group.names["sec"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  identities = module.naming.managed_identity_names
}
```

Consumed by a scale set:

```hcl
identity {
  type         = "UserAssigned"
  identity_ids = [module.managed_identity.ids["app"]]
}
```

Granted access by a resource owner:

```hcl
module "key_vault" {
  # the vault creates role assignments scoped to itself
  reader_principal_ids = values(module.managed_identity.principal_ids)
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | `string` | — | The `sec` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `identities` | `map(string)` | — | Tier key → identity name. |
| `role_assignments` | `map(object)` | `{}` | Prefer resource-owner grants. |
| `propagation_delay_seconds` | `number` | `30` | Entra ID consistency window. |

## Outputs

`ids`, `principal_ids`, `client_ids`, `names`, `tenant_id`, `identities`,
`role_assignment_ids`, `ready`, `propagation_delay_applied_seconds`

**`principal_id` vs `client_id`** — these are routinely confused. Role
assignments and Key Vault grants take the **principal (object) ID**.
Application code requesting a token for a specific identity presents the
**client (application) ID**, which is required when a VM has more than one
user-assigned identity and the token request must say which to use.

---

## Entra ID propagation

Azure role assignments and identity principals are **eventually consistent**,
and Azure exposes no API to wait on. A principal created at second zero is
frequently not resolvable when the next resource references it, producing
`PrincipalNotFound` — intermittently, so it reads as a flaky apply rather than
a consistency window.

This module addresses it two ways, and the distinction matters:

**For its own role assignments — `principal_type = "ServicePrincipal"`.**
Without it, Azure looks the principal up in Entra ID to determine its type, and
that lookup is exactly what fails for a freshly created principal. Declaring
the type skips the lookup entirely, so these assignments do not depend on
propagation at all. This is a fix, not a workaround.

(`skip_service_principal_aad_check` is the older answer to the same problem.
`principal_type` supersedes it and is preferable — it states a fact rather than
disabling a check.)

**For downstream data-plane consumers — a `time_sleep`.** Key Vault is the
common case: an RBAC grant must be *effective* before a secret can be read, and
there is no equivalent trick. This is a timer, not a fix. It cannot guarantee
readiness, only make the common case work. Depend on the `ready` output, or on
the module itself, to order after it.

Set `propagation_delay_seconds = 0` to disable, at the cost of intermittent
data-plane failures on first apply.

---

## Role assignment direction

`role_assignments` here is optional and usually empty. Most access in this
platform is granted by the **resource owner**: the `key-vault` and `storage`
modules take principal IDs and create assignments scoped to themselves.

That direction is deliberate. A grant scoped to the vault lives and dies with
the vault. A grant created here, scoped to a resource this module does not own,
would outlive its target and leave an orphaned assignment pointing at a deleted
scope — which accumulates silently and shows up years later in an access
review nobody can explain.

Use this input only for genuinely cross-cutting grants where the scope is a
subscription or resource group.

---

## Cost

User-assigned managed identities are **free**. There is no per-identity charge,
so creating one per tier costs nothing over sharing one.

---

## Deployed state

`dev` — applied and verified in Azure:

```
id-app-dev-eus-001   principal 7a5db8c4-…  client bc27773c-…
id-biz-dev-eus-001   principal 7dc87b08-…  client 9345f1f3-…
```

No role assignments yet — Key Vault and Storage grant themselves in modules 13
and 14.

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
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |
| <a name="provider_time"></a> [time](#provider\_time) | 0.14.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_role_assignment.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [time_sleep.propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_identities"></a> [identities](#input\_identities) | Map of tier key to identity name, e.g. { app = "id-app-dev-eus-001" }. The key is used to address the identity in outputs and in role\_assignments, so it must be stable — renaming a key destroys and recreates the identity, invalidating every role assignment that referenced its principal ID. | `map(string)` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_propagation_delay_seconds"></a> [propagation\_delay\_seconds](#input\_propagation\_delay\_seconds) | Seconds to wait after creating identities before dependent resources use<br/>them.<br/><br/>A newly created user-assigned identity's service principal takes time to<br/>become visible across Entra ID, and there is no API to poll for readiness.<br/>Until it propagates, operations referencing the principal fail with<br/>PrincipalNotFound — intermittently, which makes it look like a flaky apply<br/>rather than a consistency window.<br/><br/>Role assignments created by THIS module set principal\_type explicitly,<br/>which avoids the lookup entirely and needs no delay. This wait exists for<br/>downstream consumers that touch a data plane — Key Vault in particular,<br/>where the RBAC grant must be effective before a secret can be read.<br/><br/>Set to 0 to disable. 30 is usually enough; a first-ever identity in a<br/>tenant can take longer. | `number` | `30` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for the identities. Should be the "sec" lifecycle scope — identities are security-team owned and outlive the compute that assumes them. | `string` | n/a | yes |
| <a name="input_role_assignments"></a> [role\_assignments](#input\_role\_assignments) | Map of assignment key to { identity\_key, scope, role\_definition\_name or role\_definition\_id, description, condition }. Prefer having the resource owner grant access to itself; use this for subscription or resource-group scoped roles. | <pre>map(object({<br/>    identity_key         = string<br/>    scope                = string<br/>    role_definition_name = optional(string)<br/>    role_definition_id   = optional(string)<br/>    description          = optional(string)<br/>    condition            = optional(string)<br/>    condition_version    = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_client_ids"></a> [client\_ids](#output\_client\_ids) | Map of tier key to client (application) ID. This is what application code presents when requesting a token for a specific user-assigned identity — a VM with more than one assigned identity must name which to use. |
| <a name="output_identities"></a> [identities](#output\_identities) | Full detail per tier: id, name, principal\_id, client\_id. For callers needing more than one field. |
| <a name="output_ids"></a> [ids](#output\_ids) | Map of tier key to identity ARM resource ID. This is what a scale set's identity block references. |
| <a name="output_names"></a> [names](#output\_names) | Map of tier key to identity name. |
| <a name="output_principal_ids"></a> [principal\_ids](#output\_principal\_ids) | Map of tier key to principal (object) ID. This is what role assignments and Key Vault RBAC grants reference — NOT the client ID. |
| <a name="output_propagation_delay_applied_seconds"></a> [propagation\_delay\_applied\_seconds](#output\_propagation\_delay\_applied\_seconds) | Seconds actually waited after identity creation. Zero means no wait was applied, and a downstream data-plane operation may hit PrincipalNotFound intermittently. |
| <a name="output_ready"></a> [ready](#output\_ready) | Identifier of the propagation wait, or null when the wait is disabled. Depend on this to order downstream data-plane use after the Entra ID propagation window. |
| <a name="output_role_assignment_ids"></a> [role\_assignment\_ids](#output\_role\_assignment\_ids) | Map of assignment key to role assignment ID. Empty by default — most access in this platform is granted by the resource owner, scoped to itself, so the grant dies with the resource rather than outliving it. |
| <a name="output_tenant_id"></a> [tenant\_id](#output\_tenant\_id) | Tenant the identities belong to. one() over the distinct set doubles as an assertion that every identity shares one tenant — if that were ever untrue, the plan fails rather than silently returning whichever came first. |
<!-- END_TF_DOCS -->
