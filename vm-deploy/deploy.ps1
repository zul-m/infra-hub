<#
.SYNOPSIS
    Root deployment dispatcher for vm-deploy.

.DESCRIPTION
    Keeps deployment entrypoint at vm-deploy root and dispatches to:
    - vm/deploy-vm.ps1
    - aks/deploy-aks.ps1

.PARAMETER Target
    Deployment target: vm | aks.
#>
[CmdletBinding()]
param(
    [ValidateSet("vm", "aks")]
    [string]$Target,

    [ValidateSet("win10", "win11", "win19", "win22", "win25")]
    [string]$OsVersion,

    [ValidateSet("plan", "apply", "destroy")]
    [string]$Action,

    [ValidateSet("Standard_D4s_v3", "Standard_D8s_v3")]
    [string]$VmSize,

    [switch]$AutoApprove,

    [switch]$BootstrapAks,

    [string]$AksResourceGroup,
    [string]$AksClusterName,
    [string]$AksLocation,
    [string]$AksKubernetesVersion,
    [string]$AksLogAnalyticsWorkspaceName,
    [int]$AksLinuxNodeCount,
    [string]$AksLinuxNodeVmSize,
    [int]$AksWindowsNodeCount,
    [string]$AksWindowsNodeVmSize,
    [string]$AksWindowsNodePoolName,
    [string]$AksWindowsAdminUsername,
    [string]$AksWindowsAdminPassword,
    [string]$AksRegistryServer,
    [string]$AksRegistryUsername,
    [string]$AksRegistryPassword,
    [string]$AksRegistrySecretName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |         Infra  Deploy  Tool          |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan

if (-not $Target) {
    if ($BootstrapAks) {
        $Target = "aks"
    } else {
        $hasAksParams = @($PSBoundParameters.Keys | Where-Object { $_ -like "Aks*" }).Count -gt 0
        $hasVmParams = $PSBoundParameters.ContainsKey("OsVersion") -or $PSBoundParameters.ContainsKey("VmSize")
        if ($hasAksParams) {
            $Target = "aks"
        } elseif ($hasVmParams) {
            $Target = "vm"
        }
    }
}

if (-not $Target) {
    $targetChoice = Select-Option -Prompt "Select deployment target:" -Options @("VM", "AKS") -Default 0
    $Target = if ($targetChoice -eq "AKS") { "aks" } else { "vm" }
}

$vmScript = Join-Path $PSScriptRoot "vm\deploy-vm.ps1"
$aksScript = Join-Path $PSScriptRoot "aks\deploy-aks.ps1"

if ($Target -eq "vm") {
    if (-not (Test-Path $vmScript)) {
        throw "VM deployment script not found: $vmScript"
    }

    $vmParams = @{}
    if ($PSBoundParameters.ContainsKey("OsVersion")) { $vmParams.OsVersion = $OsVersion }
    if ($PSBoundParameters.ContainsKey("Action")) { $vmParams.Action = $Action }
    if ($PSBoundParameters.ContainsKey("VmSize")) { $vmParams.VmSize = $VmSize }
    if ($AutoApprove) { $vmParams.AutoApprove = $true }

    & $vmScript @vmParams
    exit $LASTEXITCODE
}

if (-not (Test-Path $aksScript)) {
    throw "AKS deployment script not found: $aksScript"
}

$aksParams = @{}
if ($PSBoundParameters.ContainsKey("Action")) {
    if ($Action -eq "plan") {
        throw "Action 'plan' is only valid for Target 'vm'."
    }
    $aksParams.Action = $Action
} elseif ($BootstrapAks) {
    $aksParams.Action = "apply"
}
if ($AutoApprove) { $aksParams.AutoApprove = $true }

if ($PSBoundParameters.ContainsKey("AksResourceGroup")) { $aksParams.AksResourceGroup = $AksResourceGroup }
if ($PSBoundParameters.ContainsKey("AksClusterName")) { $aksParams.AksClusterName = $AksClusterName }
if ($PSBoundParameters.ContainsKey("AksLocation")) { $aksParams.AksLocation = $AksLocation }
if ($PSBoundParameters.ContainsKey("AksKubernetesVersion")) { $aksParams.AksKubernetesVersion = $AksKubernetesVersion }
if ($PSBoundParameters.ContainsKey("AksLogAnalyticsWorkspaceName")) { $aksParams.AksLogAnalyticsWorkspaceName = $AksLogAnalyticsWorkspaceName }
if ($PSBoundParameters.ContainsKey("AksLinuxNodeCount")) { $aksParams.AksLinuxNodeCount = $AksLinuxNodeCount }
if ($PSBoundParameters.ContainsKey("AksLinuxNodeVmSize")) { $aksParams.AksLinuxNodeVmSize = $AksLinuxNodeVmSize }
if ($PSBoundParameters.ContainsKey("AksWindowsNodeCount")) { $aksParams.AksWindowsNodeCount = $AksWindowsNodeCount }
if ($PSBoundParameters.ContainsKey("AksWindowsNodeVmSize")) { $aksParams.AksWindowsNodeVmSize = $AksWindowsNodeVmSize }
if ($PSBoundParameters.ContainsKey("AksWindowsNodePoolName")) { $aksParams.AksWindowsNodePoolName = $AksWindowsNodePoolName }
if ($PSBoundParameters.ContainsKey("AksWindowsAdminUsername")) { $aksParams.AksWindowsAdminUsername = $AksWindowsAdminUsername }
if ($PSBoundParameters.ContainsKey("AksWindowsAdminPassword")) { $aksParams.AksWindowsAdminPassword = $AksWindowsAdminPassword }
if ($PSBoundParameters.ContainsKey("AksRegistryServer")) { $aksParams.AksRegistryServer = $AksRegistryServer }
if ($PSBoundParameters.ContainsKey("AksRegistryUsername")) { $aksParams.AksRegistryUsername = $AksRegistryUsername }
if ($PSBoundParameters.ContainsKey("AksRegistryPassword")) { $aksParams.AksRegistryPassword = $AksRegistryPassword }
if ($PSBoundParameters.ContainsKey("AksRegistrySecretName")) { $aksParams.AksRegistrySecretName = $AksRegistrySecretName }

& $aksScript @aksParams
exit $LASTEXITCODE
