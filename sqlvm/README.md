# SQL VM

Private on-prem simulation stack with SQL Server VM on Azure.

This Terraform stack deploys:

- 1 Windows Server 2022 VM (`onprem`)
- 1 SQL Server 2022 Developer VM (`sql` image)
- 1 private VM subnet with explicit outbound through Azure NAT Gateway
- 1 Azure Bastion host so your local machine can RDP without VM public IP
- Auto-shutdown on both VMs with notifications disabled

## Requirement Mapping

- Region: `southeastasia`
- No infra redundancy: single VM instances, standard disks, no availability zones/sets
- Standard security: standard VM setup, no special trusted-launch requirements
- No public IP (VM): both VM NICs are private only
- Explicit outbound internet access: NAT Gateway on the VM subnet
- No inbound ports from internet: NSG only allows RDP from Bastion subnet
- Password secured: use sensitive Terraform variables (not hardcoded in code)
- SQL image: `MicrosoftSQLServer/sql2022-ws2022/sqldev-gen2`
- SQL connectivity: `PRIVATE`, SQL authentication enabled

## Prerequisites

- Terraform >= 1.5
- Azure CLI logged in (`az login`)
- Permission to create networking, VM, and Bastion resources

## Deploy

1. Create your secrets file:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars` with strong passwords.

3. Initialize and deploy:

```powershell
terraform init
terraform plan
terraform apply
```

## Connect from Local Machine (Private)

1. After deploy, open Azure Portal and connect to the onprem VM using Azure Bastion.
2. Use VM local admin credentials configured in Terraform variables.
3. From the onprem VM, open SSMS and connect to SQL VM private IP using SQL auth credentials:
   - Server: `sql_vm_private_ip,1433`
   - Authentication: SQL Server Authentication

## Notes

- A public IP exists only on Azure Bastion (required for Bastion service).
- A separate public IP is attached to the NAT Gateway for outbound-only internet access.
- VMs still remain private-only with no public IP.

## Clearing the Azure Warning

This stack disables default outbound access on the VM subnet and adds an explicit outbound path through Azure NAT Gateway.

If you already deployed an earlier version of this stack and Azure still shows the warning on the VMs after `terraform apply`, stop and deallocate the VMs once so Azure clears the old default outbound flag on the NICs.
