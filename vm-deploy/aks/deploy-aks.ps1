<#
.SYNOPSIS
    AKS deployment tool for vm-deploy/aks.

.DESCRIPTION
    Uses Terraform to provision AKS resources and addons.

.PARAMETER Action
    AKS action: apply | destroy

.PARAMETER AutoApprove
    Skip confirmation prompts.
#>
[CmdletBinding()]
param(
    [ValidateSet("apply", "destroy")]
    [string]$Action,

    [switch]$AutoApprove,

    [string]$AksResourceGroup = "mumu-aks",

    [string]$AksClusterName = "mumu-aks1361",

    [string]$AksLocation,

    [string]$AksKubernetesVersion = "1.36.1",

    [ValidateSet("Free", "Standard", "Premium")]
    [string]$AksSkuTier = "Free",

    [int]$AksLinuxNodeCount = 1,

    [string]$AksLinuxNodeVmSize = "Standard_D4s_v3",

    [int]$AksWindowsNodeCount = 2,

    [string]$AksWindowsNodeVmSize = "Standard_D4_v3",

    [string]$AksWindowsNodePoolName = "win",

    [string]$AksWindowsAdminUsername = "mumu",

    [string]$AksWindowsAdminPassword,

    [string]$AksLogAnalyticsWorkspaceName,

    [string]$AksRegistryServer,

    [string]$AksRegistryUsername,

    [string]$AksRegistryPassword,

    [string]$AksRegistrySecretName = "sitecore-docker-registry"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-AzLogin {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI is not installed. Install it first: https://aka.ms/installazurecliwindows"
    }

    & az account show --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Azure CLI auth: already signed in." -ForegroundColor Green
        return
    }

    Write-Host "  Azure CLI auth: not signed in." -ForegroundColor Yellow
    $choice = $Host.UI.PromptForChoice(
        "  Azure sign-in required",
        "  You are not signed in to Azure CLI. Sign in now?",
        @("&Yes", "&No"),
        0
    )

    if ($choice -ne 0) {
        throw "Azure sign-in is required before running AKS operations."
    }

    Write-Host "  Launching Azure login (device code)..." -ForegroundColor Cyan
    & az login --use-device-code
    if ($LASTEXITCODE -ne 0) {
        throw "az login failed with exit code $LASTEXITCODE"
    }

    & az account show --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Azure login completed, but no active account context is available."
    }

    Write-Host "  Azure CLI auth: sign-in successful." -ForegroundColor Green
}

function Assert-TerraformInstalled {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw "Terraform is not installed or not on PATH. Install it first: https://developer.hashicorp.com/terraform/downloads"
    }
}

function Ensure-NonEmpty {
    param(
        [string]$Value,
        [string]$Name
    )

    if (-not $Value -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }
}

function Select-Option {
    param(
        [string]   $Prompt,
        [string[]] $Options,
        [int]      $Default = 0
    )

    $idx = if ($Default -ge 0 -and $Default -lt $Options.Count) { $Default } else { -1 }
    $menuLines = $Options.Count + 5
    $esc = [char]27
    $firstRender = $true

    while ($true) {
        if (-not $firstRender) {
            Write-Host -NoNewline "$esc[$($menuLines)A"
        }
        $firstRender = $false

        Write-Host ""
        Write-Host "  $Prompt" -ForegroundColor Yellow
        Write-Host ""

        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $idx) {
                Write-Host "   " -NoNewline
                Write-Host " $($Options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host "     $($Options[$i])"
            }
        }

        Write-Host ""
        Write-Host "   [Up/Down] Navigate   [Enter] Confirm   [Esc] Quit" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            UpArrow {
                if ($idx -eq -1) {
                    $idx = 0
                } elseif ($idx -gt 0) {
                    $idx--
                }
            }
            DownArrow {
                if ($idx -eq -1) {
                    $idx = 0
                } elseif ($idx -lt $Options.Count-1) {
                    $idx++
                }
            }
            Enter {
                if ($idx -ge 0) {
                    Write-Host ""
                    return $Options[$idx]
                }
            }
            Escape { Write-Host "`n  Cancelled.`n"; exit 0 }
        }
    }
}

