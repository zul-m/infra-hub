# Keyvault

Windows jumpbox stack on Azure with Azure Key Vault-managed VM credentials.

## What this deploys

This stack creates:

- A Resource Group (name includes random suffix)
- Networking:
  - Virtual Network
  - `AzureBastionSubnet`
  - VM subnet (`snet-vm`)
- Azure Bastion (Standard SKU) with static public IP
- Azure Key Vault (RBAC mode enabled)
- Windows Server 2019 VM

## Module breakdown

### `modules/network`

Creates:

- VNet
- Bastion subnet (`AzureBastionSubnet`)
- VM subnet (`snet-vm`)

Outputs subnet IDs used by other modules.

### `modules/bastion`

Creates:

- Public IP for Bastion
- Azure Bastion host (Standard SKU)

Used to access the VM without exposing RDP publicly.

### `modules/keyvault`

Creates:

- Azure Key Vault (RBAC authorization enabled)
- Role assignment for current Terraform identity: `Key Vault Secrets Officer`
- Password secret (`<prefix>-<suffix>-vm-password`)
- Username secret (`<prefix>-<suffix>-vm-username`)

Behavior:

- If `generate_admin_password = true`, a random password is generated and stored in Key Vault.
- If `generate_admin_password = false` and `admin_password` is provided, that password is stored instead.
- Includes a wait (`time_sleep`) after role assignment to allow RBAC propagation before writing secrets.

### `modules/vm`

Creates:

- NIC in VM subnet
- Windows Server 2019 VM (`Premium_LRS` OS disk)

Credentials are passed from root module:

- Username from `admin_username`
- Password from Key Vault module output

## Prerequisites

- Terraform `>= 1.6.0`
- Azure subscription and tenant IDs
- Azure permissions to create:
  - Resource groups
  - Networking
  - Bastion
  - Key Vault + role assignments
  - Virtual machines
- Azure authentication already available in your shell (for example via `az login`)

## Configure tfvars from template

Use the provided example file as your starting point.

### Step 1: copy template to real tfvars file

PowerShell:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

### Step 2: update required values in `terraform.tfvars`

At minimum, set:

```hcl
subscription_id = "<your-azure-subscription-id>"
tenant_id       = "<your-azure-tenant-id>"
```

Common values to adjust:

```hcl
location = "southeastasia"
project  = "sitecore-aks"

vnet_cidr           = "10.50.0.0/16"
subnet_bastion_cidr = "10.50.0.0/26"
subnet_vm_cidr      = "10.50.1.0/24"

vm_size           = "Standard_D8s_v5"
vm_instance_count = 1
os_disk_size_gb   = 256
data_disk_size_gb = 256

admin_username          = "azureuser"
generate_admin_password = true
```

If you prefer to supply your own admin password:

```hcl
generate_admin_password = false
admin_password          = "<strong-password>"
```

Security note:

- Do not commit plaintext secrets to git.
- Keep `terraform.tfvars` local/ignored, and provide sensitive values through secure pipeline variables when possible.

## Deploy

```powershell
terraform init
terraform plan
terraform apply
```

## Notes and caveats

- Resource names include a random suffix for uniqueness.
- `vm_instance_count` is currently passed to the VM module but the module creates a single VM resource as written.
- Key Vault uses RBAC mode (`rbac_authorization_enabled = true`) and not access policies.
- Bastion requires subnet name `AzureBastionSubnet`, which is already handled by the network module.
