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

## The resources already exist

This configuration was written **after** the backend was created by hand. It
describes what is already deployed, so adopt it with `import` rather than
`apply` — an apply against an empty state would fail on the storage account
name already being taken.

```bash
cd bootstrap

terraform init
export SUB=$(az account show --query id -o tsv)

terraform import -var="subscription_id=$SUB" \
  azurerm_resource_group.tfstate \
  "/subscriptions/$SUB/resourceGroups/REDACTED-STATE-RG"

terraform import -var="subscription_id=$SUB" \
  azurerm_storage_account.tfstate \
  "/subscriptions/$SUB/resourceGroups/REDACTED-STATE-RG/providers/Microsoft.Storage/storageAccounts/REDACTED-STATE-ACCOUNT"

for env in dev qa stage prod; do
  terraform import -var="subscription_id=$SUB" \
    "azurerm_storage_container.tfstate[\"$env\"]" \
    "https://REDACTED-STATE-ACCOUNT.blob.core.windows.net/tfstate-$env"
done

terraform plan -var="subscription_id=$SUB"
```

The defaults are set to match the account's **current live state**, so the plan
after import should be close to empty. Where it is not, that is a real
discrepancy — see below.

Containers `tfstate-qa` and `tfstate-stage` do not exist yet; their imports
will fail until an apply creates them. `tfstate-test` exists and is an empty
leftover from before the environment rename.

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

### Applying this configuration will not re-do the work

Both changes were made with `az` against the live account, because `bootstrap`
has still never been applied or imported (see above). The defaults here were
updated to match, so an eventual import and apply should show **no diff** on
these two settings. If it shows one, the live account has drifted, not this
file.

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