function Get-DefaultAksLocation {
    $vmTfvarsPath = Join-Path (Join-Path $PSScriptRoot "..") "vm\terraform.tfvars"
    if (-not (Test-Path $vmTfvarsPath)) {
        return $null
    }

    $match = Select-String -Path $vmTfvarsPath -Pattern '^\s*location\s*=\s*"([^"]+)"\s*$' | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value
}

if (-not $AksLocation) {
    $AksLocation = Get-DefaultAksLocation
}

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |       AKS Deploy (Terraform)         |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan

if (-not $Action) {
    $Action = Select-Option -Prompt "Select action:" -Options @("apply", "destroy") -Default 0
}

if (-not $AutoApprove) {
    $choice = Select-Option -Prompt "Auto-approve?" -Options @("No  - pause and review before applying", "Yes - execute immediately") -Default 0
    $AutoApprove = $choice -like "Yes*"
}

$createRegistrySecret = $false
if ($AksRegistryServer -and $AksRegistryUsername -and $AksRegistryPassword) {
    $createRegistrySecret = $true
} elseif ($AksRegistryServer -or $AksRegistryUsername -or $AksRegistryPassword) {
    throw "AksRegistryServer, AksRegistryUsername, and AksRegistryPassword must all be set together."
}

if ($Action -eq "apply" -and $AksWindowsNodeCount -gt 0 -and -not $AksWindowsAdminPassword) {
    $tfvarsPath = Join-Path $PSScriptRoot "terraform.tfvars"
    if (Test-Path $tfvarsPath) {
        $tfvarsMatch = Select-String -Path $tfvarsPath -Pattern '^\s*windows_admin_password\s*=\s*"([^"]+)"\s*$' | Select-Object -First 1
        if ($tfvarsMatch) {
            $AksWindowsAdminPassword = $tfvarsMatch.Matches[0].Groups[1].Value
        }
    }
}

if ($Action -eq "apply" -and $AksWindowsNodeCount -gt 0) {
    Ensure-NonEmpty -Value $AksWindowsAdminPassword -Name "AksWindowsAdminPassword (required when AksWindowsNodeCount > 0)"
}

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |              Summary                 |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ("  |  Target       : {0,-22}|" -f "aks") -ForegroundColor White
Write-Host ("  |  Action       : {0,-22}|" -f $Action) -ForegroundColor White
Write-Host ("  |  Auto-approve : {0,-22}|" -f ([string]$AutoApprove)) -ForegroundColor White
Write-Host ("  |  AKS RG       : {0,-22}|" -f $AksResourceGroup) -ForegroundColor White
Write-Host ("  |  AKS cluster  : {0,-22}|" -f $AksClusterName) -ForegroundColor White
Write-Host ("  |  K8s version  : {0,-22}|" -f $AksKubernetesVersion) -ForegroundColor White
Write-Host ("  |  SKU tier     : {0,-22}|" -f $AksSkuTier) -ForegroundColor White
Write-Host ("  |  Location     : {0,-22}|" -f $AksLocation) -ForegroundColor White
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ""

if ($Action -eq "destroy" -and -not $AutoApprove) {
    $ok = $Host.UI.PromptForChoice(
        "  Confirm AKS destroy",
        "  This will DELETE AKS cluster '$AksClusterName' and managed resources. Continue?",
        @("&Yes", "&No"),
        1
    )
    if ($ok -ne 0) {
        Write-Host "  Cancelled.`n"
        exit 0
    }
}

$terraformArgs = @(
    $Action
)

