# Module: `bastion`

Azure Bastion — operator access to instances that carry no public IP and accept
SSH from nowhere except the Bastion path.

This is the module that makes the platform's "no public compute" position
workable rather than merely stated.

---

## The SKU changes the shape of the resource

Not just its capabilities. This is the main thing to understand before using
the module.

| | Developer | Basic | Standard | Premium |
|---|---|---|---|---|
| **Cost** | **None** | ~$140/mo | ~$175/mo base | Higher |
| **Attaches by** | `virtual_network_id` | `AzureBastionSubnet` | `AzureBastionSubnet` | `AzureBastionSubnet` |
| **Public IP** | None | Required | Required | Required |
| **Instances** | Shared regional | Fixed at 2 | 2–50 scale units | 2–50 |
| Native client tunneling | ✗ | ✗ | ✓ | ✓ |
| File copy | ✗ | ✗ | ✓ | ✓ |
| IP connect | ✗ | ✗ | ✓ | ✓ |
| Shareable links | ✗ | ✗ | ✓ | ✓ |
| Kerberos | ✗ | ✓ | ✓ | ✓ |
| Zones | ✗ | ✗ | ✓ | ✓ |
| Session recording | ✗ | ✗ | ✗ | ✓ |

**Developer is a shared regional instance.** It does not consume
`AzureBastionSubnet`, takes no public IP, and offers browser sessions only. It
also does not work across peered VNets. Regional availability is limited.

Because the SKU determines whether `virtual_network_id` or an
`ip_configuration` block applies, a mismatched pairing is rejected by
preconditions here rather than by Azure several minutes into a ~10 minute
provisioning attempt.

---

## Usage

