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
trap [System.OperationCanceledException] {
    return
}

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

function Get-TerraformResourceSummary {
    param(
        [string]$Action,
        [string]$StdOut,
        [string]$StdErr
    )

    $combined = @($StdOut, $StdErr) -join "`n"
    $created = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    $destroyed = New-Object System.Collections.Generic.List[string]

    $lines = $combined -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -match '^\s*#\s+(?<resource>\S+)\s+will be created') {
            $created.Add($matches.resource)
            continue
        }
        if ($line -match '^\s*#\s+(?<resource>\S+)\s+will be updated in-place') {
            $changed.Add($matches.resource)
            continue
        }
        if ($line -match '^\s*#\s+(?<resource>\S+)\s+will be destroyed') {
            $destroyed.Add($matches.resource)
            continue
        }
        if ($line -match '^(?<resource>[^:]+):\s+Creation complete') {
            $created.Add($matches.resource.Trim())
            continue
        }
        if ($line -match '^(?<resource>[^:]+):\s+Modifications complete') {
            $changed.Add($matches.resource.Trim())
            continue
        }
        if ($line -match '^(?<resource>[^:]+):\s+Destruction complete') {
            $destroyed.Add($matches.resource.Trim())
            continue
        }
    }

    $created = @($created | Select-Object -Unique)
    $changed = @($changed | Select-Object -Unique)
    $destroyed = @($destroyed | Select-Object -Unique)

    $add = 0
    $chg = 0
    $des = 0

    $planMatch = [regex]::Match($combined, 'Plan:\s+(?<add>\d+)\s+to add,\s+(?<change>\d+)\s+to change,\s+(?<destroy>\d+)\s+to destroy\.')
    $applyMatch = [regex]::Match($combined, 'Apply complete!\s+Resources:\s+(?<add>\d+)\s+added,\s+(?<change>\d+)\s+changed,\s+(?<destroy>\d+)\s+destroyed\.')

    if ($planMatch.Success) {
        $add = [int]$planMatch.Groups['add'].Value
        $chg = [int]$planMatch.Groups['change'].Value
        $des = [int]$planMatch.Groups['destroy'].Value
    } elseif ($applyMatch.Success) {
        $add = [int]$applyMatch.Groups['add'].Value
        $chg = [int]$applyMatch.Groups['change'].Value
        $des = [int]$applyMatch.Groups['destroy'].Value
    } else {
        $add = $created.Count
        $chg = $changed.Count
        $des = $destroyed.Count
    }

    return [pscustomobject]@{
        Action             = $Action
        AddedCount         = $add
        ChangedCount       = $chg
        DestroyedCount     = $des
        CreatedResources   = @($created)
        ChangedResources   = @($changed)
        DestroyedResources = @($destroyed)
    }
}

function Write-TerraformResourceList {
    param(
        [string]$Title,
        [string[]]$Resources,
        [int]$MaxItems = 12
    )

    $list = @($Resources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($list.Count -eq 0) {
        return
    }

    Write-Host ("  {0}:" -f $Title) -ForegroundColor DarkGray
    $display = $list | Select-Object -First $MaxItems
    foreach ($resource in $display) {
        Write-Host ("    - {0}" -f $resource) -ForegroundColor Gray
    }

    if ($list.Count -gt $MaxItems) {
        $remaining = $list.Count - $MaxItems
        Write-Host ("    ... and {0} more" -f $remaining) -ForegroundColor Gray
    }
}

function Write-TerraformSummary {
    param(
        [pscustomobject]$Summary
    )

    Write-Host ""
    Write-Host "  Terraform completed." -ForegroundColor Green
    Write-Host ("  Action: {0}" -f $Summary.Action) -ForegroundColor Green
    Write-Host ("  Changes: +{0}  ~{1}  -{2}" -f $Summary.AddedCount, $Summary.ChangedCount, $Summary.DestroyedCount) -ForegroundColor Green

    Write-TerraformResourceList -Title "Provisioned" -Resources $Summary.CreatedResources
    Write-TerraformResourceList -Title "Updated" -Resources $Summary.ChangedResources
    Write-TerraformResourceList -Title "Destroyed" -Resources $Summary.DestroyedResources
}

function Get-TerraformStageLabel {
    param(
        [string]$ResourceName
    )

    if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        return "Applying infrastructure changes"
    }

    switch -Wildcard ($ResourceName) {
        "azurerm_resource_group.*" { return "Creating resource group" }
        "azurerm_virtual_network.*" { return "Configuring virtual network" }
        "azurerm_subnet.*" { return "Configuring virtual network" }
        "azurerm_network_security_group.*" { return "Configuring network security" }
        "azurerm_network_security_rule.*" { return "Configuring network security" }
        "azurerm_subnet_network_security_group_association.*" { return "Attaching network security rules" }
        "azurerm_public_ip.*" { return "Allocating public IP" }
        "azurerm_network_interface.*" { return "Configuring VM network interface" }
        "azurerm_windows_virtual_machine.*" { return "Creating Windows virtual machine" }
        "azurerm_virtual_machine_extension.winrm_https" { return "Configuring WinRM over HTTPS" }
        "azurerm_dev_test_global_vm_shutdown_schedule.*" { return "Configuring auto-shutdown schedule" }
        "terraform_data.install_applications" { return "Installing applications (SQL Server, SSMS, Azure CLI, Notepad++)" }
        default { return "Applying infrastructure changes" }
    }
}

