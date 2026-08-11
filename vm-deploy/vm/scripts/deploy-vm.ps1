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

.PARAMETER ResourceGroupName
    Resource group name to target for destroy. In interactive mode this is prompted only for destroy.

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

    [string]$ResourceGroupName,

    [ValidateSet("Standard_D4s_v3", "Standard_D8s_v3")]
    [string]$VmSize,

    [switch]$AutoApprove,

    [switch]$ConfirmDestroy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
trap [System.OperationCanceledException] {
    return
}

$script:TerraformWorkingDirectory = Split-Path $PSScriptRoot -Parent

function Test-IsNonInteractiveSession {
    if ($env:TF_IN_AUTOMATION -eq "1") {
        return $true
    }

    if ($env:CI -and $env:CI.ToString().Trim().ToLowerInvariant() -eq "true") {
        return $true
    }

    if (-not [Environment]::UserInteractive) {
        return $true
    }

    try {
        return [Console]::IsInputRedirected -or [Console]::IsOutputRedirected
    } catch {
        return $true
    }
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
        [pscustomobject]$Summary,
        [string[]]$DestroyedDisplayResources
    )

    Write-Host ""
    Write-Host "  Terraform completed." -ForegroundColor Green
    Write-Host ("  Action: {0}" -f $Summary.Action) -ForegroundColor Green
    Write-Host ("  Changes: +{0}  ~{1}  -{2}" -f $Summary.AddedCount, $Summary.ChangedCount, $Summary.DestroyedCount) -ForegroundColor Green

    Write-TerraformResourceList -Title "Provisioned" -Resources $Summary.CreatedResources
    Write-TerraformResourceList -Title "Updated" -Resources $Summary.ChangedResources
    if ($Summary.Action -eq "destroy" -and $DestroyedDisplayResources) {
        Write-TerraformResourceList -Title "Destroyed" -Resources $DestroyedDisplayResources
    } else {
        Write-TerraformResourceList -Title "Destroyed" -Resources $Summary.DestroyedResources
    }
}

function Get-TerraformDestroyTargets {
    param(
        [string]$StdOut,
        [string]$StdErr
    )

    $combined = @($StdOut, $StdErr) -join "`n"
    $entries = New-Object System.Collections.Generic.List[object]
    $currentDestroyedResource = $null

    foreach ($line in ($combined -split "`r?`n")) {
        if ($line -match '^\s*#\s+(?<resource>\S+)\s+will be destroyed') {
            $currentDestroyedResource = $matches.resource
            continue
        }

        if ($line -match '^\s*#\s+') {
            $currentDestroyedResource = $null
            continue
        }

        if (-not $currentDestroyedResource) {
            continue
        }

        if ($line -match '^\s*[-+~]?\s*(?<attr>name|resource_group_name|cluster_name|node_resource_group|vm_name)\s*=\s*"(?<value>[^"]+)"') {
            $entries.Add([pscustomobject]@{
                Resource  = $currentDestroyedResource
                Attribute = $matches.attr
                Value     = $matches.value
            })
        }
    }

    $uniqueEntries = @($entries | Group-Object Resource, Attribute, Value | ForEach-Object { $_.Group[0] })
    $uniqueValues = @($uniqueEntries | Select-Object -ExpandProperty Value -Unique)

    return [pscustomobject]@{
        Entries = $uniqueEntries
        Values  = $uniqueValues
    }
}

