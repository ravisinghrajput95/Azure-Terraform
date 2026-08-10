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
<!-- END_TF_DOCS -->