```hcl
module "bastion" {
  source = "../../modules/bastion"
  count  = module.profile.enable_bastion ? 1 : 0

  name                = module.naming.names.bastion
  resource_group_name = module.resource_group.names["net"]
  location            = module.resource_group.location
  tags                = module.tags.tags

  sku = module.profile.profile.bastion_sku

  virtual_network_id = module.profile.profile.bastion_sku == "Developer" ? module.networking.vnet_id : null
  subnet_id          = module.profile.profile.bastion_sku == "Developer" ? null : module.networking.subnet_ids["AzureBastionSubnet"]
  public_ip_name     = module.profile.profile.bastion_sku == "Developer" ? null : "pip-bas-cloudcart-dev-eus-001"
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | From `naming`. |
| `resource_group_name` | `string` | — | The `net` scope. |
| `location` | `string` | — | Normalised region. |
| `tags` | `map(string)` | — | From `tags`. |
| `sku` | `string` | `"Basic"` | From `profile`. |
| `virtual_network_id` | `string` | `null` | Developer only. |
| `subnet_id` | `string` | `null` | Basic and above only. |
| `public_ip_name` | `string` | `null` | Basic and above only. |
| `zones` | `list(string)` | `[]` | Standard/Premium only. |
| `scale_units` | `number` | `2` | Standard/Premium only, 2–50. |
| `copy_paste_enabled` | `bool` | `true` | All SKUs. |
| `file_copy_enabled` | `bool` | `false` | Standard/Premium. |
| `tunneling_enabled` | `bool` | `false` | Standard/Premium. |
| `ip_connect_enabled` | `bool` | `false` | Standard/Premium. |
| `shareable_link_enabled` | `bool` | `false` | Standard/Premium. |
| `kerberos_enabled` | `bool` | `false` | Basic and above. |
| `session_recording_enabled` | `bool` | `false` | Premium only. |

`private_only_enabled` is **not** an input. It is computed-only in azurerm
4.x — readable but not settable — so it is exposed as an output instead.

## Outputs

`id`, `name`, `dns_name`, `sku`, `public_ip_address`, `public_ip_id`,
`private_only_enabled`, `uses_dedicated_subnet`, `supports_native_client`,
`supports_file_copy`, `capability_notes`

---

## Design notes

**The SKU capability matrix is encoded, not documented.** Setting a
Standard-only feature on Basic fails at apply after several minutes of
provisioning. The preconditions move that to plan time, in under a second, with
a message naming the feature and the SKU that would support it.

**`shareable_link_enabled` defaults false.** It generates links granting session
access to users who hold no Azure RBAC on the target. That is an authentication
bypass by design — occasionally the right tool, never a sensible default.

**Session recording and shareable links are mutually exclusive**, and the
precondition explains why rather than simply relaying Azure's rejection: a
shareable link grants access without RBAC, so a recorded session could not be
attributed to an identity. Recording that cannot be attributed is not an audit
trail.

**`capability_notes` is an output** so an operator who did not choose the SKU
can see from `terraform output` why the native client will not connect, rather
than debugging it.

---

## Cost

| SKU | Approximate |
|---|---|
| Developer | **$0** |
| Basic | ~$140/month + outbound data |
| Standard | ~$175/month base + per scale unit + outbound data |

On a credit-limited subscription, Developer is the difference between Bastion
being free and Bastion being most of the monthly budget.

---

## Deployed state

`dev` — Developer SKU:

```
sku                     Developer
attaches by             virtual_network_id
uses AzureBastionSubnet no
public IP               none
native client           no — browser sessions only
cost                    $0
```

`AzureBastionSubnet` and its nine mandated NSG rules exist from modules 7 and
8 and stay empty, held in reserve so a later move to Standard needs no network
change.

---

## Upgrading to Standard

Change `bastion_sku` in the profile. The module then requires `subnet_id` and
`public_ip_name`, which the environment root already computes conditionally.
The subnet and its NSG rules are already correct.

Standard is worth it when operators need `az network bastion tunnel` for native
SSH and SCP, when sessions must cross a VNet peering, or when concurrent
session count exceeds what a shared instance provides.

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
| [azurerm_bastion_host.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/bastion_host) | resource |
| [azurerm_public_ip.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_copy_paste_enabled"></a> [copy\_paste\_enabled](#input\_copy\_paste\_enabled) | Allow clipboard copy and paste in the browser session. Supported on all SKUs. Disabling it is a data-exfiltration control that also makes routine operator work materially slower. | `bool` | `true` | no |
| <a name="input_file_copy_enabled"></a> [file\_copy\_enabled](#input\_file\_copy\_enabled) | Allow file upload and download through the session. Standard and Premium only. | `bool` | `false` | no |
| <a name="input_ip_connect_enabled"></a> [ip\_connect\_enabled](#input\_ip\_connect\_enabled) | Allow connecting to a target by private IP rather than by resource ID. Standard and Premium only. Convenient, and it widens reachable targets to anything routable from the Bastion subnet. | `bool` | `false` | no |
| <a name="input_kerberos_enabled"></a> [kerberos\_enabled](#input\_kerberos\_enabled) | Enable Kerberos authentication for domain-joined targets. Basic and above. | `bool` | `false` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region, normalised form. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Bastion host name, from naming.names.bastion. | `string` | n/a | yes |
| <a name="input_public_ip_name"></a> [public\_ip\_name](#input\_public\_ip\_name) | Name for the Bastion public IP, created by this module for Basic and above. Unused by Developer. | `string` | `null` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group. Should be the "net" lifecycle scope — Bastion is network edge, not application. | `string` | n/a | yes |
| <a name="input_scale_units"></a> [scale\_units](#input\_scale\_units) | Instance count, 2-50. Standard and Premium only; Basic is fixed at 2 and Developer is a shared instance. Each unit supports roughly 20 concurrent sessions. | `number` | `2` | no |
| <a name="input_session_recording_enabled"></a> [session\_recording\_enabled](#input\_session\_recording\_enabled) | Record sessions for audit. Premium only. Cannot be combined with shareable links. | `bool` | `false` | no |
| <a name="input_shareable_link_enabled"></a> [shareable\_link\_enabled](#input\_shareable\_link\_enabled) | Allow generating links that grant session access to users without Azure RBAC on the target. Standard and Premium only. Off by default — it is an authentication bypass by design. | `bool` | `false` | no |
| <a name="input_sku"></a> [sku](#input\_sku) | Bastion SKU. Pass the profile module's bastion\_sku. Developer carries no charge but is portal-only and does not use AzureBastionSubnet. | `string` | `"Basic"` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | AzureBastionSubnet ID. Required for Basic, Standard and Premium, and must be null for Developer. The subnet must be named exactly AzureBastionSubnet and be /26 or larger. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags from the tags module. | `map(string)` | n/a | yes |
| <a name="input_tunneling_enabled"></a> [tunneling\_enabled](#input\_tunneling\_enabled) | Allow native client connections via `az network bastion tunnel`, rather than browser only. Standard and Premium only. This is the main practical reason to move off Developer. | `bool` | `false` | no |
| <a name="input_virtual_network_id"></a> [virtual\_network\_id](#input\_virtual\_network\_id) | Virtual network the Developer SKU attaches to. Required for Developer, and must be null for every other SKU. | `string` | `null` | no |
| <a name="input_zones"></a> [zones](#input\_zones) | Availability zones for the Bastion host. Supported on Standard and Premium only. Empty means regional. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_capability_notes"></a> [capability\_notes](#output\_capability\_notes) | Human-readable summary of what this SKU can and cannot do, for operators who did not choose it. |
| <a name="output_dns_name"></a> [dns\_name](#output\_dns\_name) | FQDN of the Bastion host. Used by `az network bastion` and by the portal to establish sessions. |
| <a name="output_id"></a> [id](#output\_id) | ARM resource ID of the Bastion host. Diagnostics target this. |
| <a name="output_name"></a> [name](#output\_name) | Bastion host name. |
| <a name="output_private_only_enabled"></a> [private\_only\_enabled](#output\_private\_only\_enabled) | Whether Azure reports the host as private-only. Computed-only in azurerm 4.x — readable but not settable through Terraform. |
| <a name="output_public_ip_address"></a> [public\_ip\_address](#output\_public\_ip\_address) | Public IP of the Bastion host, or null on the Developer SKU, which is a shared regional instance with no dedicated public endpoint. |
| <a name="output_public_ip_id"></a> [public\_ip\_id](#output\_public\_ip\_id) | Public IP resource ID, or null on Developer. |
| <a name="output_sku"></a> [sku](#output\_sku) | SKU actually deployed. |
| <a name="output_supports_file_copy"></a> [supports\_file\_copy](#output\_supports\_file\_copy) | Whether files can be transferred through the session. |
| <a name="output_supports_native_client"></a> [supports\_native\_client](#output\_supports\_native\_client) | Whether `az network bastion tunnel` and native RDP/SSH clients work. False on Developer and Basic — those are browser-only. |
| <a name="output_uses_dedicated_subnet"></a> [uses\_dedicated\_subnet](#output\_uses\_dedicated\_subnet) | Whether this SKU consumes AzureBastionSubnet. False on Developer, which attaches by virtual network ID — meaning AzureBastionSubnet stays empty and is held in reserve for a later SKU upgrade. |
<!-- END_TF_DOCS -->