function Get-TerraformDestroyedDisplayResources {
    param(
        [pscustomobject]$Targets,
        [string[]]$FallbackResources
    )

    if (-not $Targets -or -not $Targets.Entries) {
        return @($FallbackResources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $entries = @($Targets.Entries | Where-Object { $_.Value })
    $display = New-Object System.Collections.Generic.List[string]

    function Add-DisplayValue {
        param([string]$Label, [string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $item = "{0}: {1}" -f $Label, $Value.Trim()
        if (-not $display.Contains($item)) {
            $display.Add($item)
        }
    }

    $rg = @($entries |
        Where-Object { $_.Resource -match '^azurerm_resource_group\.' -and $_.Attribute -eq 'name' } |
        Select-Object -ExpandProperty Value -First 1)
    Add-DisplayValue -Label "Resource group" -Value $rg

    $vmName = @($entries |
        Where-Object { $_.Resource -match '^azurerm_windows_virtual_machine\.' -and $_.Attribute -eq 'name' } |
        Select-Object -ExpandProperty Value -First 1)
    Add-DisplayValue -Label "VM" -Value $vmName

    if ($display.Count -eq 0) {
        foreach ($value in ($entries | Select-Object -ExpandProperty Value -Unique)) {
            Add-DisplayValue -Label "Value" -Value $value
        }
    }

    if ($display.Count -eq 0) {
        return @($FallbackResources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    return @($display)
}

function Get-LiveAnsibleTaskFromLog {
    param(
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path $LogPath)) {
        return $null
    }

    $taskLine = Get-Content -Path $LogPath -Tail 120 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '(?i)^TASK \[(?<task>[^\]]+)\]' } |
        Select-Object -Last 1

    if (-not $taskLine) {
        return $null
    }

    if ($taskLine -match '(?i)^TASK \[(?<task>[^\]]+)\]') {
        return ("[Ansible] {0}" -f $matches.task.Trim())
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
    $liveProvisionLog = Join-Path (Get-Location).Path "terraform-provision.log"

    # Prevent stale Ansible task labels from a previous run.
    if ($DisplayName -eq "apply" -and (Test-Path $liveProvisionLog)) {
        Clear-Content -Path $liveProvisionLog -ErrorAction SilentlyContinue
    }

    $heartbeatTicks = 0
    while (-not $process.WaitForExit(30000)) {
        $heartbeatTicks++
        $elapsedSeconds = $heartbeatTicks * 30

        $stageLabel = $null
        if ($DisplayName -eq "apply") {
            $stageLabel = Get-LiveAnsibleTaskFromLog -LogPath $liveProvisionLog
        }

        if ($stageLabel) {
            Write-Host ("  Terraform {0}: {1}... [{2}s elapsed]" -f $DisplayName, $stageLabel, $elapsedSeconds) -ForegroundColor DarkGray
        } else {
            Write-Host ("  Terraform {0} in progress... [{1}s elapsed]" -f $DisplayName, $elapsedSeconds) -ForegroundColor DarkGray
        }
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

    $tfvarsPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "terraform.tfvars"
    if (-not (Test-Path $tfvarsPath)) {
        throw "terraform.tfvars was not found at '$tfvarsPath'. Copy vm-deploy/terraform.tfvars.example to vm-deploy/terraform.tfvars."
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

function Get-TerraformStateResourceGroupName {
    param(
        [string]$ResourceAddress
    )

    $stateResources = @(& terraform "-chdir=$script:TerraformWorkingDirectory" state list 2>$null)
    if ($LASTEXITCODE -ne 0 -or $stateResources.Count -eq 0) {
        throw "No Terraform state resources were found. Destroy is blocked until a managed environment exists in this state."
    }

    if ($stateResources -notcontains $ResourceAddress) {
        throw "Terraform state does not contain '$ResourceAddress'. Destroy is blocked because the managed resource group cannot be resolved from state."
    }

    $stateShow = @(& terraform "-chdir=$script:TerraformWorkingDirectory" state show $ResourceAddress 2>$null)
    if ($LASTEXITCODE -ne 0 -or $stateShow.Count -eq 0) {
        throw "Failed to read Terraform state for '$ResourceAddress'. Destroy is blocked."
    }

    foreach ($line in $stateShow) {
        if ($line -match '^\s*name\s*=\s*"(?<name>[^"]+)"\s*$') {
            return $matches.name
        }
    }

    throw "Terraform state for '$ResourceAddress' does not expose a readable name attribute. Destroy is blocked."
}

function Assert-DestroyResourceGroupMatch {
    param(
        [string]$RequestedResourceGroup
    )

    if ([string]::IsNullOrWhiteSpace($RequestedResourceGroup)) {
        throw "Resource group name is required for destroy."
    }

    $stateResourceGroup = Get-TerraformStateResourceGroupName -ResourceAddress "azurerm_resource_group.main"
    if ($RequestedResourceGroup.Trim() -ine $stateResourceGroup.Trim()) {
        throw "Destroy blocked: requested resource group '$RequestedResourceGroup' does not match Terraform state resource group '$stateResourceGroup'."
    }

    Write-Host "  Destroy guard: resource group matches Terraform state." -ForegroundColor Green
}

function Get-LocalStateResourceGroupName {
    param(
        [string]$StatePath,
        [string]$ResourceName
    )

    if (-not (Test-Path $StatePath)) {
        return $null
    }

    $rawState = Get-Content -Path $StatePath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($rawState)) {
        return $null
    }

    try {
        $state = $rawState | ConvertFrom-Json
    } catch {
        return $null
    }

    $resource = $state.resources |
        Where-Object { $_.type -eq "azurerm_resource_group" -and $_.name -eq $ResourceName } |
        Select-Object -First 1

    if (-not $resource -or -not $resource.instances -or $resource.instances.Count -eq 0) {
        return $null
    }

    $instance = $resource.instances | Select-Object -First 1
    if ($instance.attributes -and $instance.attributes.name) {
        return [string]$instance.attributes.name
    }

    return $null
}

function Assert-DestroyResourceGroupMatchEarly {
    param(
        [string]$RequestedResourceGroup,
        [switch]$AllowPrompt
    )

    $statePath = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform.tfstate"
    $stateResourceGroup = Get-LocalStateResourceGroupName -StatePath $statePath -ResourceName "main"

    $candidate = if ([string]::IsNullOrWhiteSpace($RequestedResourceGroup)) { "" } else { $RequestedResourceGroup.Trim() }

    if ([string]::IsNullOrWhiteSpace($stateResourceGroup)) {
        Write-Host "  Destroy guard: local state RG not resolvable yet; full Terraform state check will run before destroy." -ForegroundColor DarkYellow
        return $candidate
    }

    while ($true) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -ieq $stateResourceGroup.Trim()) {
            Write-Host "  Destroy guard: resource group matches local Terraform state." -ForegroundColor Green
            return $stateResourceGroup.Trim()
        }

        if (-not $AllowPrompt) {
            throw "Destroy blocked: in non-interactive mode the requested resource group '$RequestedResourceGroup' does not match local Terraform state resource group '$stateResourceGroup'. Pass -ResourceGroupName '$stateResourceGroup' and -ConfirmDestroy."
        }

        Write-Host "  Destroy guard: entered resource group does not match Terraform state." -ForegroundColor Red
        $candidate = (Read-Host "  Enter resource group name to destroy (blank to cancel)").Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            Write-Host "  Cancelled.`n"
            throw [System.OperationCanceledException]::new("VM destroy cancelled due to resource group mismatch.")
        }
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
            Escape {
                Write-Host "`n  Cancelled.`n"
                throw [System.OperationCanceledException]::new("VM deployment selection cancelled by user.")
            }
        }
    }
}

$Profiles = [ordered]@{
    win11 = @{ label = "Windows 11 24H2 Pro"; publisher = "MicrosoftWindowsDesktop"; offer = "Windows-11"; sku = "win11-24h2-pro"; version = "latest" }
    win10 = @{ label = "Windows 10 22H2 Pro"; publisher = "MicrosoftWindowsDesktop"; offer = "Windows-10"; sku = "win10-22h2-pro-g2"; version = "latest" }
    win19 = @{ label = "Windows Server 2019"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2019-datacenter-gensecond"; version = "latest" }
    win22 = @{ label = "Windows Server 2022"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2022-datacenter-g2"; version = "latest" }
    win25 = @{ label = "Windows Server 2025"; publisher = "MicrosoftWindowsServer"; offer = "WindowsServer"; sku = "2025-datacenter-g2"; version = "latest" }
}

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |             VM  Deploy               |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan

if (-not $Action) {
    $Action = Select-Option -Prompt "Select action:" -Options @("plan", "apply", "destroy") -Default 0
}

if ($Action -eq "destroy" -and $AutoApprove) {
    Write-Host "  Auto-approve input ignored for destroy; a destroy preview and explicit confirmation are always required." -ForegroundColor DarkYellow
    $AutoApprove = $false
}

$isNonInteractive = Test-IsNonInteractiveSession
if ($Action -eq "destroy" -and $isNonInteractive -and -not $ConfirmDestroy) {
    throw "Destroy requires explicit non-interactive confirmation. Re-run with -ConfirmDestroy and -ResourceGroupName <name>."
}

if ($Action -eq "destroy" -and -not $ResourceGroupName) {
    if ($isNonInteractive) {
        throw "ResourceGroupName is required for destroy in non-interactive mode. Pass -ResourceGroupName <name> with -ConfirmDestroy."
    }

    Write-Host ""
    $ResourceGroupName = Read-Host "  Enter resource group name to destroy"
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "Resource group name is required for destroy."
    }
}

if ($Action -eq "destroy") {
    $ResourceGroupName = Assert-DestroyResourceGroupMatchEarly -RequestedResourceGroup $ResourceGroupName -AllowPrompt:(-not $isNonInteractive -and -not $ConfirmDestroy)
}

if (-not $OsVersion) {
    if ($Action -eq "destroy") {
        # OS image inputs are not meaningful for destroy; use a stable default profile.
        $OsVersion = "win22"
    } else {
        $labels = $Profiles.Keys | ForEach-Object { $Profiles[$_].label }
        $picked = Select-Option -Prompt "Select OS version:" -Options $labels -Default 0
        $OsVersion = $Profiles.Keys | Where-Object { $Profiles[$_].label -eq $picked } | Select-Object -First 1
    }
}

if (-not $VmSize -and $Action -ne "destroy") {
    $vmSizeChoice = Select-Option -Prompt "Select VM size:" -Options @("D4s_v3  - Standard_D4s_v3", "D8s_v3  - Standard_D8s_v3") -Default -1
    if ($vmSizeChoice -like "D8s_v3*") {
        $VmSize = "Standard_D8s_v3"
    } else {
        $VmSize = "Standard_D4s_v3"
    }
}

if ($Action -eq "apply" -and -not $AutoApprove) {
    $choice = Select-Option -Prompt "Auto-approve?" -Options @("No  - pause and review before applying", "Yes - apply immediately") -Default 0
    $AutoApprove = $choice -like "Yes*"
}

$img = $Profiles[$OsVersion]

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |              Summary                 |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
$autoApproveDisplay = if ($Action -eq "destroy") { "N/A (preview + confirm)" } else { [string]$AutoApprove }
Write-Host ("  |  Target       : {0,-22}|" -f "vm") -ForegroundColor White
Write-Host ("  |  Action       : {0,-22}|" -f $Action) -ForegroundColor White
Write-Host ("  |  Auto-approve : {0,-22}|" -f $autoApproveDisplay) -ForegroundColor White
if ($Action -eq "destroy") {
    Write-Host ("  |  Resource grp : {0,-22}|" -f $ResourceGroupName) -ForegroundColor White
} else {
    Write-Host ("  |  OS           : {0,-22}|" -f $OsVersion) -ForegroundColor White
    Write-Host ("  |  SKU          : {0,-22}|" -f $img.sku) -ForegroundColor White
    Write-Host ("  |  VM size      : {0,-22}|" -f $VmSize) -ForegroundColor White
}
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ""

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

if ($Action -eq "apply" -and $AutoApprove) {
    $tfArgs += "-auto-approve"
}

$rootTfvarsPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "terraform.tfvars"
if (-not (Test-Path $rootTfvarsPath)) {
    throw "Root terraform.tfvars not found at '$rootTfvarsPath'. Copy vm-deploy/terraform.tfvars.example to vm-deploy/terraform.tfvars."
}
$tfArgs = @($tfArgs[0], "-var-file=$rootTfvarsPath") + $tfArgs[1..($tfArgs.Count - 1)]

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

    if ($Action -eq "destroy") {
        Assert-DestroyResourceGroupMatch -RequestedResourceGroup $ResourceGroupName

        $destroyPreviewArgs = @()
        $replacedAction = $false
        foreach ($arg in $tfArgs) {
            if (-not $replacedAction -and $arg -eq "destroy") {
                $destroyPreviewArgs += @("plan", "-destroy")
                $replacedAction = $true
                continue
            }
            $destroyPreviewArgs += $arg
        }

        if (-not $replacedAction) {
            throw "Failed to prepare destroy preview arguments."
        }

        $previewResult = Invoke-TerraformMinimal -Arguments $destroyPreviewArgs -DisplayName "destroy-preview"
        if ($previewResult.ExitCode -ne 0) {
            if ($previewResult.StdErr) {
                Write-Host ""
                Write-Host "  Error Output:" -ForegroundColor Red
                Write-Host $previewResult.StdErr -ForegroundColor Red
            }
            if ($previewResult.StdOut) {
                Write-Host ""
                Write-Host "  Output:" -ForegroundColor Yellow
                Write-Host $previewResult.StdOut -ForegroundColor Yellow
            }
            throw "terraform plan -destroy preview exited with code $($previewResult.ExitCode)"
        }

        Write-Host ""
        Write-Host "  Destroy preview summary:" -ForegroundColor Yellow
        Write-Host ("  Changes: +{0}  ~{1}  -{2}" -f $previewResult.Summary.AddedCount, $previewResult.Summary.ChangedCount, $previewResult.Summary.DestroyedCount) -ForegroundColor Yellow
        $destroyTargets = Get-TerraformDestroyTargets -StdOut $previewResult.StdOut -StdErr $previewResult.StdErr
        $previewDestroyedDisplay = Get-TerraformDestroyedDisplayResources -Targets $destroyTargets -FallbackResources $previewResult.Summary.DestroyedResources
        Write-TerraformResourceList -Title "Destroyed" -Resources $previewDestroyedDisplay -MaxItems 30
        if ($previewResult.Summary.DestroyedCount -eq 0) {
            Write-Host "  No resources are planned for destroy." -ForegroundColor DarkYellow
        }

        if ($ConfirmDestroy) {
            Write-Host "  Destroy confirmation override detected (-ConfirmDestroy)." -ForegroundColor DarkYellow
        } else {
            $vmNameFromPreview = @($destroyTargets.Entries |
                Where-Object { $_.Resource -match '^azurerm_windows_virtual_machine\.' -and $_.Attribute -eq 'name' } |
                Select-Object -ExpandProperty Value -First 1)
            $displayVmName = if ($vmNameFromPreview) { $vmNameFromPreview } else { "(from state)" }
            $confirmMessage = "  This will DELETE VM '$displayVmName' and resource group '$ResourceGroupName'. Continue?"
            $ok = $Host.UI.PromptForChoice("  Confirm destroy", $confirmMessage, @("&Yes", "&No"), 1)
            if ($ok -ne 0) {
                Write-Host "  Cancelled.`n"
                throw [System.OperationCanceledException]::new("VM destroy cancelled by user.")
            }
            Write-Host ""
        }

        $tfArgs += "-auto-approve"
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

    $destroyedDisplayForSummary = $null
    if ($Action -eq "destroy") {
        $destroyedTargets = Get-TerraformDestroyTargets -StdOut $actionResult.StdOut -StdErr $actionResult.StdErr
        $destroyedDisplayForSummary = Get-TerraformDestroyedDisplayResources -Targets $destroyedTargets -FallbackResources $actionResult.Summary.DestroyedResources
    }
    Write-TerraformSummary -Summary $actionResult.Summary -DestroyedDisplayResources $destroyedDisplayForSummary
} finally {
    Pop-Location
}
