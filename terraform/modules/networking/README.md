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
| [azurerm_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/nat_gateway) | resource |
| [azurerm_nat_gateway_public_ip_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/nat_gateway_public_ip_association) | resource |
| [azurerm_public_ip.nat](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_subnet.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_nat_gateway_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_nat_gateway_association) | resource |
| [azurerm_virtual_network.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_address_space"></a> [address\_space](#input\_address\_space) | VNet address space. One non-overlapping /16 per environment — see docs/NETWORKING.md. Ranges are spaced so a future peering, VPN or ExpressRoute link cannot collide, which is the one networking mistake that cannot be fixed without rebuilding every resource in the subnet. | `list(string)` | n/a | yes |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Custom DNS servers for the VNet. Leave empty to use Azure-provided DNS, which is required for private endpoint resolution via private DNS zones. Setting custom servers without forwarding to 168.63.129.16 breaks private endpoint name resolution. | `list(string)` | `[]` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Deploy a NAT Gateway for outbound connectivity. Pass the profile module's enable\_nat\_gateway. Roughly $33/month plus $0.045/GB processed, against roughly $912/month for Azure Firewall. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_nat_gateway_idle_timeout_in_minutes"></a> [nat\_gateway\_idle\_timeout\_in\_minutes](#input\_nat\_gateway\_idle\_timeout\_in\_minutes) | Idle timeout for outbound flows, 4-120 minutes. Raising it holds SNAT ports longer, which reduces port exhaustion for long-lived connections but increases it for high-churn short connections. | `number` | `4` | no |
| <a name="input_nat_gateway_name"></a> [nat\_gateway\_name](#input\_nat\_gateway\_name) | NAT Gateway name, from naming.names.nat\_gateway. | `string` | `null` | no |
| <a name="input_nat_gateway_public_ip_name"></a> [nat\_gateway\_public\_ip\_name](#input\_nat\_gateway\_public\_ip\_name) | Name for the NAT Gateway's public IP. | `string` | `null` | no |
| <a name="input_nat_gateway_zones"></a> [nat\_gateway\_zones](#input\_nat\_gateway\_zones) | Availability zone to pin the NAT Gateway to. A NAT Gateway is ZONAL, not zone-redundant — it lives in exactly one zone, and a zone outage takes egress with it. Leave empty for a regional (non-zonal) deployment. For zone-resilient egress, deploy one NAT Gateway per zone with separate subnets, or use Azure Firewall, which is zone-redundant. | `list(string)` | `[]` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for the network. Should be the "net" lifecycle scope, so the identity that redeploys the application cannot delete the network edge. | `string` | n/a | yes |
| <a name="input_subnets"></a> [subnets](#input\_subnets) | Map of subnet key to configuration. The key is used for output lookup and<br/>for\_each addressing, so it must be stable — renaming a key destroys and<br/>recreates the subnet.<br/><br/>Azure reserves specific subnet NAMES with fixed minimum sizes:<br/>AzureFirewallSubnet (/26), AzureFirewallManagementSubnet (/26),<br/>AzureBastionSubnet (/26) and GatewaySubnet (/27, /26 recommended). Those<br/>names must be exact; the module validates their sizes.<br/><br/>Fields:<br/>  cidr                              Address prefix, must sit inside address\_space<br/>  service\_endpoints                 e.g. ["Microsoft.Storage"]<br/>  private\_endpoint\_network\_policies "Disabled", "Enabled",<br/>                                    "NetworkSecurityGroupEnabled" or<br/>                                    "RouteTableEnabled". Must not be<br/>                                    "Disabled" on the private endpoint<br/>                                    subnet if NSG rules are expected to<br/>                                    apply to it.<br/>  associate\_nat\_gateway             Route this subnet's egress via the NAT<br/>                                    Gateway. Unsupported on<br/>                                    AzureBastionSubnet and<br/>                                    AzureFirewallSubnet.<br/>  default\_outbound\_access\_enabled   Implicit outbound internet access.<br/>                                    Retired by Azure on 30 September 2025;<br/>                                    left false so the platform never relies<br/>                                    on it.<br/>  delegation                        Optional service delegation. | <pre>map(object({<br/>    cidr                                          = string<br/>    service_endpoints                             = optional(list(string), [])<br/>    private_endpoint_network_policies             = optional(string, "Enabled")<br/>    private_link_service_network_policies_enabled = optional(bool, true)<br/>    associate_nat_gateway                         = optional(bool, false)<br/>    default_outbound_access_enabled               = optional(bool, false)<br/>    delegation = optional(object({<br/>      name         = string<br/>      service_name = string<br/>      actions      = optional(list(string), [])<br/>    }), null)<br/>  }))</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_vnet_name"></a> [vnet\_name](#input\_vnet\_name) | Virtual network name, from naming.names.virtual\_network. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_address_space"></a> [address\_space](#output\_address\_space) | VNet address space. |
| <a name="output_location"></a> [location](#output\_location) | Region the network was created in. |
| <a name="output_nat_associated_subnets"></a> [nat\_associated\_subnets](#output\_nat\_associated\_subnets) | Subnets whose egress routes through the NAT Gateway. A subnet absent from this list, with no firewall route, has no outbound internet access — default outbound access was retired in September 2025. |
| <a name="output_nat_gateway_id"></a> [nat\_gateway\_id](#output\_nat\_gateway\_id) | NAT Gateway resource ID, or null when not deployed. |
| <a name="output_nat_gateway_is_zonal"></a> [nat\_gateway\_is\_zonal](#output\_nat\_gateway\_is\_zonal) | Whether the NAT Gateway is pinned to a single availability zone. When true, a zone outage removes egress for every associated subnet. When false the gateway is regional. Neither is zone-redundant — that requires one gateway per zone, or Azure Firewall. |
| <a name="output_nat_gateway_public_ip"></a> [nat\_gateway\_public\_ip](#output\_nat\_gateway\_public\_ip) | The public IP address all outbound traffic is SNATed to. This is the address to allowlist on any external service the workload calls. |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Resource group containing the network. |
| <a name="output_subnet_cidrs"></a> [subnet\_cidrs](#output\_subnet\_cidrs) | Map of subnet name to address prefix. NSG rules use these as source and destination prefixes, so tier-to-tier rules are derived from the address plan rather than restated. |
| <a name="output_subnet_ids"></a> [subnet\_ids](#output\_subnet\_ids) | Map of subnet name to ARM resource ID. This is what NSG associations, route table associations, private endpoints and scale sets consume. |
| <a name="output_subnets"></a> [subnets](#output\_subnets) | Full detail per subnet: id, name, cidr and the network policy settings actually applied. |
| <a name="output_subnets_without_egress"></a> [subnets\_without\_egress](#output\_subnets\_without\_egress) | Subnets with neither a NAT Gateway association nor implicit outbound access. Expected for AzureBastionSubnet, which manages its own path, but worth checking for anything else that appears here. |
| <a name="output_vnet_id"></a> [vnet\_id](#output\_vnet\_id) | ARM resource ID of the virtual network. Private DNS zone links and peerings target this. |
| <a name="output_vnet_name"></a> [vnet\_name](#output\_vnet\_name) | Virtual network name. |
<!-- END_TF_DOCS -->
