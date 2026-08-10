# Azure-Terraform

Provisions the **cloudcart** environment on Microsoft Azure with Terraform: a
VNet with two subnets, a Linux bastion VM, and an AKS cluster.

## Layout

```
providers.tf   azurerm ~> 3.117, Service Principal auth
backend.tf     partial azurerm backend, filled from backend.conf
main.tf        resource group data source + network / virtual_machine / aks modules
variables.tf   auth, resource group, tags, SSH
outputs.tf     bastion IP + SSH command, AKS name and kubeconfig

modules/
  virtual_machine/   public IP, NIC, NSG, Ubuntu 24.04 VM with SystemAssigned identity
  aks/               AKS cluster on subnet2, SystemAssigned identity
```

## Prerequisites

The resource group and the state storage account are **not** managed by this
config — they must exist before the first `init`, since the backend lives in
them. `main.tf` reads the resource group through a data source.

## Usage

```bash
terraform init -backend-config=backend.conf
terraform plan
terraform apply
```

`backend.conf` and `terraform.tfvars` hold credentials and are gitignored.
Copy the examples below and fill in your own values.

**terraform.tfvars**

```hcl
client_id         = "..."
client_secret     = "..."
tenant_id         = "..."
subscription_id   = "..."
ssh_public_key    = "ssh-rsa AAAA..."
ssh_allowed_cidrs = ["203.0.113.4/32"]
```

**backend.conf**

```hcl
client_id            = "..."
client_secret        = "..."
tenant_id            = "..."
subscription_id      = "..."
resource_group_name  = "cloudcart"
storage_account_name = "..."
container_name       = "..."
key                  = "terraform.tfstate"
use_azuread_auth     = true
```

## Notes

- `ssh_allowed_cidrs` defaults to `[]`, which creates **no** inbound SSH rule.
  Set it to your own CIDR to reach the bastion.
- The bastion sits on `subnet1` (10.0.1.0/24), AKS nodes on `subnet2`
  (10.0.2.0/24).
- Cluster credentials: `terraform output -raw aks_kube_config > ~/.kube/config`
