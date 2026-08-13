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

## Two settings that are weaker than the documentation claimed

`docs/DEPLOYMENT.md` §2 Phase 0 described the account as having
`shared_access_key_enabled = false`. It does not. Both of these are defaulted
to the live values so that adopting this configuration changes nothing by
accident, and both are worth closing deliberately.

### `shared_access_key_enabled` — currently `true`

Shared keys are static, non-expiring, unscopable, and grant total control of
every environment's state. Every `backend.conf` here already sets
`use_azuread_auth = true`, so nothing needs them.

```bash
terraform apply -var="subscription_id=$SUB" -var="shared_access_key_enabled=false"
```

Before doing that, confirm nothing else authenticates with a key — a CI job, a
storage explorer session, a script. Disabling it breaks those immediately.

### `blob_soft_delete_retention_days` — currently `0`, i.e. disabled

Versioning is enabled and protects against a state file being **overwritten**
or truncated. It does **not** protect against one being **deleted** — a
different failure, and the more final of the two.

```bash
terraform apply -var="subscription_id=$SUB" -var="blob_soft_delete_retention_days=30"
```

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
