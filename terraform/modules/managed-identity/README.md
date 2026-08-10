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
