# Module: `redis`

**Azure Managed Redis** (`Microsoft.Cache/redisEnterprise`) with access keys
disabled, TLS-only transport, no public endpoint, and a private endpoint.

---

## Classic Azure Cache for Redis is retiring

This module originally targeted `azurerm_redis_cache`. That resource can no
longer create instances — the Azure API rejects it outright:

```
BadRequest: Azure Cache for Redis is retiring, create Azure Managed Redis
instance instead. https://aka.ms/AzureCacheForRedisRetirement
```

So the classic Basic / Standard / Premium tiers and their `C` and `P` families
are simply unavailable for new deployments. Azure Managed Redis is the
replacement, and three differences matter more than the resource rename:

| | Classic | Managed Redis |
|---|---|---|
| SKU naming | `Basic` + family `C`, capacity `0` | `Balanced_B0` |
| Private DNS zone | `privatelink.redis.cache.windows.net` | **`privatelink.redis.azure.net`** |
| Default port | 6380 | **10000** |
| Private endpoint subresource | `redisCache` | **`redisEnterprise`** |

The DNS zone is the dangerous one. Supplying the classic zone to a Managed
Redis private endpoint registers no usable record, so the hostname resolves to
its **public** address from inside the VNet — no error, at any layer. A
precondition names this specifically.

The port catches people out too: a client configured for 6380 simply will not
connect.

**Managed Redis is slightly cheaper at the small end** — `Balanced_B0` is
roughly $13/month against ~$16 for the classic Basic C0 it supersedes.

---

## Availability is `high_availability_enabled`, not the tier

Unlike classic Redis, where availability was tied to Basic/Standard/Premium,
Managed Redis exposes it as a flag on every SKU.

`high_availability_enabled = true` replicates across nodes and is what carries
the SLA. Setting it false roughly halves the cost and **removes the SLA
entirely** — a host fault or a routine platform restart loses the whole cache,
with nothing to fail over to.

The `availability_summary` output states this in plain language rather than
leaving it implicit:

```
Balanced_B0 with high availability DISABLED: single node, NO SLA. A host
fault or restart loses the entire cache with nothing to fail over to.
Suitable only where the cache is a pure accelerator and a cold start is
survivable.
```

dev runs with HA off as a deliberate cost decision. test and prod enable it,
and a production guardrail in the `profile` module rejects turning it off.

`FlashOptimized` always replicates; HA cannot be disabled on it, and a
precondition catches the attempt.

---

## Access keys disabled

Managed Redis access keys have the same weaknesses as storage account keys:
static, never expiring, impossible to scope, and total control of the cache.

`access_keys_authentication_enabled = false` is the default. Clients
authenticate with a managed identity through an **access policy assignment**,
which is the Managed Redis equivalent of a data-plane role assignment.

Two consequences:

- With keys off, a principal **without** an assignment cannot connect at all. A
  cache with no assignments is created successfully and is unreachable by
  everything — a precondition rejects that combination.
- Any library or sidecar still passing a key stops working the moment keys are
  disabled. This is a client-side change, not only an infrastructure one.

The assignment resource takes only the cache and the principal — there is no
per-assignment name and no policy selector, so it grants the built-in full data
access policy and nothing narrower is expressible today.

Access keys are deliberately **not exported**, for the same reason as in the
`storage` module.

---

## Usage

```hcl
module "redis" {
  source = "../../modules/redis"
  count  = module.profile.enable_redis ? 1 : 0

  name                = module.naming.redis_name
  resource_group_name = module.resource_group.names["data"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku_name                  = module.profile.profile.redis_sku_name
  high_availability_enabled = module.profile.profile.redis_high_availability

  access_keys_authentication_enabled = false
  client_protocol                    = "Encrypted"
  public_network_access_enabled      = false

  access_policy_assignments = {
    for tier, principal_id in module.managed_identity.principal_ids :
    "tier-${tier}" => { principal_id = principal_id }
  }

  create_private_endpoint    = true
  private_endpoint_subnet_id = module.networking.subnet_ids["snet-pep-dev-cus"]
  private_endpoint_name      = "pep-redis-cloudcart-dev-cus-001"
  private_dns_zone_ids       = [module.private_dns.zone_ids_by_service["managed_redis"]]
}
```

## Key inputs

