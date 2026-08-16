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
| [azurerm_application_gateway.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_public_ip.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_web_application_firewall_policy.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/web_application_firewall_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_backend_http_settings"></a> [backend\_http\_settings](#input\_backend\_http\_settings) | Map of settings name to configuration. `probe_name` binds a health probe; without one the gateway uses a default probe against "/", which returns 404 on most applications and marks every backend unhealthy. | <pre>map(object({<br/>    port                                = number<br/>    protocol                            = optional(string, "Https")<br/>    cookie_based_affinity               = optional(string, "Disabled")<br/>    request_timeout                     = optional(number, 30)<br/>    probe_name                          = optional(string)<br/>    host_name                           = optional(string)<br/>    pick_host_name_from_backend_address = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_backend_pools"></a> [backend\_pools](#input\_backend\_pools) | Map of pool name to { fqdns, ip\_addresses }. Leave both empty for a pool a scale set attaches itself to. | <pre>map(object({<br/>    fqdns        = optional(list(string), [])<br/>    ip_addresses = optional(list(string), [])<br/>  }))</pre> | <pre>{<br/>  "default": {}<br/>}</pre> | no |
| <a name="input_http2_enabled"></a> [http2\_enabled](#input\_http2\_enabled) | Enable HTTP/2 for client connections. Note the gateway always speaks HTTP/1.1 to the backend regardless. | `bool` | `true` | no |
| <a name="input_listeners"></a> [listeners](#input\_listeners) | Map of listener name to { port, protocol, host\_name, ssl\_certificate\_name }. An HTTPS listener requires a certificate. | <pre>map(object({<br/>    port                 = number<br/>    protocol             = optional(string, "Https")<br/>    host_name            = optional(string)<br/>    ssl_certificate_name = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_max_capacity"></a> [max\_capacity](#input\_max\_capacity) | Maximum autoscale capacity units. This is the ceiling on ingress throughput — a gateway at max capacity queues and then sheds traffic while the backend sits idle, which reads as an application problem. | `number` | `10` | no |
| <a name="input_min_capacity"></a> [min\_capacity](#input\_min\_capacity) | Minimum autoscale capacity units. Each unit handles roughly 10 Mbps of throughput and 50 connections per second. Zero is permitted but means a cold start on first request. | `number` | `2` | no |
| <a name="input_name"></a> [name](#input\_name) | Application Gateway name. | `string` | n/a | yes |
| <a name="input_probes"></a> [probes](#input\_probes) | Map of probe name to configuration. An Application Gateway probe checks the APPLICATION, unlike a layer 4 load balancer probe — `match_status_codes` is what makes it meaningful. | <pre>map(object({<br/>    protocol                                  = optional(string, "Https")<br/>    path                                      = string<br/>    interval                                  = optional(number, 30)<br/>    timeout                                   = optional(number, 30)<br/>    unhealthy_threshold                       = optional(number, 3)<br/>    host                                      = optional(string)<br/>    pick_host_name_from_backend_http_settings = optional(bool, true)<br/>    match_status_codes                        = optional(list(string), ["200-399"])<br/>  }))</pre> | `{}` | no |
| <a name="input_public_ip_name"></a> [public\_ip\_name](#input\_public\_ip\_name) | Name for the gateway's public IP. | `string` | n/a | yes |
| <a name="input_redirect_configurations"></a> [redirect\_configurations](#input\_redirect\_configurations) | Map of redirect name to { target\_listener\_name, redirect\_type }. The usual use is forcing HTTP to HTTPS, which is a routing rule rather than a setting. | <pre>map(object({<br/>    target_listener_name = string<br/>    redirect_type        = optional(string, "Permanent")<br/>    include_path         = optional(bool, true)<br/>    include_query_string = optional(bool, true)<br/>  }))</pre> | `{}` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "app" lifecycle scope. | `string` | n/a | yes |
| <a name="input_routing_rules"></a> [routing\_rules](#input\_routing\_rules) | Map of rule name to configuration. Each binds a listener to either a backend (pool plus settings) or a redirect. Priority is required on v2 SKUs and must be unique. | <pre>map(object({<br/>    priority                    = number<br/>    listener_name               = string<br/>    backend_pool_name           = optional(string)<br/>    backend_http_settings_name  = optional(string)<br/>    redirect_configuration_name = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | "Standard\_v2" or "WAF\_v2". Only v2 SKUs are offered: v1 is retired, and only v2 supports autoscaling, zone redundancy and Key Vault certificate references. | `string` | `"WAF_v2"` | no |
| <a name="input_ssl_certificate_key_vault_secret_id"></a> [ssl\_certificate\_key\_vault\_secret\_id](#input\_ssl\_certificate\_key\_vault\_secret\_id) | Key Vault secret ID of the TLS certificate. Referencing the vault rather than embedding a PFX means the certificate is never in Terraform state and rotation is a vault operation, not a redeploy. Requires user\_assigned\_identity\_id with Key Vault Secrets User on the vault. | `string` | `null` | no |
| <a name="input_ssl_policy_name"></a> [ssl\_policy\_name](#input\_ssl\_policy\_name) | Predefined SSL policy. AppGwSslPolicy20220101 requires TLS 1.2 minimum and a modern cipher set. The older policies permit TLS 1.0 and 1.1, which most compliance regimes reject. | `string` | `"AppGwSslPolicy20220101"` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Dedicated Application Gateway subnet.<br/><br/>Two constraints that are not negotiable:<br/><br/>  - The subnet must contain NOTHING else. Azure rejects a gateway in a<br/>    subnet holding other resource types.<br/>  - Its NSG must allow inbound GatewayManager on 65200-65535. Without it<br/>    the gateway provisions and then reports permanently unhealthy, and the<br/>    error names the gateway rather than the missing rule.<br/><br/>A 0.0.0.0/0 route to a firewall on this subnet also breaks it — AppGW v2<br/>requires direct control-plane access. The route-table module rejects that<br/>combination. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_user_assigned_identity_id"></a> [user\_assigned\_identity\_id](#input\_user\_assigned\_identity\_id) | User-assigned identity the gateway uses to read its certificate from Key Vault. Required whenever ssl\_certificate\_key\_vault\_secret\_id is set. | `string` | `null` | no |
| <a name="input_waf_exclusions"></a> [waf\_exclusions](#input\_waf\_exclusions) | Rule exclusions, each { match\_variable, selector\_match\_operator, selector }. Every exclusion is a hole in the WAF — record why in the configuration, and prefer disabling one rule ID over excluding a whole variable. | <pre>list(object({<br/>    match_variable          = string<br/>    selector_match_operator = string<br/>    selector                = string<br/>  }))</pre> | `[]` | no |
| <a name="input_waf_file_upload_limit_mb"></a> [waf\_file\_upload\_limit\_mb](#input\_waf\_file\_upload\_limit\_mb) | Maximum file upload size in MB. | `number` | `100` | no |
| <a name="input_waf_max_request_body_size_kb"></a> [waf\_max\_request\_body\_size\_kb](#input\_waf\_max\_request\_body\_size\_kb) | Maximum request body the WAF will inspect, in KB. Bodies larger than this are passed through UNINSPECTED unless blocked outright, so raising it widens coverage and raising it too far costs latency. | `number` | `128` | no |
| <a name="input_waf_mode"></a> [waf\_mode](#input\_waf\_mode) | "Detection" logs what would have been blocked; "Prevention" blocks it. Run Detection first in a lower environment and tune the exclusions — going straight to Prevention blocks legitimate traffic and teaches the team to distrust the WAF. | `string` | `"Prevention"` | no |
| <a name="input_waf_request_body_check_enabled"></a> [waf\_request\_body\_check\_enabled](#input\_waf\_request\_body\_check\_enabled) | Inspect request bodies. Disabling it makes the WAF blind to anything in a POST body, which is where injection payloads usually are. | `bool` | `true` | no |
| <a name="input_waf_rule_set_type"></a> [waf\_rule\_set\_type](#input\_waf\_rule\_set\_type) | "OWASP" is the classic CRS. "Microsoft\_DefaultRuleSet" is Microsoft's managed set, which includes the OWASP rules plus Microsoft threat intelligence. | `string` | `"OWASP"` | no |
| <a name="input_waf_rule_set_version"></a> [waf\_rule\_set\_version](#input\_waf\_rule\_set\_version) | Rule set version. OWASP 3.2 is the current CRS; Microsoft\_DefaultRuleSet uses 2.1. | `string` | `"3.2"` | no |
| <a name="input_zones"></a> [zones](#input\_zones) | Availability zones. Empty means the gateway is regional and a zone outage takes ingress with it. v2 SKUs support zones at no extra charge, so an empty list in production is almost always an oversight. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backend_pool_ids"></a> [backend\_pool\_ids](#output\_backend\_pool\_ids) | Map of pool name to ID. Pass the relevant ID to the vm module's scale set network configuration. |
| <a name="output_capacity_range"></a> [capacity\_range](#output\_capacity\_range) | Autoscale bounds. max\_capacity is the ceiling on ingress throughput — a gateway at maximum queues and then sheds traffic while the backend sits idle, which reads as an application problem. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the gateway. Diagnostic settings target this. |
| <a name="output_is_zone_redundant"></a> [is\_zone\_redundant](#output\_is\_zone\_redundant) | Whether the gateway spans availability zones. False means a zone outage takes ingress with it — and since v2 supports zones at no extra charge, false in production is almost always an oversight. |
| <a name="output_name"></a> [name](#output\_name) | Gateway name. |
| <a name="output_public_ip_address"></a> [public\_ip\_address](#output\_public\_ip\_address) | Public ingress address. This is the address a DNS record should point at. |
| <a name="output_public_ip_id"></a> [public\_ip\_id](#output\_public\_ip\_id) | Public IP resource ID. |
| <a name="output_settings_without_probe"></a> [settings\_without\_probe](#output\_settings\_without\_probe) | Backend HTTP settings with no explicit probe. These fall back to Azure's default probe against "/", which returns 404 on most applications and marks every backend unhealthy while the application is fine. |
| <a name="output_uses_key_vault_certificate"></a> [uses\_key\_vault\_certificate](#output\_uses\_key\_vault\_certificate) | Whether TLS is served from a Key Vault-referenced certificate. True means the certificate is never in Terraform state and rotation is a vault operation rather than a redeploy. |
| <a name="output_waf_exclusion_count"></a> [waf\_exclusion\_count](#output\_waf\_exclusion\_count) | Number of WAF rule exclusions in force. Every exclusion is a hole; a growing count is worth reviewing, because exclusions are added under incident pressure and rarely removed afterwards. |
| <a name="output_waf_mode"></a> [waf\_mode](#output\_waf\_mode) | "Detection" logs what would have been blocked; "Prevention" blocks it. Detection is a tuning mode, not a security posture — a gateway left in Detection is a WAF that has never blocked anything. |
| <a name="output_waf_policy_id"></a> [waf\_policy\_id](#output\_waf\_policy\_id) | WAF policy resource ID, or null on the Standard\_v2 SKU. |
<!-- END_TF_DOCS -->
