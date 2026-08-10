# Module: `networking`

Virtual network, subnets, and the NAT Gateway egress path. Validates the
address plan at plan time rather than discovering conflicts after deployment.

---

## Usage

```hcl
module "networking" {
  source = "../../modules/networking"

  vnet_name           = module.naming.names.virtual_network
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  address_space = ["10.10.0.0/16"]

  subnets = {
    AzureBastionSubnet = { cidr = "10.10.0.128/26" }

    "snet-app-dev-eus" = {
      cidr                  = "10.10.4.0/22"
      associate_nat_gateway = true
    }

    "snet-pep-dev-eus" = {
      cidr                              = "10.10.13.0/24"
      private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
      associate_nat_gateway             = true
    }
  }

  enable_nat_gateway         = module.profile.enable_nat_gateway
  nat_gateway_name           = module.naming.names.nat_gateway
  nat_gateway_public_ip_name = "pip-ng-${module.naming.base}-001"
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `vnet_name` | `string` | — | From `naming`. |
| `resource_group_name` | `string` | — | The `net` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `address_space` | `list(string)` | — | One `/16` per environment. |
| `dns_servers` | `list(string)` | `[]` | Empty means Azure-provided DNS. |
| `subnets` | `map(object)` | — | See below. |
| `enable_nat_gateway` | `bool` | `false` | From `profile`. |
| `nat_gateway_name` | `string` | `null` | From `naming`. |
| `nat_gateway_public_ip_name` | `string` | `null` | |
| `nat_gateway_zones` | `list(string)` | `[]` | At most one — a NAT Gateway is zonal. |
| `nat_gateway_idle_timeout_in_minutes` | `number` | `4` | 4–120. |

### Subnet object

| Field | Default | Description |
|---|---|---|
| `cidr` | — | Must sit inside `address_space`. |
| `service_endpoints` | `[]` | |
| `private_endpoint_network_policies` | `"Enabled"` | `Disabled` silently stops NSG rules applying. |
| `private_link_service_network_policies_enabled` | `true` | |
| `associate_nat_gateway` | `false` | Unsupported on Bastion/Firewall subnets. |
| `default_outbound_access_enabled` | `false` | Retired by Azure Sept 2025. |
| `delegation` | `null` | Optional service delegation. |

## Outputs

`vnet_id`, `vnet_name`, `address_space`, `resource_group_name`, `location`,
`subnet_ids`, `subnet_cidrs`, `subnets`, `nat_gateway_id`,
`nat_gateway_public_ip`, `nat_gateway_is_zonal`, `nat_associated_subnets`,
`subnets_without_egress`

---

## Design notes

**Subnets are discrete `azurerm_subnet` resources; the VNet declares address
space only.** `azurerm_virtual_network` also accepts an inline `subnet` block.
Using both forms produces permanent drift — the inline block treats subnets it
does not list as removable, so each apply deletes what the other form created
and the next apply recreates them. It is one of the most common reasons a
Terraform configuration never reaches a clean plan.

**`for_each` keyed by subnet name, never `count`.** With `count`, removing one
subnet re-indexes every subnet after it and Terraform plans to destroy and
recreate unrelated subnets — which fails anyway, since a subnet containing
resources cannot be deleted.

**CIDR overlap is detected numerically at plan time.** Terraform has no built-in
overlap function, so ranges are converted to integers and compared pairwise.
This matters because Azure accepts overlapping definitions in some orders and
rejects them in others, and an overlapping subnet cannot be corrected in
place — it must be emptied and rebuilt.

Pairs are compared by **index into a sorted key list**, not by key. Terraform's
`<` operator is numeric only and rejects string operands; comparing keys
directly fails at plan time with `Invalid operand`.

**`default_outbound_access_enabled = false` everywhere.** Azure retired default
outbound access on 30 September 2025. Setting it false explicitly means the
platform never silently depends on implicit egress: a subnet either has a NAT
Gateway, a firewall route, or no internet at all — and which one is visible in
configuration rather than inherited by accident.

**Reserved subnet minimum sizes are validated.** `AzureFirewallSubnet`,
`AzureFirewallManagementSubnet` and `AzureBastionSubnet` need `/26`;
`GatewaySubnet` needs `/27`. A smaller prefix is accepted at create time by some
API versions and then fails when the service is deployed — with an error naming
the *service*, not the subnet, which makes it hard to diagnose.

Azure reserves 5 addresses per subnet, so a `/26` yields 59 usable, not 64.

**A NAT Gateway is zonal, not zone-redundant.** It occupies one zone, and a zone
outage takes egress with it. Zone-resilient egress requires one gateway per
zone with subnets pinned accordingly, or Azure Firewall, which is
zone-redundant. `nat_gateway_is_zonal` surfaces which mode is in effect.

**Standard SKU public IP is the only option.** The Basic SKU was retired on
30 September 2025, so the historical "use Basic in dev to save money" move no
longer exists.

---

## Preconditions

| Check | Failure it prevents |
|---|---|
| No overlapping subnet CIDRs | A subnet that cannot be corrected without emptying and rebuilding it |
| Subnets inside `address_space` | API rejection late in the apply |
| Reserved subnets meet minimum size | Confusing failure that names the service, not the subnet |
| NAT association not on Bastion/Firewall subnets | Association fails, or silently breaks the service |
| No NAT request when `enable_nat_gateway` is false | Subnet silently has no egress at all |

---

## Cost

| Component | Approximate |
|---|---|
| VNet, subnets | Free |
| NAT Gateway | ~$33/month + ~$0.045/GB processed |
| Standard public IP | ~$3.65/month |

Against roughly $912/month for Azure Firewall Standard. The `profile` module
treats the two as mutually exclusive: a UDR to a firewall overrides a NAT
Gateway, so running both means paying for a gateway that never carries traffic.

---

## Deployed state

`dev` — applied and verified in Azure:

```
vnet-cloudcart-dev-eus-001        10.10.0.0/16

AzureBastionSubnet   10.10.0.128/26   no NAT (manages own egress)
snet-app-dev-eus     10.10.4.0/22     NAT
snet-biz-dev-eus     10.10.8.0/22     NAT
snet-db-dev-eus      10.10.12.0/24    NAT
snet-pep-dev-eus     10.10.13.0/24    NAT, NetworkSecurityGroupEnabled
snet-mgmt-dev-eus    10.10.14.0/24    NAT

ng-cloudcart-dev-eus-001   Standard, regional, 5 subnets, 1 public IP
SNAT address               20.85.212.228
```

Reserved and deliberately not allocated: `AzureFirewallSubnet` 10.10.0.0/26,
`AzureFirewallManagementSubnet` 10.10.0.64/26, `GatewaySubnet` 10.10.0.192/26,
`snet-agw` 10.10.1.0/24. Adding a firewall or Application Gateway later needs
no renumbering.
