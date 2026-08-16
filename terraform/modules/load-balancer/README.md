# Module: `load-balancer`

Standard SKU load balancer, internal or public, with backend pools, health
probes and rules.

One module serves both roles because the resource shape is identical apart
from the frontend: an internal load balancer takes a subnet and a private
address, a public one takes a public IP.

---

## A public load balancer is not an Application Gateway

Worth stating plainly, because the two are often treated as interchangeable
ingress.

| | Public load balancer | Application Gateway |
|---|---|---|
| Layer | **4** (TCP/UDP) | 7 (HTTP) |
| TLS termination | ✗ | ✓ |
| WAF | ✗ | ✓ |
| Path/host routing | ✗ | ✓ |
| Cost | ~$18/month | ~$260/month minimum |

A load balancer **forwards packets**. It does not terminate TLS, inspect
requests, or filter anything. This platform uses one for dev ingress only
because Application Gateway has no inexpensive tier — test and prod use AppGW
precisely for what this cannot do, and the ingress NSG rule differs by
environment as a result.

---

## Standard SKU is closed by default

Beyond the Basic tier's retirement in September 2025, Standard differs in one
way that catches people out: **it permits no inbound traffic unless an NSG
allows it.** A Basic load balancer permitted traffic unless an NSG denied it.

That is why the tier NSGs must allow the `AzureLoadBalancer` service tag.
Without that rule every backend reports unhealthy, and the symptom looks like
an application fault rather than a network one — the load balancer is up, the
instances are running, and no traffic flows.

---

## Usage

```hcl
module "load_balancer_internal" {
  source = "../../modules/load-balancer"

  name                = module.naming.names.load_balancer_internal
  resource_group_name = module.resource_group.names["app"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  type      = "internal"
  subnet_id = module.networking.subnet_ids["snet-biz-dev-cus"]
  zones     = module.profile.profile.compute_zones

  backend_pools = ["biz"]

  probes = {
    "biz-health" = {
      protocol     = "Http"
      port         = 8443
      request_path = "/healthz"
    }
  }

  rules = {
    "biz-https" = {
      frontend_port     = 8443
      backend_port      = 8443
      backend_pool_name = "biz"
      probe_name        = "biz-health"
    }
  }
}
```

## Key inputs

| Name | Default | Description |
|---|---|---|
| `type` | — | `internal` or `public`. |
| `subnet_id` | `null` | Internal only. |
| `private_ip_address` | `null` | Null means dynamic. |
| `public_ip_name` | `null` | Public only. |
| `zones` | `[]` | Empty means zone-redundant on Standard. |
| `backend_pools` | `["default"]` | Created empty. |
| `probes` | `{}` | See below. |
| `rules` | `{}` | |
| `disable_outbound_snat` | `true` | See below. |

## Outputs

`id`, `name`, `type`, `frontend_ip_address`, `public_ip_id`,
`backend_pool_ids`, `probe_ids`, `tcp_only_probes`,
`probe_detection_seconds`, `unused_backend_pools`, `orphaned_probes`,
`outbound_snat_disabled`

---

## Probes decide what "healthy" means

**A TCP probe only checks that a port accepts connections.** A hung process
happily continues accepting them, so the probe reports healthy while every
request times out. Prefer `Http` or `Https` with a `request_path` wherever the
backend speaks HTTP. The `tcp_only_probes` output lists any that do not.

Validation enforces the pairing: a path is **required** for an HTTP probe and
**rejected** on a TCP one. Azure silently ignores a path on a TCP probe, which
makes the probe look like an application health check when it is not.

`probe_detection_seconds` reports `interval × threshold` — how long a dead
instance keeps receiving traffic. The default 5s × 2 is 10 seconds.

---

## Outbound SNAT is disabled

`disable_outbound_snat = true` on public rules, deliberately.

Egress in this platform is the NAT Gateway's job, and a NAT Gateway takes
precedence over load balancer SNAT anyway. Leaving LB SNAT enabled creates a
second, **undeclared** egress path that is invisible in the route table and
competes for a much smaller SNAT port allocation — the usual cause of
intermittent outbound connection failures that appear only under load.

---

## Backend pools are created empty

A scale set attaches **itself** to a pool by ID; the pool does not enumerate
its members. That is what allows instances to come and go during a rolling
upgrade without a Terraform change.

Two outputs cover the failure modes: `unused_backend_pools` (no rule sends
traffic there, so an attached scale set sits healthy and idle) and
`orphaned_probes` (nothing references it — usually a rename that missed one
side).

---

## Deprecated arguments

`enable_floating_ip` and `enable_tcp_reset` are deprecated in azurerm 4.x. This
module uses `floating_ip_enabled` and `tcp_reset_enabled`.

`tcp_reset_enabled` defaults **true**: without it an idle-timed-out flow is
dropped silently and the client blocks until its own timeout. With it the
client gets a RST and fails fast.

---

## Cost

| Component | Approximate |
|---|---|
| Standard load balancer | ~$18/month + $0.005/GB processed |
| Standard public IP | ~$3.65/month |

An internal load balancer has no public IP, so it is the base rate only.

---

## Deployed state

`dev`:

```
lbi-biz-dev-cus-001   internal  Standard  frontend 10.10.8.4   1 pool, 1 rule, 1 probe
lbe-cloudcart-dev-cus-001  public  Standard  frontend 172.212.155.43  1 pool, 1 rule, 1 probe
```

