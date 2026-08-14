# bootstrap — Phase 0

Creates the Azure Storage backend that every environment's state lives in.

**This configuration uses local state, deliberately.** The backend cannot live
in the state it stores.

---

## Why local state here

Making the bootstrap self-hosting means the account holding all state is
described by a state file inside itself. Lose the account and you lose the
ability to describe it; corrupt that one file and the recovery path runs
through the thing that is broken.

It is acceptable here for a specific reason, not as a general exception: these
resources are **re-derivable**. The account name is an input, the containers
are empty scaffolding, and nothing in this configuration holds data that cannot
be recreated. Its state file being lost is an inconvenience — `terraform
import` reconstructs it, and the commands are below.

`*.tfstate` is gitignored at the repository root, so the local state is never
committed.

---

## Adopted — imported and applied on 2026-08-14

This configuration was written **after** the backend was created by hand, so it
was adopted with `import` rather than `apply` — an apply against an empty state
would have failed on the storage account name already being taken.

It is no longer aspirational: the backend is now under Terraform management and
`terraform plan` is clean. The commands below are kept as the recovery path,
since the local state file is gitignored and losing it means doing this again.

```bash
cd bootstrap

terraform init
export SUB=$(az account show --query id -o tsv)

# The account name is NOT committed — it is a public DNS label, so it lives in
# the gitignored terraform.tfvars rather than in a default. Terraform loads
# that file automatically; a fresh clone without it fails with "No value for
# required variable". See terraform.tfvars.example.
export ACCOUNT=$(terraform console <<< "var.storage_account_name" | tr -d '"')

terraform import -var="subscription_id=$SUB" \
  azurerm_resource_group.tfstate \
  "/subscriptions/$SUB/resourceGroups/REDACTED-STATE-RG"

terraform import -var="subscription_id=$SUB" \
  azurerm_storage_account.tfstate \
  "/subscriptions/$SUB/resourceGroups/REDACTED-STATE-RG/providers/Microsoft.Storage/storageAccounts/$ACCOUNT"

# qa and stage did not exist and were CREATED by the apply, not imported.
for env in dev prod; do
  terraform import -var="subscription_id=$SUB" \
    "azurerm_storage_container.tfstate[\"$env\"]" \
    "https://$ACCOUNT.blob.core.windows.net/tfstate-$env"
done

terraform plan -var="subscription_id=$SUB"
```

The container import ID is the **data-plane URL**, not an ARM resource ID, even
though the resource is configured with `storage_account_id`. Verified working.

### `storage_use_azuread = true` is required, and the error does not say so

The storage account import fails without it:

```
Error: retrieving queue properties for Storage Account (...): 403
Key based authentication is not permitted on this storage account.
```

This is a direct consequence of `shared_access_key_enabled = false`. Reading a
storage account touches the **data plane** — the provider fetches queue and
share properties during an ordinary refresh — and it does so with a shared key
unless the provider is told otherwise. With keys disabled the account becomes
unreadable, and `import`, `plan` and `refresh` all fail the same way.

The message names the *queue* endpoint, which is doubly misleading: nothing in
this configuration uses queues, and the cause is authentication rather than
queues. `storage_use_azuread = true` in the provider block switches the data
plane to Entra ID. The caller then needs a **data-plane role** — Storage Blob
Data Contributor or Owner — because control-plane Owner alone does not grant it.

The environment root modules have set this flag all along; `dev`'s own storage
account has had shared keys disabled since it was built. Only `bootstrap` was
missing it, for the same reason it had no state: **it had never been run.** This
is the concrete cost of configuration that exists but has never executed, and
it surfaced the moment the state account stopped accepting keys.

### What the first apply changed

`2 to add, 4 to change, 0 to destroy`:

| Resource | Change |
|---|---|
| Resource group | `managedBy: Manual` → `Terraform` — now true |
| Storage account | no tags → the three standard tags |
| Containers `dev`, `prod` | `storage_account_name` → `storage_account_id` |
| Containers `qa`, `stage` | **created** — they did not exist |

The container change is the provider moving off `storage_account_name`, one of
the deprecated arguments this repository tracks. It is an in-place **update**;
had it been ForceNew it would have destroyed the container holding dev's live
state. Worth confirming on the plan rather than assuming, which is why the
counts are recorded here.

`tfstate-test` still exists, is empty, and is a leftover from before the `test`
→ `qa` rename. It is deliberately **not** in `var.environments`, so Terraform
does not manage it and will not delete it. Removing it is a manual decision.

---

## Two settings that were weaker than the documentation claimed — both now closed

`docs/DEPLOYMENT.md` §2 Phase 0 described the account as having
`shared_access_key_enabled = false` when it did not. Both gaps were closed on
the live account on **2026-08-14**, and the defaults here now match reality
rather than trailing it.

### `shared_access_key_enabled` — now `false`

Shared keys are static, non-expiring, unscopable, attributable to no one, and
grant total control of every environment's state. Every `backend.conf` here
already sets `use_azuread_auth = true`, so nothing needed them.

The exposure was confirmed to be real before it was closed: an 88-character key
listed straight from the account authenticated to the blob endpoint and
enumerated every state container, bypassing RBAC. Afterwards:

```console
$ az storage container list --account-name <acct> --account-key "$KEY"
ERROR: Key based authentication is not permitted on this storage account.

$ az storage container list --account-name <acct> --auth-mode login
tfstate-dev  tfstate-prod  tfstate-test
```

`terraform plan` against dev then read all 147 resources, took the state lock
and released it — so the Entra path covers reads, writes and locking, not just
reads.

**If you re-enable this, do it knowingly.** The reverse change is
`--allow-shared-key-access true`, and it reopens a path around RBAC.

### `blob_soft_delete_retention_days` — now `30`

Versioning was already enabled and protects against a state file being
**overwritten** or truncated. It does **not** protect against one being
**deleted** — a different failure, and the more final of the two.

Container soft delete is set to the same window and is a separate policy.
Deleting the *container* takes every blob inside it regardless of the blob
policy, so enabling only the blob one leaves the larger hole open. The
configuration sets both from this single variable.

### Both settings survived adoption unchanged

Both changes were originally made with `az` against the live account, before
this configuration was imported. The defaults here were set to match, and the
import on 2026-08-14 **confirmed it**: the first plan showed no diff on either
setting, which is the evidence that code and reality agree rather than an
assertion that they do.

A future diff on either means the live account has drifted, not this file.

`state_protection_summary` reports both states in plain language rather than
leaving them to be inferred from the configuration.

---

## Adding an environment

One word:

```hcl
environments = ["dev", "qa", "stage", "prod", "sandbox"]
```

Then `apply`, and take that environment's `backend.conf` from the
`backend_config` output — which emits the file contents ready to write, so the
account and container names are never transcribed by hand.

---

## What this does NOT create

Phase 0 in `docs/DEPLOYMENT.md` also lists a deployment identity and its role
assignments. Those are **not** here, deliberately: a service principal and its
subscription-level RBAC are an identity decision with a different blast radius
and a different approver than a storage account. Creating them silently
alongside a container would be the wrong default.
