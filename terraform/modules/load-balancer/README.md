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
<!-- END_TF_DOCS -->