Both probes are HTTP against `/healthz` with a 10-second detection window.
Backend pools are empty until the `vm` module attaches the scale sets.

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
| [azurerm_lb.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/lb) | resource |
| [azurerm_lb_backend_address_pool.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/lb_backend_address_pool) | resource |
| [azurerm_lb_probe.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/lb_probe) | resource |
| [azurerm_lb_rule.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/lb_rule) | resource |
| [azurerm_public_ip.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_backend_pools"></a> [backend\_pools](#input\_backend\_pools) | Backend pool names. A scale set attaches itself to these by ID rather than the pool listing its members, so the pool is created empty and populated by the vm module. | `list(string)` | <pre>[<br/>  "default"<br/>]</pre> | no |
| <a name="input_disable_outbound_snat"></a> [disable\_outbound\_snat](#input\_disable\_outbound\_snat) | Whether load balancing rules perform outbound SNAT.<br/><br/>TRUE here, deliberately. This platform provides egress through a NAT<br/>Gateway attached to the subnet, and a NAT Gateway takes precedence over<br/>load balancer outbound SNAT anyway. Leaving LB SNAT enabled creates a<br/>second, undeclared egress path that is invisible in the route table and<br/>competes for a much smaller SNAT port allocation — the usual cause of<br/>intermittent outbound connection failures under load. | `bool` | `true` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Load balancer name. | `string` | n/a | yes |
| <a name="input_private_ip_address"></a> [private\_ip\_address](#input\_private\_ip\_address) | Static private address for an internal frontend. Null uses dynamic allocation, which is fine — the address is discovered through the private DNS zone or the output, not hardcoded by clients. | `string` | `null` | no |
| <a name="input_probes"></a> [probes](#input\_probes) | Map of probe name to configuration.<br/><br/>A probe is what decides whether an instance receives traffic. Two things<br/>are worth getting right:<br/><br/>  protocol      "Http" or "Https" with a request\_path checks the<br/>                APPLICATION. "Tcp" only checks that the port accepts a<br/>                connection, which a hung process will happily continue to<br/>                do — so a TCP probe reports healthy while every request<br/>                times out.<br/><br/>  thresholds    interval\_in\_seconds x probe\_threshold is how long a dead<br/>                instance keeps receiving traffic. The default 5s x 2 = 10s. | <pre>map(object({<br/>    protocol            = optional(string, "Tcp")<br/>    port                = number<br/>    request_path        = optional(string)<br/>    interval_in_seconds = optional(number, 5)<br/>    probe_threshold     = optional(number, 2)<br/>  }))</pre> | `{}` | no |
| <a name="input_public_ip_name"></a> [public\_ip\_name](#input\_public\_ip\_name) | Name for the public IP, created by this module for a public load balancer. | `string` | `null` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "app" lifecycle scope — a load balancer is deployed with the application, not with the network edge. | `string` | n/a | yes |
| <a name="input_rules"></a> [rules](#input\_rules) | Map of rule name to configuration. Each rule binds a frontend port to a backend port, a pool and a probe. | <pre>map(object({<br/>    protocol                = optional(string, "Tcp")<br/>    frontend_port           = number<br/>    backend_port            = number<br/>    backend_pool_name       = optional(string, "default")<br/>    probe_name              = string<br/>    idle_timeout_in_minutes = optional(number, 4)<br/>    load_distribution       = optional(string, "Default")<br/>    floating_ip_enabled     = optional(bool, false)<br/>    tcp_reset_enabled       = optional(bool, true)<br/>  }))</pre> | `{}` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet for the frontend. Required for an internal load balancer, and must be null for a public one. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_type"></a> [type](#input\_type) | "internal" or "public". | `string` | n/a | yes |
| <a name="input_zones"></a> [zones](#input\_zones) | Availability zones for the frontend. A zone-redundant frontend survives a zone outage; a zonal one does not. Empty means no zone preference, which for a Standard load balancer means zone-redundant by default. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backend_pool_ids"></a> [backend\_pool\_ids](#output\_backend\_pool\_ids) | Map of pool name to ID. Pass the relevant ID to the vm module's scale set network configuration. |
| <a name="output_frontend_ip_address"></a> [frontend\_ip\_address](#output\_frontend\_ip\_address) | The address clients connect to: the private frontend address for an internal load balancer, the public IP for a public one. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the load balancer. Diagnostic settings target this. |
| <a name="output_name"></a> [name](#output\_name) | Load balancer name. |
| <a name="output_orphaned_probes"></a> [orphaned\_probes](#output\_orphaned\_probes) | Probes no rule references. Inert — usually a rename that missed one side. |
| <a name="output_outbound_snat_disabled"></a> [outbound\_snat\_disabled](#output\_outbound\_snat\_disabled) | Whether load balancing rules perform outbound SNAT. Disabled in this platform: egress is the NAT Gateway's job, and a second undeclared egress path competes for a much smaller SNAT port allocation, which surfaces as intermittent outbound failures under load. |
| <a name="output_probe_detection_seconds"></a> [probe\_detection\_seconds](#output\_probe\_detection\_seconds) | Map of probe name to how long a failed instance keeps receiving traffic — interval\_in\_seconds multiplied by probe\_threshold. |
| <a name="output_probe_ids"></a> [probe\_ids](#output\_probe\_ids) | Map of probe name to ID. |
| <a name="output_public_ip_id"></a> [public\_ip\_id](#output\_public\_ip\_id) | Public IP resource ID, or null for an internal load balancer. |
| <a name="output_tcp_only_probes"></a> [tcp\_only\_probes](#output\_tcp\_only\_probes) | Probes checking only that a TCP port accepts connections. A hung process keeps accepting connections, so these report healthy while every request times out. Prefer an Http or Https probe with a request\_path wherever the backend speaks HTTP. |
| <a name="output_type"></a> [type](#output\_type) | "internal" or "public". |
| <a name="output_unused_backend_pools"></a> [unused\_backend\_pools](#output\_unused\_backend\_pools) | Pools no rule sends traffic to. A scale set attached to one of these sits healthy and idle, receiving nothing. |
<!-- END_TF_DOCS -->
