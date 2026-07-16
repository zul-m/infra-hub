# Infra Deploy

Deployment entrypoint with two separated targets under this folder:

- `vm/` for VM Terraform stack, tfvars, and Ansible provisioning
- `aks/` for AKS Terraform stack and wrapper script
- root `deploy.ps1` as a dispatcher

## Folder Layout

```text
vm-deploy/
  deploy.ps1
  .gitignore
  vm/
    deploy-vm.ps1
    main.tf
    variables.tf
    outputs.tf
    versions.tf
    terraform.tfvars
    terraform.tfvars.example
    ansible/
      requirements.yml
      playbooks/applications.yml
  aks/
    deploy-aks.ps1
    main.tf
    variables.tf
    outputs.tf
    versions.tf
    terraform.tfvars.example
```

## Prerequisites

- Azure CLI logged in (`az login`)
- For VM target:
  - Terraform >= 1.5
  - WSL available on Windows hosts (Ansible runs through WSL)
  - Ansible and Python in WSL
  - `pywinrm` installed in WSL
- For AKS target:
  - Terraform >= 1.5
  - `kubectl` only if you want to manually inspect/use the cluster after deploy

## Configure

1. VM variables:

```powershell
Copy-Item .\vm\terraform.tfvars.example .\vm\terraform.tfvars
```

2. Edit `vm/terraform.tfvars` and set your values (`location`, subscription/tenant IDs, VM credentials, SQL credentials, etc).

3. AKS variables:

```powershell
Copy-Item .\aks\terraform.tfvars.example .\aks\terraform.tfvars
```

Then edit `aks/terraform.tfvars` and use CLI flags only when you want one-off overrides.

## Deploy Via Root Script

Interactive (choose `vm` or `aks` first):

```powershell
.\deploy.ps1
```

VM apply:

```powershell
.\deploy.ps1 -Target vm -OsVersion win25 -Action apply -VmSize Standard_D4s_v3 -AutoApprove
```

VM plan/destroy:

```powershell
.\deploy.ps1 -Target vm -OsVersion win11 -Action plan
.\deploy.ps1 -Target vm -OsVersion win22 -Action destroy
```

AKS apply:

```powershell
.\deploy.ps1 -Target aks -Action apply -AutoApprove `
  -AksResourceGroup mumu-aks `
  -AksClusterName mumu-aks1361 `
  -AksWindowsAdminUsername mumu `
  -AksWindowsAdminPassword "<strong-password>"
```

AKS apply with optional workspace override:

```powershell
.\deploy.ps1 -Target aks -Action apply -AutoApprove `
  -AksResourceGroup mumu-aks `
  -AksClusterName mumu-aks1361 `
  -AksLogAnalyticsWorkspaceName mumu-aks1361-law `
  -AksWindowsAdminUsername mumu `
  -AksWindowsAdminPassword "<strong-password>"
```

AKS apply with registry pull secret (managed by Terraform):

```powershell
.\deploy.ps1 -Target aks -Action apply -AutoApprove `
  -AksResourceGroup mumu-aks `
  -AksClusterName mumu-aks1361 `
  -AksWindowsAdminUsername mumu `
  -AksWindowsAdminPassword "<strong-password>" `
  -AksRegistryServer ideftdevacr.azurecr.io `
  -AksRegistryUsername "<registry-username>" `
  -AksRegistryPassword "<registry-password>" `
  -AksRegistrySecretName sitecore-docker-registry
```

AKS destroy:

```powershell
.\deploy.ps1 -Target aks -Action destroy -AksResourceGroup mumu-aks -AksClusterName mumu-aks1361
```

## Notes

- Root `deploy.ps1` only routes to target-specific scripts; target logic is isolated per folder.
- VM Terraform state/caches and tfvars are now expected under `vm/`.
- AKS resources and ingress-nginx are provisioned by Terraform in `aks/`.
- Optional docker-registry pull secret is also managed by Terraform when registry inputs are provided.
- AKS script uses `vm/terraform.tfvars` location as default `AksLocation` only when `location` is not set in `aks/terraform.tfvars` and not passed as a CLI override.
- Legacy `-BootstrapAks` still maps to AKS apply for backward compatibility.
