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

## Common Workflow

From either stack directory:

```powershell
terraform init
terraform plan
terraform apply
```

Use each stack's local `terraform.tfvars.example` as the starting template.