function Get-LocalExecStageLabel {
    param(
        [string]$ResourceName,
        [string]$Message
    )

    if ($ResourceName -ne "terraform_data.install_applications") {
        return $null
    }

    if ($Message -match "ANSIBLE PROVISIONING STARTED") {
        return "Installing applications (SQL Server, SSMS, Azure CLI, Notepad++)"
    }
    if ($Message -match "Installing Ansible collections") {
        return "Preparing Ansible collections"
    }
    if ($Message -match "Running playbook against") {
        return "Applying application playbook"
    }
    if ($Message -match "Provisioning attempt") {
        return "Provisioning applications"
    }
    if ($Message -match "ANSIBLE PROVISIONING COMPLETED SUCCESSFULLY") {
        return "Application provisioning completed"
    }

    return $null
}

function Invoke-TerraformMinimal {
    param(
        [string[]]$Arguments,
        [string]$DisplayName
    )

    Write-Host "  Terraform: $DisplayName" -ForegroundColor Cyan

    $terraformPath = (Get-Command terraform -ErrorAction Stop).Source
    $allArgs = @($Arguments + @("-no-color"))
    $quotedArgs = $allArgs | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\\"') + '"'
        } else {
            $_
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $terraformPath
    $startInfo.Arguments = ($quotedArgs -join " ")
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["TF_IN_AUTOMATION"] = "1"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $heartbeatTicks = 0
    while (-not $process.WaitForExit(30000)) {
        $heartbeatTicks++
        $elapsedSeconds = $heartbeatTicks * 30
        Write-Host ("  Terraform still running... [{0}s elapsed]" -f $elapsedSeconds) -ForegroundColor DarkGray
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $summary = Get-TerraformResourceSummary -Action $DisplayName -StdOut $stdout -StdErr $stderr
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Summary  = $summary
    }
}

function Get-TfvarsQuotedValue {
    param(
        [string]$Key,
        [string]$Guidance
    )

    $tfvarsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform.tfvars"
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
            Escape {
                Write-Host "`n  Cancelled.`n"
                throw [System.OperationCanceledException]::new("VM deployment selection cancelled by user.")
            }
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
        throw [System.OperationCanceledException]::new("VM destroy cancelled by user.")
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

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    Assert-TerraformInstalled
    Ensure-AzLogin

    $location = Get-TerraformLocation
    Test-AzVmImageSkuAvailable -Image $img -Location $location -Action $Action
    Test-AzVmQuotaAvailable -Location $location -VmSize $VmSize -Action $Action

    $initResult = Invoke-TerraformMinimal -Arguments @("init", "-input=false") -DisplayName "init"
    if ($initResult.ExitCode -ne 0) {
        if ($initResult.StdErr) {
            Write-Host ""
            Write-Host "  Error Output:" -ForegroundColor Red
            Write-Host $initResult.StdErr -ForegroundColor Red
        }
        throw "terraform init exited with code $($initResult.ExitCode)"
    }

    $actionResult = Invoke-TerraformMinimal -Arguments $tfArgs -DisplayName $Action
    if ($actionResult.ExitCode -ne 0) {
        if ($actionResult.StdErr) {
            Write-Host ""
            Write-Host "  Error Output:" -ForegroundColor Red
            Write-Host $actionResult.StdErr -ForegroundColor Red
        }
        if ($actionResult.StdOut) {
            Write-Host ""
            Write-Host "  Output:" -ForegroundColor Yellow
            Write-Host $actionResult.StdOut -ForegroundColor Yellow
        }
        throw "terraform $Action exited with code $($actionResult.ExitCode)"
    }

    Write-TerraformSummary -Summary $actionResult.Summary
} finally {
    Pop-Location
}
