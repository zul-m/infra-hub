<#
.SYNOPSIS
    VM deployment tool for vm-deploy/vm.

.DESCRIPTION
    Run with no arguments for the arrow-key menu.
    Pass parameters directly to skip the menu (useful for scripting).

.PARAMETER OsVersion
    OS profile: win11 | win10 | win19 | win22 | win25

.PARAMETER Action
    Terraform action: plan | apply | destroy

.PARAMETER VmSize
    VM size: Standard_D4s_v3 | Standard_D8s_v3

.PARAMETER AutoApprove
    Skip the Terraform confirmation prompt.
#>
[CmdletBinding()]
param(
    [ValidateSet("win10", "win11", "win19", "win22", "win25")]
    [string]$OsVersion,

    [ValidateSet("plan", "apply", "destroy")]
    [string]$Action,

    [ValidateSet("Standard_D4s_v3", "Standard_D8s_v3")]
    [string]$VmSize,

    [switch]$AutoApprove
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
        throw "Azure sign-in is required before running Terraform."
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

function Get-TfvarsQuotedValue {
    param(
        [string]$Key,
        [string]$Guidance
    )

    $tfvarsPath = Join-Path $PSScriptRoot "terraform.tfvars"
    if (-not (Test-Path $tfvarsPath)) {
        throw "terraform.tfvars was not found at '$tfvarsPath'. This file must define $Key for preflight checks."
    }

    $escapedKey = [regex]::Escape($Key)
    $pattern = '^\s*' + $escapedKey + '\s*=\s*"([^"]+)"\s*$'
    $match = Select-String -Path $tfvarsPath -Pattern $pattern | Select-Object -First 1
    if (-not $match) {
        throw $Guidance
    }

    return $match.Matches[0].Groups[1].Value
}

function Get-TerraformLocation {
    return Get-TfvarsQuotedValue -Key "location" -Guidance 'No location entry was found in terraform.tfvars. Add a line like: location = "southeastasia"'
}

function Test-AzVmImageSkuAvailable {
    param(
        [hashtable]$Image,
        [string]$Location,
        [string]$Action
    )

    if ($Action -eq "destroy") {
        return
    }

    Write-Host "  Preflight: validating image SKU '$($Image.sku)' in '$Location'..." -ForegroundColor Cyan

    $skuNames = & az vm image list-skus --location $Location --publisher $Image.publisher --offer $Image.offer --query "[].name" --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query image SKUs from Azure CLI for location '$Location' (publisher '$($Image.publisher)', offer '$($Image.offer)')."
    }

    if (-not $skuNames -or ($skuNames -notcontains $Image.sku)) {
        throw "Selected image SKU '$($Image.sku)' is not available in location '$Location' for publisher '$($Image.publisher)' and offer '$($Image.offer)'."
    }

    Write-Host "  Preflight: image SKU is available." -ForegroundColor Green
}

function Assert-VcpuQuotaHeadroom {
    param(
        [pscustomobject]$Usage,
        [int]$RequiredCores,
        [string]$QuotaLabel
    )

    if (-not $Usage) {
        throw "Quota entry '$QuotaLabel' was not found in Azure usage output."
    }

    $current = [int]$Usage.current
    $limit = [int]$Usage.limit
    $available = $limit - $current
    if ($available -lt $RequiredCores) {
        throw "Insufficient $QuotaLabel quota: required $RequiredCores vCPUs, available $available (current $current / limit $limit)."
    }
}