if ($PSBoundParameters.ContainsKey("AksResourceGroup")) {
    $terraformArgs += @("-var", "resource_group_name=$AksResourceGroup")
}
if ($PSBoundParameters.ContainsKey("AksClusterName")) {
    $terraformArgs += @("-var", "cluster_name=$AksClusterName")
}
if ($PSBoundParameters.ContainsKey("AksLocation")) {
    $terraformArgs += @("-var", "location=$AksLocation")
}
if ($PSBoundParameters.ContainsKey("AksKubernetesVersion")) {
    $terraformArgs += @("-var", "kubernetes_version=$AksKubernetesVersion")
}
if ($PSBoundParameters.ContainsKey("AksSkuTier")) {
    $terraformArgs += @("-var", "aks_sku_tier=$AksSkuTier")
}
if ($PSBoundParameters.ContainsKey("AksLinuxNodeCount")) {
    $terraformArgs += @("-var", "linux_node_count=$AksLinuxNodeCount")
}
if ($PSBoundParameters.ContainsKey("AksLinuxNodeVmSize")) {
    $terraformArgs += @("-var", "linux_node_vm_size=$AksLinuxNodeVmSize")
}
if ($PSBoundParameters.ContainsKey("AksWindowsNodeCount")) {
    $terraformArgs += @("-var", "windows_node_count=$AksWindowsNodeCount")
}
if ($PSBoundParameters.ContainsKey("AksWindowsNodeVmSize")) {
    $terraformArgs += @("-var", "windows_node_vm_size=$AksWindowsNodeVmSize")
}
if ($PSBoundParameters.ContainsKey("AksWindowsNodePoolName")) {
    $terraformArgs += @("-var", "windows_node_pool_name=$AksWindowsNodePoolName")
}
if ($PSBoundParameters.ContainsKey("AksWindowsAdminUsername")) {
    $terraformArgs += @("-var", "windows_admin_username=$AksWindowsAdminUsername")
}
if ($PSBoundParameters.ContainsKey("AksRegistrySecretName")) {
    $terraformArgs += @("-var", "registry_secret_name=$AksRegistrySecretName")
}
if ($PSBoundParameters.ContainsKey("AksLogAnalyticsWorkspaceName")) {
    $terraformArgs += @("-var", "log_analytics_workspace_name=$AksLogAnalyticsWorkspaceName")
}

if ($createRegistrySecret) {
    $terraformArgs += @("-var", "create_registry_secret=true")
}

if ($PSBoundParameters.ContainsKey("AksRegistryServer")) {
    $terraformArgs += @("-var", "registry_server=$AksRegistryServer")
}
if ($PSBoundParameters.ContainsKey("AksRegistryUsername")) {
    $terraformArgs += @("-var", "registry_username=$AksRegistryUsername")
}

# Intentionally do not pass registry password via -var to avoid leaking secrets in process args.
if ($createRegistrySecret -and -not $PSBoundParameters.ContainsKey("AksRegistryPassword")) {
    throw "AksRegistryPassword is required when registry secret creation is enabled."
}

if ($AutoApprove) {
    $terraformArgs += "-auto-approve"
}

# Avoid quoting issues for special characters in passwords by passing via TF_VAR env.
if ($AksWindowsAdminPassword) {
    $env:TF_VAR_windows_admin_password = $AksWindowsAdminPassword
}
if ($PSBoundParameters.ContainsKey("AksRegistryPassword")) {
    Ensure-NonEmpty -Value $AksRegistryPassword -Name "AksRegistryPassword"
    $env:TF_VAR_registry_password = $AksRegistryPassword
}

Push-Location $PSScriptRoot
try {
    Assert-TerraformInstalled
    Ensure-AzLogin

    & terraform init -input=false
    if ($LASTEXITCODE -ne 0) {
        throw "terraform init exited with code $LASTEXITCODE"
    }

    & terraform @terraformArgs
    if ($LASTEXITCODE -ne 0) {
        throw "terraform $Action exited with code $LASTEXITCODE"
    }

} finally {
    Remove-Item Env:TF_VAR_windows_admin_password -ErrorAction SilentlyContinue
    Remove-Item Env:TF_VAR_registry_password -ErrorAction SilentlyContinue
    Pop-Location
}