| Name | Default | Description |
|---|---|---|
| `sku_name` | `"Balanced_B0"` | `<Family>_<Size>` — Balanced, MemoryOptimized, ComputeOptimized, FlashOptimized. |
| `high_availability_enabled` | `true` | Carries the SLA. |
| `access_keys_authentication_enabled` | `false` | |
| `access_policy_assignments` | `{}` | Required when keys are off. |
| `client_protocol` | `"Encrypted"` | Never Plaintext. |
| `clustering_policy` | `"EnterpriseCluster"` | Changes the client contract. |
| `eviction_policy` | `"VolatileLRU"` | See below. |
| `port` | `null` | Azure default is **10000**, not 6380. |
| `public_network_access_enabled` | `false` | No IP allowlist exists — blunt on/off. |
| `create_private_endpoint` | `true` | Static bool. |
| `private_dns_zone_ids` | `[]` | Must be the **managed_redis** zone. |

## Outputs

`id`, `name`, `hostname`, `sku_name`, `connection_guidance`,
`high_availability_enabled`, `availability_summary`, `access_keys_enabled`,
`access_policy_assignment_ids`, `reachable_from`, `private_endpoint_id`,
`private_endpoint_ip`

---

## Design notes

**`eviction_policy` defaults to `VolatileLRU`.** It evicts only keys carrying a
TTL, which is safe when the cache also holds keys that must not vanish.
`AllKeysLRU` may evict anything; `NoEviction` makes writes fail instead of
evicting, correct only when the cache is a store rather than a cache.

**`clustering_policy` is not a transparent choice.** `OSSCluster` exposes the
standard Redis Cluster API and requires a cluster-aware client.
`EnterpriseCluster` presents a single endpoint and hides sharding, which is
simpler for clients that are not cluster-aware. This changes the client
contract, so it is not a capacity dial.

**`public_network_access` is a string enum**, not a boolean — unlike almost
every other resource in this platform. The module takes a bool and converts.

**Managed Redis has no IP allowlist.** Unlike Key Vault and Storage, public
access is all-or-nothing: either the internet can reach the endpoint or only
the private endpoint can. dev therefore disables it entirely, since nothing in
this platform needs to reach the cache from an operator machine — there are no
secrets to manage and no containers to create.

---

## Cost

| SKU | Approximate (Central US list) |
|---|---|
| `Balanced_B0` | ~$13/month |
| `Balanced_B1` | ~$26/month |
| `Balanced_B3` | ~$53/month |
| `MemoryOptimized_M10` | ~$130/month |
| Private endpoint | ~$7.30/month |

High availability roughly doubles the node count and therefore the rate.

There is no free tier. On a credit-limited subscription, Redis remains the
first component worth disabling — `enable_redis = false` in the profile removes
it entirely.

---

## Deployed state

