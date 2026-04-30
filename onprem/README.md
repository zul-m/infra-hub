# On Prem

Single Windows VM stack on Azure with direct RDP/WinRM access controlled by a caller-IP-aware CIDR allowlist.

This Terraform stack deploys:

- 1 Windows Server 2022 VM
- 1 VNet and subnet for the VM
- 1 NSG allowing inbound RDP (3389) and WinRM HTTPS (5986) from the Terraform runner's current public IP plus any extra configured CIDRs
- 1 static Standard Public IP attached to the VM NIC
- Auto-shutdown on the VM with notifications disabled
- WinRM HTTPS bootstrap on the VM via Custom Script Extension
- Post-provision Ansible run to install SQL Server 2022 and SSMS

## Requirement Mapping

- Region: configurable by `location`
- No infra redundancy: single VM instance, standard disk, no availability zones/sets
- Standard security: standard VM setup, no special trusted-launch requirements
- Public IP on VM: static Standard Public IP attached to VM NIC
- Inbound access restricted: NSG allows 3389/5986 from the Terraform runner's current public IP plus any additional `allowed_cidrs`
- Outbound access: VM uses Azure default outbound behavior (no NAT Gateway in this stack)
- Password secured: use sensitive Terraform variables (not hardcoded in code)

## Prerequisites

- Terraform >= 1.5
- Azure CLI logged in (`az login`)
- Permission to create networking, public IP, and VM resources
- Outbound internet access from the machine running Terraform to reach `api.ipify.org` and download Ansible/Chocolatey packages
- WSL available on the machine running Terraform because the post-provision Ansible step runs via `wsl bash -lc ...`
- Ansible and Python available inside the WSL environment that Terraform will use
- Network path from that WSL-backed Ansible environment to the VM public IP on port 5986
- WinRM Python dependency installed in that WSL environment:

```powershell
pip install pywinrm
```

- Ansible collections are downloaded automatically during `terraform apply` from `./ansible/requirements.yml`

## Deploy

1. Create your secrets file:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars` with your Azure IDs, admin credentials, and strong SQL password.
3. `allowed_cidrs` is optional. Terraform automatically adds the current public IP of the machine running `plan` or `apply`, and you can append extra trusted CIDRs if needed.
4. `prefix` and `env` control naming, and Terraform appends the current `MMDD` date automatically. With the current defaults on April 30, the resource group is `mumu-onprem-0430` and resources are named like `mumu-0430-vm`.
5. `vnet_cidr` and `vm_subnet_cidr` are optional. If omitted, Terraform uses `10.20.0.0/16` for the VNet and derives the VM subnet as `10.20.1.0/24`.
6. Initialize and deploy:

```powershell
terraform init
terraform plan
terraform apply
```

## Connect from Local Machine

1. Use the output `vm_public_ip` or `rdp_target` from Terraform.
2. Connect via RDP directly to the VM public IP.
3. Ensure you run Terraform from the same public IP you expect to use for access, or add that IP to `allowed_cidrs`.

Example:

```powershell
terraform output rdp_target
```

## Ansible Behavior

- Terraform runs `ansible-galaxy` and then the playbook from `ansible_playbook_path` via `local-exec`.
- The command always executes through WSL (`wsl bash -lc ...`) as part of `terraform apply`; there is no Terraform toggle in this stack to skip SQL/SSMS installation.
- SQL Server is always installed in mixed mode (SQL authentication enabled). Configure `sql_admin_username` and `sql_admin_password` accordingly.
- `ansible_playbook_path` defaults to `./ansible/playbooks/applications.yml` and can be overridden if you need a different playbook path.

## Outputs

- `resource_group_name`
- `vnet_name`
- `vm_private_ip`
- `vm_public_ip`
- `rdp_target`
- `sql_server_name`

## Notes

- This stack currently does not deploy Azure Bastion or NAT Gateway.
- NSG rules are driven by the detected caller IP plus `allowed_cidrs`; keep any additional entries minimal and specific.
- Terraform triggers Ansible from `./ansible/playbooks/applications.yml` by default.

## Security Recommendation

For stronger security, consider replacing direct VM public IP access with Azure Bastion or a private-only design in a future revision.