function Test-AzVmQuotaAvailable {
    param(
        [string]$Location,
        [string]$VmSize,
        [string]$Action
    )

    if ($Action -eq "destroy") {
        return
    }

    Write-Host "  Preflight: validating quota for VM size '$VmSize' in '$Location'..." -ForegroundColor Cyan

    $skuInfoJson = & az vm list-skus --location $Location --size $VmSize --resource-type virtualMachines --query '[0].{name:name,family:family,vcpus:capabilities[?name==`"vCPUs`"].value | [0]}' --output json
    if ($LASTEXITCODE -ne 0 -or -not $skuInfoJson) {
        throw "Failed to query VM SKU metadata for '$VmSize' in '$Location'."
    }

    $skuInfo = $skuInfoJson | ConvertFrom-Json
    if (-not $skuInfo -or -not $skuInfo.vcpus) {
        throw "VM size '$VmSize' was not found in location '$Location'."
    }

    $requiredCores = [int]$skuInfo.vcpus
    if ($requiredCores -le 0) {
        throw "Could not determine required vCPUs for VM size '$VmSize'."
    }

    $familyQuotaKey = [string]$skuInfo.family
    $usageQuery = "[?name.value=='cores' || name.value=='$familyQuotaKey'].{value:name.value,current:currentValue,limit:limit}"
    $usageJson = & az vm list-usage --location $Location --query $usageQuery --output json
    if ($LASTEXITCODE -ne 0 -or -not $usageJson) {
        throw "Failed to query quota usage for location '$Location'."
    }

    $usage = $usageJson | ConvertFrom-Json
    $regional = $usage | Where-Object { $_.value -eq "cores" } | Select-Object -First 1
    Assert-VcpuQuotaHeadroom -Usage $regional -RequiredCores $requiredCores -QuotaLabel "regional vCPU"

    if ($familyQuotaKey) {
        $family = $usage | Where-Object { $_.value -eq $familyQuotaKey } | Select-Object -First 1
        if ($family) {
            Assert-VcpuQuotaHeadroom -Usage $family -RequiredCores $requiredCores -QuotaLabel "family vCPU ($familyQuotaKey)"
        }
    }

    Write-Host "  Preflight: quota is sufficient (needs $requiredCores vCPUs)." -ForegroundColor Green
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

$Profiles = [ordered]@{
    win11 = @{ label = "Windows 11 24H2 Pro  (win11-24h2-pro)"; publisher = "MicrosoftWindowsDesktop"; offer = "Windows-11"; sku = "win11-24h2-pro"; version = "latest" }
    win10 = @{ label = "Windows 10 22H2 Pro  (win10-22h2-pro-g2)"; publisher = "MicrosoftWindowsDesktop"; offer = "Windows-10"; sku = "win10-22h2-pro-g2"; version = "latest" }
    win19 = @{ label = "Windows Server 2019  (2019-datacenter-gensecond)"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2019-datacenter-gensecond"; version = "latest" }
    win22 = @{ label = "Windows Server 2022  (2022-datacenter-g2)"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2022-datacenter-g2"; version = "latest" }
    win25 = @{ label = "Windows Server 2025  (2025-datacenter-g2)"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2025-datacenter-g2"; version = "latest" }
}

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |             VM  Deploy               |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan

if (-not $OsVersion) {
    $labels = $Profiles.Keys | ForEach-Object { $Profiles[$_].label }
    $picked = Select-Option -Prompt "Select OS version:" -Options $labels -Default 0
    $OsVersion = $Profiles.Keys | Where-Object { $Profiles[$_].label -eq $picked } | Select-Object -First 1
}

if (-not $Action) {
    $Action = Select-Option -Prompt "Select action:" -Options @("plan", "apply", "destroy") -Default 0
}

if (-not $VmSize -and $Action -ne "destroy") {
    $vmSizeChoice = Select-Option -Prompt "Select VM size:" -Options @("D4s_v3  - Standard_D4s_v3", "D8s_v3  - Standard_D8s_v3") -Default -1
    if ($vmSizeChoice -like "D8s_v3*") {
        $VmSize = "Standard_D8s_v3"
    } else {
        $VmSize = "Standard_D4s_v3"
    }
}

if (-not $AutoApprove -and $Action -ne "plan") {
    $choice = Select-Option -Prompt "Auto-approve?" -Options @("No  - pause and review before applying", "Yes - apply immediately") -Default 0
    $AutoApprove = $choice -like "Yes*"
}

$img = $Profiles[$OsVersion]

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |              Summary                 |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ("  |  Target       : {0,-22}|" -f "vm") -ForegroundColor White
Write-Host ("  |  Action       : {0,-22}|" -f $Action) -ForegroundColor White
Write-Host ("  |  Auto-approve : {0,-22}|" -f ([string]$AutoApprove)) -ForegroundColor White
Write-Host ("  |  OS           : {0,-22}|" -f $OsVersion) -ForegroundColor White
Write-Host ("  |  SKU          : {0,-22}|" -f $img.sku) -ForegroundColor White
Write-Host ("  |  VM size      : {0,-22}|" -f $VmSize) -ForegroundColor White
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ""

if ($Action -eq "destroy" -and -not $AutoApprove) {
    $ok = $Host.UI.PromptForChoice("  Confirm destroy", "  This will DELETE all VM resources. Continue?", @("&Yes", "&No"), 1)
    if ($ok -ne 0) {
        Write-Host "  Cancelled.`n"
        exit 0
    }
    Write-Host ""
}

$tfArgs = @(
    $Action,
    "-var", "vm_image_publisher=$($img.publisher)",
    "-var", "vm_image_offer=$($img.offer)",
    "-var", "vm_image_sku=$($img.sku)",
    "-var", "vm_image_version=$($img.version)"
)

if ($VmSize) {
    $tfArgs += @("-var", "vm_size=$VmSize")
}

if ($AutoApprove -and $Action -ne "plan") {
    $tfArgs += "-auto-approve"
}

Push-Location $PSScriptRoot
try {
    Assert-TerraformInstalled
    Ensure-AzLogin

    $location = Get-TerraformLocation
    Test-AzVmImageSkuAvailable -Image $img -Location $location -Action $Action
    Test-AzVmQuotaAvailable -Location $location -VmSize $VmSize -Action $Action

    & terraform init -input=false
    if ($LASTEXITCODE -ne 0) {
        throw "terraform init exited with code $LASTEXITCODE"
    }

    & terraform @tfArgs
    if ($LASTEXITCODE -ne 0) {
        throw "terraform $Action exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
