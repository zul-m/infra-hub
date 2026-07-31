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

    foreach ($line in ($combined -split "`r?`n")) {
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
    foreach ($resource in ($list | Select-Object -First $MaxItems)) {
        Write-Host ("    - {0}" -f $resource) -ForegroundColor Gray
    }

    if ($list.Count -gt $MaxItems) {
        Write-Host ("    ... and {0} more" -f ($list.Count - $MaxItems)) -ForegroundColor Gray
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

function Redact-TerraformOutput {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $redacted = [string]$Text

    $knownSecretValues = @(
        $env:TF_VAR_windows_admin_password,
        $env:TF_VAR_registry_password
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($secretValue in $knownSecretValues) {
        $redacted = [regex]::Replace($redacted, [regex]::Escape([string]$secretValue), '[REDACTED]')
    }

    $redacted = [regex]::Replace(
        $redacted,
        '(?im)(\b(?:password|passwd|secret|token|api[_-]?key|client[_-]?secret|connection[_-]?string|access[_-]?key|private[_-]?key)\b\s*[:=]\s*)([^\r\n]+)',
        '$1[REDACTED]'
    )

    $redacted = [regex]::Replace(
        $redacted,
        '(?im)("?(?:password|passwd|secret|token|api[_-]?key|client[_-]?secret|connection[_-]?string|access[_-]?key|private[_-]?key)"?\s*:\s*")([^"]+)("?)',
        '$1[REDACTED]$3'
    )

    return $redacted
}

function Throw-TerraformFailure {
    param(
        [string]$Phase,
        [pscustomobject]$Result
    )

    Write-Host "" -ForegroundColor Red
    Write-Host ("  Terraform {0} failed (exit code {1})." -f $Phase, $Result.ExitCode) -ForegroundColor Red

    $stdErr = if ($null -ne $Result.StdErr) { [string]$Result.StdErr } else { "" }
    $stdOut = if ($null -ne $Result.StdOut) { [string]$Result.StdOut } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
        Write-Host "" -ForegroundColor Red
        Write-Host "  --- Terraform STDERR ---" -ForegroundColor Red
        Write-Host (Redact-TerraformOutput -Text $stdErr) -ForegroundColor Red
    }

    if (-not [string]::IsNullOrWhiteSpace($stdOut)) {
        $outLines = @($stdOut -split "`r?`n")
        $tailCount = [Math]::Min(120, $outLines.Count)
        Write-Host "" -ForegroundColor Yellow
        Write-Host ("  --- Terraform STDOUT (last {0} lines) ---" -f $tailCount) -ForegroundColor Yellow
        if ($tailCount -gt 0) {
            Write-Host (Redact-TerraformOutput -Text (($outLines | Select-Object -Last $tailCount) -join "`n")) -ForegroundColor Yellow
        }
    }

    throw "terraform $Phase exited with code $($Result.ExitCode)"
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
        Write-Host ("  Terraform {0} in progress... [{1}s elapsed]" -f $DisplayName, $elapsedSeconds) -ForegroundColor DarkGray
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
            Escape {
                Write-Host "`n  Cancelled.`n"
                throw [System.OperationCanceledException]::new("AKS deployment selection cancelled by user.")
            }
        }
    }
}

function Get-DefaultAksLocation {
    $rootTfvarsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform.tfvars"
    if (-not (Test-Path $rootTfvarsPath)) {
        return $null
    }

    $match = Select-String -Path $rootTfvarsPath -Pattern '^\s*location\s*=\s*"([^"]+)"\s*$' | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value
}

$locationResolvedFromDefault = $false
if (-not $AksLocation) {
    $AksLocation = Get-DefaultAksLocation
    $locationResolvedFromDefault = -not [string]::IsNullOrWhiteSpace($AksLocation)
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
    $tfvarsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform.tfvars"
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
        throw [System.OperationCanceledException]::new("AKS destroy cancelled by user.")
    }
}

$rootTfvarsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform.tfvars"
if (-not (Test-Path $rootTfvarsPath)) {
    throw "Root terraform.tfvars not found at '$rootTfvarsPath'. Copy vm-deploy/terraform.tfvars.example to vm-deploy/terraform.tfvars."
}

$terraformArgs = @(
    $Action,
    "-var-file=$rootTfvarsPath"
)

if ($PSBoundParameters.ContainsKey("AksResourceGroup")) {
    $terraformArgs += @("-var", "resource_group_name=$AksResourceGroup")
}
if ($PSBoundParameters.ContainsKey("AksClusterName")) {
    $terraformArgs += @("-var", "cluster_name=$AksClusterName")
}
if ($PSBoundParameters.ContainsKey("AksLocation") -or $locationResolvedFromDefault) {
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
if ($PSBoundParameters.ContainsKey("AksWindowsAdminPassword")) {
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

    $initResult = Invoke-TerraformMinimal -Arguments @("init", "-input=false") -DisplayName "init"
    if ($initResult.ExitCode -ne 0) {
        Throw-TerraformFailure -Phase "init" -Result $initResult
    }

    $actionResult = Invoke-TerraformMinimal -Arguments $terraformArgs -DisplayName $Action
    if ($actionResult.ExitCode -ne 0) {
        Throw-TerraformFailure -Phase $Action -Result $actionResult
    }

    Write-TerraformSummary -Summary $actionResult.Summary

} finally {
    Remove-Item Env:TF_VAR_windows_admin_password -ErrorAction SilentlyContinue
    Remove-Item Env:TF_VAR_registry_password -ErrorAction SilentlyContinue
    Pop-Location
}
