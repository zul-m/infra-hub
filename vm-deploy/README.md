# VM Deploy

Single Windows VM stack on Azure with direct RDP/WinRM access controlled by a caller-IP-aware CIDR allowlist.

This Terraform stack deploys:

- 1 Windows VM
- 1 VNet and subnet for the VM
- 1 NSG allowing inbound RDP (3389) and WinRM HTTPS (5986) from the Terraform runner's current public IP plus any extra configured CIDRs
- 1 static Standard Public IP attached to the VM NIC
- Auto-shutdown on the VM with notifications disabled
- WinRM HTTPS bootstrap on the VM via Custom Script Extension
- Post-provision Ansible run to install applications from `ansible/playbooks/applications.yml`, including SQL Server tooling, Azure CLI, and Azure Storage Explorer

## Prerequisites

- Terraform >= 1.5
- Azure CLI logged in (`az login`)
- Permission to create resource groups, networking, public IP, and VM resources
- Outbound internet access from the machine running Terraform to reach `api.ipify.org`
- WSL available on Windows hosts because post-provision Ansible is executed through `wsl bash -lc ...`
- Ansible and Python available in your WSL environment
- Network path from your runner/WSL environment to VM public IP on port 5986
- WinRM Python dependency installed in WSL:

```powershell
pip install pywinrm
```

## Configure

1. Copy the example variable file:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars` and set required values:

- `location`
- `tenant_id`
- `subscription_id`
- VM image fields (`vm_image_publisher`, `vm_image_offer`, `vm_image_sku`, `vm_image_version`)
- VM admin credentials (`vm_admin_username`, `vm_admin_password`)
- SQL admin credentials (`sql_admin_username`, `sql_admin_password`)

3. Optional values:

- `allowed_cidrs`: extra trusted CIDRs in addition to your detected public IP
- `vnet_cidr` and `vm_subnet_cidr`: custom networking CIDRs
- `ansible_playbook_path`: alternate Ansible playbook path

## Deploy

Preferred option: use the `deploy.ps1` wrapper, which includes Azure login preflight, OS selection menu, and optional auto-approve flow.

Interactive menu:

```powershell
.\deploy.ps1
```

Non-interactive apply example:

```powershell
.\deploy.ps1 -OsVersion win25 -Action apply -AutoApprove
```

You can also run plan/destroy non-interactively:

```powershell
.\deploy.ps1 -OsVersion win11 -Action plan
.\deploy.ps1 -OsVersion win22 -Action destroy
```

Manual Terraform commands:

```powershell
terraform init
terraform plan
terraform apply
```

## Outputs

- `resource_group_name`
- `vnet_name`
- `vm_private_ip`
- `vm_public_ip`
- `rdp_target`
- `vm_name`

## Notes

- Resource names use a stable suffix from `resource_name_suffix`.
- NSG inbound access is intentionally restricted to the runner public IP plus `allowed_cidrs`.
- Terraform triggers Ansible automatically during `apply` via `local-exec`.