`dev` — `Balanced_B0`, high availability off, TLS required, access keys
disabled with Entra access policy assignments for the app and biz tiers, no
public endpoint, private endpoint in `snet-pep-dev-cus`.

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

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.81.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_managed_redis.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/managed_redis) | resource |
| [azurerm_managed_redis_access_policy_assignment.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/managed_redis_access_policy_assignment) | resource |
| [azurerm_private_endpoint.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_keys_authentication_enabled"></a> [access\_keys\_authentication\_enabled](#input\_access\_keys\_authentication\_enabled) | Whether the static access keys may be used. FALSE is the stronger posture — clients then authenticate with a managed identity through a Redis access policy assignment. Any library or sidecar still passing a key stops working the moment this is disabled, so it is a client-side change too. | `bool` | `false` | no |
| <a name="input_access_policy_assignments"></a> [access\_policy\_assignments](#input\_access\_policy\_assignments) | Map of assignment key to { principal\_id }. The map key is for addressing in Terraform only — Azure does not name these. Each assignment grants the built-in full data access policy; the resource exposes no policy selector, so nothing narrower is expressible today. With access keys disabled, a principal without an assignment cannot connect at all. | <pre>map(object({<br/>    principal_id = string<br/>  }))</pre> | `{}` | no |
| <a name="input_client_protocol"></a> [client\_protocol](#input\_client\_protocol) | "Encrypted" requires TLS; "Plaintext" does not. Always Encrypted — the plaintext protocol carries the access key and every cached value in clear text. | `string` | `"Encrypted"` | no |
| <a name="input_clustering_policy"></a> [clustering\_policy](#input\_clustering\_policy) | "OSSCluster" exposes the standard Redis Cluster API and requires a cluster-aware client. "EnterpriseCluster" presents a single endpoint and hides sharding, which is simpler for clients that are not cluster-aware. This changes the client contract, so it is not a transparent choice. | `string` | `"EnterpriseCluster"` | no |
| <a name="input_create_private_endpoint"></a> [create\_private\_endpoint](#input\_create\_private\_endpoint) | Whether to create a private endpoint. A STATIC boolean, so count resolves at plan time from an empty state. | `bool` | `true` | no |
| <a name="input_eviction_policy"></a> [eviction\_policy](#input\_eviction\_policy) | Behaviour when the cache is full. "VolatileLRU" evicts only keys carrying a TTL, which is safe when the cache also holds keys that must not vanish. "AllKeysLRU" may evict anything. "NoEviction" makes writes fail instead of evicting — correct only when the cache is a store rather than a cache. | `string` | `"VolatileLRU"` | no |
| <a name="input_high_availability_enabled"></a> [high\_availability\_enabled](#input\_high\_availability\_enabled) | Replicate across nodes. TRUE is the default and carries the SLA. Setting false roughly halves the cost and removes the SLA — a host fault loses the entire cache with nothing to fail over to. Acceptable only where the cache is a pure accelerator and a cold start is survivable. | `bool` | `true` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Cache name, from naming.redis\_name. Globally unique. | `string` | n/a | yes |
| <a name="input_port"></a> [port](#input\_port) | Data-plane port. Null uses the Azure default of 10000, which differs from classic Redis — clients configured for 6380 will not connect. | `number` | `null` | no |
| <a name="input_private_dns_zone_ids"></a> [private\_dns\_zone\_ids](#input\_private\_dns\_zone\_ids) | Private DNS zone IDs for privatelink.redis.azure.net. NOTE: Managed Redis uses a DIFFERENT zone from classic Azure Cache for Redis, which used privatelink.redis.cache.windows.net. Supplying the classic zone registers no usable record. | `list(string)` | `[]` | no |
| <a name="input_private_endpoint_name"></a> [private\_endpoint\_name](#input\_private\_endpoint\_name) | Name for the private endpoint. | `string` | `null` | no |
| <a name="input_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#input\_private\_endpoint\_subnet\_id) | Subnet for the private endpoint. | `string` | `null` | no |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether the cache keeps a public endpoint. Managed Redis has no IP allowlist, so this is a blunt on/off — either the internet can reach the endpoint or only the private endpoint can. | `bool` | `false` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "data" lifecycle scope. | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | Managed Redis SKU, e.g. "Balanced\_B0", "Balanced\_B1", "MemoryOptimized\_M10", "ComputeOptimized\_X3", "FlashOptimized\_A250". Pass the profile's redis\_sku\_name. | `string` | `"Balanced_B0"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_keys_enabled"></a> [access\_keys\_enabled](#output\_access\_keys\_enabled) | Whether the static access keys work. False is the intended state — clients authenticate with a managed identity through an access policy assignment. |
| <a name="output_access_policy_assignment_ids"></a> [access\_policy\_assignment\_ids](#output\_access\_policy\_assignment\_ids) | Map of assignment key to resource ID. With access keys disabled, this is the complete list of principals that can reach the data plane. |
| <a name="output_availability_summary"></a> [availability\_summary](#output\_availability\_summary) | Plain-language availability posture, so the limits of the deployed configuration are visible without knowing Managed Redis semantics. |
| <a name="output_connection_guidance"></a> [connection\_guidance](#output\_connection\_guidance) | How to connect. No password — access keys are disabled and clients present a managed identity bound to an access policy. |
| <a name="output_high_availability_enabled"></a> [high\_availability\_enabled](#output\_high\_availability\_enabled) | Whether the cache replicates across nodes. This is what carries the SLA. |
| <a name="output_hostname"></a> [hostname](#output\_hostname) | Cache hostname. Resolves to the private endpoint from inside the VNet. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the cache. Access policy assignments and diagnostic settings target this. |
| <a name="output_name"></a> [name](#output\_name) | Cache name. |
| <a name="output_private_endpoint_id"></a> [private\_endpoint\_id](#output\_private\_endpoint\_id) | Private endpoint resource ID, or null when none was created. |
| <a name="output_private_endpoint_ip"></a> [private\_endpoint\_ip](#output\_private\_endpoint\_ip) | Private IP the cache hostname resolves to inside the VNet. |
| <a name="output_reachable_from"></a> [reachable\_from](#output\_reachable\_from) | Who can reach the cache, in plain language. |
| <a name="output_sku_name"></a> [sku\_name](#output\_sku\_name) | SKU actually deployed. |
<!-- END_TF_DOCS -->
