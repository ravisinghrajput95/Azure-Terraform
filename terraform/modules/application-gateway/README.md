# Module: `application-gateway`

Application Gateway v2 with a standalone WAF policy, autoscaling, zone
support, and a TLS certificate referenced from Key Vault.

---

## Verification status

**This module has not been applied to Azure.** dev deploys a public load
balancer instead, because Application Gateway has no inexpensive tier
(~$260/month minimum against ~$18). Only `test` and `prod` exercise it.

What *is* proven: 16 tests using `mock_provider`, which run with no
credentials and exercise every cross-reference check and precondition. They
prove the module's **logic** — that each guard fires on the input it is meant
to catch. They do not prove Azure accepts the resulting API call. That
distinction matters and is not glossed over here.

---

## Blocks are wired together by name

An Application Gateway is unusual in Terraform: it is one resource containing
ten interdependent block types that reference each other by **string name**, not
by reference. A routing rule names a listener; a listener names a frontend
port; backend settings name a probe. Nothing checks those names until Azure
does, and Azure's error names an internal identifier rather than the mistake.

So the module derives the fixed names once and rejects every dangling
reference at plan time:

| Precondition | Catches |
|---|---|
| Rule → listener | Rule pointing at a listener that does not exist |
| Rule → backend pool | Same for pools |
| Rule → HTTP settings | Same for settings |
| Settings → probe | Same for probes |
| Redirect → listener | Same for redirect targets |
| Rule shape | A rule setting both a backend *and* a redirect, or neither |
| Priority uniqueness | Duplicate priorities, which v2 rejects |
| HTTPS listener → certificate | An HTTPS listener with no certificate |
| Certificate → identity | A Key Vault certificate with no identity to read it |
| Capacity bounds | `min_capacity` above `max_capacity` |
| WAF body inspection | A WAF that cannot see request bodies |

Frontend ports are **derived from the listeners** rather than declared
separately, so a listener can never reference a port that was not created.

---

## Three subnet constraints that are not negotiable

The gateway subnet must:

1. **Contain nothing else.** Azure rejects a gateway in a subnet holding other
   resource types.
2. **Allow inbound `GatewayManager` on 65200-65535.** Without it the gateway
   provisions and then reports permanently unhealthy — and the error names the
   gateway, not the missing NSG rule. This is the single most common WAF v2
   deployment failure.
3. **Carry no `0.0.0.0/0` route to a firewall.** AppGW v2 requires direct
   control-plane access. The `route-table` module rejects that combination by
   precondition.

---

## Usage

```hcl
module "application_gateway" {
  source = "../../modules/application-gateway"

  name                = module.naming.names.application_gateway
  resource_group_name = module.resource_group.names["app"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  subnet_id      = module.networking.subnet_ids["snet-agw-prod-cus"]
  public_ip_name = "pip-agw-cloudcart-prod-cus-001"

  sku_name     = module.profile.profile.application_gateway_sku
  waf_mode     = module.profile.profile.waf_mode
  zones        = module.profile.profile.application_gateway_zones
  min_capacity = module.profile.profile.application_gateway_min_capacity
  max_capacity = module.profile.profile.application_gateway_max_capacity

  ssl_certificate_key_vault_secret_id = azurerm_key_vault_certificate.tls.secret_id
  user_assigned_identity_id           = module.managed_identity.ids["app"]

  backend_pools = { app = {} }

  probes = {
    "app-health" = { path = "/healthz" }
  }

  backend_http_settings = {
    "app-https" = { port = 443, probe_name = "app-health" }
  }

  listeners = {
    "https" = { port = 443, protocol = "Https" }
    "http"  = { port = 80, protocol = "Http" }
  }

  redirect_configurations = {
    "to-https" = { target_listener_name = "https" }
  }

  routing_rules = {
    "https-to-app"  = { priority = 100, listener_name = "https", backend_pool_name = "app", backend_http_settings_name = "app-https" }
    "http-redirect" = { priority = 110, listener_name = "http", redirect_configuration_name = "to-https" }
  }
}
```

## Key inputs

| Name | Default | Description |
|---|---|---|
| `sku_name` | `"WAF_v2"` | v1 SKUs are retired and not offered. |
| `min_capacity` / `max_capacity` | `2` / `10` | Autoscale bounds. |
| `zones` | `[]` | Free on v2 — empty in prod is usually an oversight. |
| `ssl_certificate_key_vault_secret_id` | `null` | Never embed a PFX. |
| `user_assigned_identity_id` | `null` | Required with a certificate. |
| `ssl_policy_name` | `"AppGwSslPolicy20220101"` | TLS 1.2 minimum. |
| `waf_mode` | `"Prevention"` | |
| `waf_rule_set_type` / `_version` | `"OWASP"` / `"3.2"` | |
| `waf_request_body_check_enabled` | `true` | |
| `waf_exclusions` | `[]` | Each one is a hole. |
| `backend_pools`, `probes`, `backend_http_settings`, `listeners`, `routing_rules`, `redirect_configurations` | | See usage. |

## Outputs

`id`, `name`, `public_ip_address`, `public_ip_id`, `backend_pool_ids`,
`waf_policy_id`, `waf_mode`, `waf_exclusion_count`, `is_zone_redundant`,
`settings_without_probe`, `capacity_range`, `uses_key_vault_certificate`

---

## Design notes

**A standalone WAF policy, not the inline `waf_configuration` block.** The
inline form cannot be shared between gateways, cannot be applied per-listener,
and buries its exclusions inside the gateway resource where they are harder to
review.

**The certificate is referenced from Key Vault, never embedded.** A PFX in
configuration ends up in Terraform state, and rotating it becomes a redeploy
rather than a vault operation. The gateway needs a user-assigned identity with
`Key Vault Secrets User` to fetch it — a precondition rejects the certificate
without the identity, because otherwise provisioning fails several minutes in.

**Backend settings without a probe are reported, not blocked.** Azure falls
back to a default probe against `/`, which returns 404 on most applications and
marks every backend unhealthy while the application is fine.
`settings_without_probe` names them.

**`waf_exclusion_count` is an output** because exclusions are added under
incident pressure and rarely removed. A growing count is worth reviewing.

**`waf_mode = "Detection"` is a tuning mode, not a security posture.** A
gateway left in Detection is a WAF that has never blocked anything. The profile
uses Detection in test — where rules are tuned — and Prevention in prod.

**`enable_http2` is deprecated** in azurerm 4.x; this module uses
`http2_enabled`. Note the gateway always speaks HTTP/1.1 to the backend
regardless of the setting.

---

## Cost

| Component | Approximate |
|---|---|
| WAF_v2 fixed | ~$263/month |
| Standard_v2 fixed | ~$180/month |
| Capacity units | ~$6/month each, scaling with throughput |
| Standard public IP | ~$3.65/month |

`max_capacity` is the ceiling on ingress throughput. A gateway at maximum
queues and then sheds traffic while the backend sits idle — which reads as an
application problem and is not one.

---

## Tests

```bash
terraform init -backend=false
terraform test
```

16 tests, no credentials required. `mock_provider` makes them run with no Azure
access and create nothing.

---

## Reference

Generated by terraform-docs. The prose above is hand-written; everything
between the markers below is regenerated by CI and should not be edited by
hand.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
