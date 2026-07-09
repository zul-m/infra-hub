<#
.SYNOPSIS
    Interactive deployment tool for vm-deploy.

.DESCRIPTION
    Run with no arguments for the arrow-key menu.
    Pass parameters directly to skip the menu (useful for scripting).

.PARAMETER OsVersion
    OS profile: win11 | win10 | win19 | win22 | win25

.PARAMETER Action
    Terraform action: plan | apply | destroy

.PARAMETER AutoApprove
    Skip the Terraform confirmation prompt.

.EXAMPLE
    .\deploy.ps1                                          # full interactive menu
    .\deploy.ps1 -OsVersion win25                        # skips OS menu only
    .\deploy.ps1 -OsVersion win11 -Action plan
    .\deploy.ps1 -OsVersion win25 -Action apply -AutoApprove
#>
[CmdletBinding()]
param(
    [ValidateSet("win10", "win11", "win19", "win22", "win25")]
    [string]$OsVersion,

    [ValidateSet("plan", "apply", "destroy")]
    [string]$Action,

    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Azure CLI authentication preflight
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# OS image profiles
# ---------------------------------------------------------------------------
$Profiles = [ordered]@{
    win11 = @{ label = "Windows 11 23H2 Pro  (win11-23h2-pro)";      publisher = "MicrosoftWindowsDesktop"; offer = "Windows-11";    sku = "win11-23h2-pro";        version = "latest" }
    win10 = @{ label = "Windows 10 22H2 Pro  (win10-22h2-pro-g2)";   publisher = "MicrosoftWindowsDesktop"; offer = "Windows-10";    sku = "win10-22h2-pro-g2";     version = "latest" }
    win19 = @{ label = "Windows Server 2019  (2019-datacenter-gensecond)"; publisher = "MicrosoftWindowsServer";  offer = "WindowsServer"; sku = "2019-datacenter-gensecond"; version = "latest" }
    win22 = @{ label = "Windows Server 2022  (2022-datacenter-g2)";  publisher = "MicrosoftWindowsServer";  offer = "WindowsServer"; sku = "2022-datacenter-g2";  version = "latest" }
    win25 = @{ label = "Windows Server 2025  (2025-datacenter-g2)";  publisher = "MicrosoftWindowsServer";  offer = "WindowsServer"; sku = "2025-datacenter-g2";  version = "latest" }
}

# ---------------------------------------------------------------------------
# Arrow-key selection menu
# ---------------------------------------------------------------------------
function Select-Option {
    param(
        [string]   $Prompt,
        [string[]] $Options,
        [int]      $Default = 0
    )

    $idx = $Default
    # Total lines the menu occupies: blank + prompt + blank + options + blank + footer
    $menuLines = $Options.Count + 5
    $esc = [char]27
    $firstRender = $true

    while ($true) {
        if (-not $firstRender) {
            # Move cursor up N lines (ESC[nA). `e only works in PS 6+; use [char]27 for PS 5.1
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
            UpArrow   { if ($idx -gt 0)                { $idx-- } }
            DownArrow { if ($idx -lt $Options.Count-1) { $idx++ } }
            Enter     { Write-Host ""; return $Options[$idx] }
            Escape    { Write-Host "`n  Cancelled.`n"; exit 0 }
        }
    }
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |           VM  Deploy  Tool           |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Collect missing parameters interactively
# ---------------------------------------------------------------------------
if (-not $OsVersion) {
    $labels    = $Profiles.Keys | ForEach-Object { $Profiles[$_].label }
    $picked    = Select-Option -Prompt "Select OS version:" -Options $labels -Default 0
    $OsVersion = $Profiles.Keys | Where-Object { $Profiles[$_].label -eq $picked } | Select-Object -First 1
}

if (-not $Action) {
    $Action = Select-Option -Prompt "Select action:" -Options @("plan", "apply", "destroy") -Default 0
}

if (-not $AutoApprove -and $Action -ne "plan") {
    $choice      = Select-Option -Prompt "Auto-approve?" -Options @("No  - pause and review before applying", "Yes - apply immediately") -Default 0
    $AutoApprove = $choice -like "Yes*"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$img = $Profiles[$OsVersion]

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |              Summary                 |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ("  |  OS           : {0,-22}|" -f $OsVersion)     -ForegroundColor White
Write-Host ("  |  SKU          : {0,-22}|" -f $img.sku)        -ForegroundColor White
Write-Host ("  |  Action       : {0,-22}|" -f $Action)         -ForegroundColor White
Write-Host ("  |  Auto-approve : {0,-22}|" -f ([string]$AutoApprove)) -ForegroundColor White
Write-Host "  +--------------------------------------+" -ForegroundColor DarkGray
Write-Host ""

# Extra confirmation for destroy
if ($Action -eq "destroy" -and -not $AutoApprove) {
    $ok = $Host.UI.PromptForChoice("  Confirm destroy", "  This will DELETE all resources. Continue?", @("&Yes", "&No"), 1)
    if ($ok -ne 0) { Write-Host "  Cancelled.`n"; exit 0 }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Build terraform arguments
# ---------------------------------------------------------------------------
$tfArgs = @(
    $Action,
    "-var", "vm_image_publisher=$($img.publisher)",
    "-var", "vm_image_offer=$($img.offer)",
    "-var", "vm_image_sku=$($img.sku)",
    "-var", "vm_image_version=$($img.version)"
)

if ($AutoApprove -and $Action -ne "plan") {
    $tfArgs += "-auto-approve"
}

# ---------------------------------------------------------------------------
# Run terraform
# ---------------------------------------------------------------------------
Push-Location $PSScriptRoot
try {
    Assert-TerraformInstalled
    Ensure-AzLogin

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
