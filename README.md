# Infra Hub

This repository is a hub for Azure infrastructure stack variations.

## Current Stacks

### `sqlvm`

Use this stack when you need:

- Private Windows VM + SQL Server VM setup
- Bastion-based private access (no VM public IP)
- NAT-based explicit outbound internet for private subnet

Path: `./sqlvm`

### `keyvault`

Use this stack when you need:

- Windows jumpbox pattern with reusable modules
- Azure Key Vault RBAC integration for VM credential storage
- Bastion access and standard virtual network layout

Path: `./keyvault`

### `onprem`

Use this stack when you need:

- Single Windows Server 2022 VM with direct public IP access
- RDP and WinRM HTTPS controlled via the Terraform runner's public IP plus optional extra CIDRs
- Automated SQL Server 2022 and SSMS install via WSL-backed Ansible post-provisioning

Path: `./onprem`

## Common Workflow

From any stack directory:

```powershell
terraform init
terraform plan
terraform apply
```

Use each stack's local `terraform.tfvars.example` as the starting template.
