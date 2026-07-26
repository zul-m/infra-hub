param(
  [string]$TargetIp,
  [string]$AnsiblePlaybookPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-TcpPortOpen {
  param(
    [string]$TargetHost,
    [int]$Port,
    [int]$TimeoutMs = 3000
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $asyncResult = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }

    $client.EndConnect($asyncResult)
    return $true
  } catch {
    return $false
  } finally {
    if ($client.Connected) {
      $client.Close()
    } else {
      $client.Dispose()
    }
  }
}

function Wait-WinRmReady {
  param(
    [string]$TargetHost,
    [int]$Port = 5986,
    [int]$MaxWaitSeconds = 600,
    [int]$ProbeIntervalSeconds = 10
  )

  Write-Host "Waiting for WinRM HTTPS endpoint (${TargetHost}:$Port) to become reachable..." -ForegroundColor Yellow

  $elapsed = 0
  while ($elapsed -lt $MaxWaitSeconds) {
    if (Test-TcpPortOpen -TargetHost $TargetHost -Port $Port -TimeoutMs 3000) {
      Write-Host "WinRM HTTPS endpoint is reachable." -ForegroundColor Green
      return $true
    }

    $elapsed += $ProbeIntervalSeconds
    Write-Host "WinRM not reachable yet; retrying in $ProbeIntervalSeconds seconds (elapsed: ${elapsed}s/${MaxWaitSeconds}s)..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  return $false
}

function Invoke-WinRmRepairViaAzCli {
  param(
    [string]$VmName,
    [string]$ResourceGroupName
  )

  if ([string]::IsNullOrWhiteSpace($VmName) -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Write-Host "WinRM self-heal skipped: VM metadata (name/resource group) is unavailable." -ForegroundColor DarkYellow
    return $false
  }

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "WinRM self-heal skipped: Azure CLI is not available." -ForegroundColor DarkYellow
    return $false
  }

  Write-Host "WinRM unreachable. Attempting VM-side repair via Azure Run Command..." -ForegroundColor Yellow
  Write-Host "Target VM: $VmName (RG: $ResourceGroupName)" -ForegroundColor DarkYellow

  $powerState = (& az vm get-instance-view --resource-group $ResourceGroupName --name $VmName --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv 2>$null).Trim()
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not read VM power state; continuing with repair attempt." -ForegroundColor DarkYellow
  }

  if (-not [string]::IsNullOrWhiteSpace($powerState) -and $powerState -ne "VM running") {
    Write-Host "VM is not running ($powerState). Starting VM before WinRM repair..." -ForegroundColor Yellow
    & az vm start --resource-group $ResourceGroupName --name $VmName --output none
    if ($LASTEXITCODE -ne 0) {
      Write-Host "Failed to start VM before WinRM repair." -ForegroundColor DarkYellow
      return $false
    }

    Write-Host "Waiting for VM to report running state..." -ForegroundColor Yellow
    & az vm wait --resource-group $ResourceGroupName --name $VmName --updated --timeout 900
    if ($LASTEXITCODE -ne 0) {
      Write-Host "VM did not reach a ready state in time." -ForegroundColor DarkYellow
      return $false
    }
  }

  $repairScript = @'
$ErrorActionPreference = "Stop"

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$env:COMPUTERNAME" } | Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
}

$httpsListener = Get-ChildItem WSMan:\LocalHost\Listener -ErrorAction SilentlyContinue | Where-Object { $_.Keys -match "Transport=HTTPS" }
if (-not $httpsListener) {
  New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
}

netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986 | Out-Null
Restart-Service -Name WinRM -Force
'@

  & az vm run-command invoke --resource-group $ResourceGroupName --name $VmName --command-id RunPowerShellScript --scripts $repairScript --output none
  if ($LASTEXITCODE -ne 0) {
    Write-Host "WinRM self-heal command failed (az exit code: $LASTEXITCODE)." -ForegroundColor DarkYellow
    return $false
  }

  Write-Host "WinRM self-heal command completed." -ForegroundColor Green
  return $true
}

function Test-AnsibleOutputHasFailure {
  param(
    [string]$OutputText
  )

  if ([string]::IsNullOrWhiteSpace($OutputText)) {
    return $false
  }

  if ($OutputText -match 'fatal:\s*\[') {
    return $true
  }

  if ($OutputText -match 'failed=([1-9][0-9]*)') {
    return $true
  }

  if ($OutputText -match 'unreachable=([1-9][0-9]*)') {
    return $true
  }

  return $false
}

$user    = $env:ANSIBLE_WIN_USER
$pass    = $env:ANSIBLE_WIN_PASSWORD
$sqlUser = $env:SQL_ADMIN_USERNAME
$sqlPass = $env:SQL_ADMIN_PASSWORD
$vmName = $env:AZ_VM_NAME
$resourceGroupName = $env:AZ_RESOURCE_GROUP

$moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requirementsPath = (Resolve-Path (Join-Path $moduleRoot "ansible/requirements.yml")).Path
if ([System.IO.Path]::IsPathRooted($AnsiblePlaybookPath)) {
  $playbookPath = (Resolve-Path $AnsiblePlaybookPath).Path
} else {
  $playbookPath = (Resolve-Path (Join-Path $moduleRoot $AnsiblePlaybookPath)).Path
}

Write-Host ""
Write-Host "================================================================================================" -ForegroundColor Cyan
Write-Host "ANSIBLE PROVISIONING STARTED FOR HOST: $TargetIp" -ForegroundColor Cyan
Write-Host "================================================================================================" -ForegroundColor Cyan
Write-Host ""

$extraVars = @{
  ansible_connection                  = "winrm"
  ansible_port                        = 5986
  ansible_winrm_transport             = "ntlm"
  ansible_winrm_server_cert_validation = "ignore"
  ansible_user                        = $user
  ansible_password                    = $pass
  sql_admin_username                  = $sqlUser
  sql_admin_password                  = $sqlPass
}

$extraVarsFile = [System.IO.Path]::GetTempFileName()
$outputLog = Join-Path $moduleRoot "terraform-provision.log"
$attemptLog = [System.IO.Path]::GetTempFileName()
try {
  $extraVars | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $extraVarsFile -Encoding utf8

  $winRmReady = Wait-WinRmReady -TargetHost $TargetIp -Port 5986 -MaxWaitSeconds 180 -ProbeIntervalSeconds 10
  if (-not $winRmReady) {
    $repaired = Invoke-WinRmRepairViaAzCli -VmName $vmName -ResourceGroupName $resourceGroupName
    if ($repaired) {
      $winRmReady = Wait-WinRmReady -TargetHost $TargetIp -Port 5986 -MaxWaitSeconds 420 -ProbeIntervalSeconds 10
    }
  }

  if (-not $winRmReady) {
    throw "WinRM HTTPS endpoint ${TargetIp}:5986 was not reachable after retry and self-heal attempts."
  }

  $maxAttempts = 3
  $retryDelaySeconds = 45
  $lastExitCode = 0
  $isSuccess = $false

  if (Test-Path $outputLog) {
    Clear-Content -Path $outputLog -ErrorAction SilentlyContinue
  } else {
    New-Item -Path $outputLog -ItemType File -Force | Out-Null
  }

  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Host "Provisioning attempt $attempt of $maxAttempts..." -ForegroundColor Yellow

    if (Test-Path $attemptLog) {
      Clear-Content -Path $attemptLog -ErrorAction SilentlyContinue
    }

    if ($IsLinux -or $IsMacOS) {
      bash -lc "export ANSIBLE_GALAXY_IGNORE_CERTS=true; export ANSIBLE_FORCE_COLOR=true; ansible-galaxy collection install --ignore-certs -r '$requirementsPath' && ansible-playbook '$playbookPath' -i '$TargetIp,' --extra-vars '@$extraVarsFile' 2>&1" 2>&1 |
        Tee-Object -FilePath $attemptLog |
        Tee-Object -FilePath $outputLog -Append | Out-Null
    } else {
      $cwd = (Get-Location).Path -replace '\\', '/'
      $wslpath = (wsl wslpath -a "$cwd").Trim()
      if ($LASTEXITCODE -ne 0) { throw "Failed to convert working directory to a WSL path (exit code: $LASTEXITCODE)" }
      if (-not $wslpath) { throw "Failed to convert working directory to a WSL path" }

      $extraVarsWslPath = (wsl wslpath -a "$($extraVarsFile -replace '\\', '/')").Trim()
      if ($LASTEXITCODE -ne 0) { throw "Failed to convert extra vars file path to a WSL path (exit code: $LASTEXITCODE)" }
      if (-not $extraVarsWslPath) { throw "Failed to convert extra vars file path to a WSL path" }

      $requirementsWslPath = (wsl wslpath -a "$($requirementsPath -replace '\\', '/')").Trim()
      if ($LASTEXITCODE -ne 0) { throw "Failed to convert requirements file path to a WSL path (exit code: $LASTEXITCODE)" }
      if (-not $requirementsWslPath) { throw "Failed to convert requirements file path to a WSL path" }

      $playbookWslPath = (wsl wslpath -a "$($playbookPath -replace '\\', '/')").Trim()
      if ($LASTEXITCODE -ne 0) { throw "Failed to convert playbook path to a WSL path (exit code: $LASTEXITCODE)" }
      if (-not $playbookWslPath) { throw "Failed to convert playbook path to a WSL path" }

      Write-Host "Installing Ansible collections..." -ForegroundColor Yellow
      Write-Host "Running playbook against $TargetIp..." -ForegroundColor Yellow
      Write-Host ""

      wsl bash -lc "export ANSIBLE_GALAXY_IGNORE_CERTS=true; export ANSIBLE_FORCE_COLOR=true; cd '$wslpath' && ansible-galaxy collection install --ignore-certs -r '$requirementsWslPath' && ansible-playbook '$playbookWslPath' -i '$TargetIp,' --extra-vars '@$extraVarsWslPath' 2>&1" 2>&1 |
        Tee-Object -FilePath $attemptLog |
        Tee-Object -FilePath $outputLog -Append | Out-Null
    }

    $lastExitCode = $LASTEXITCODE
    Add-Content -Path $outputLog -Value ""
    Add-Content -Path $outputLog -Value "===== Attempt $attempt of $maxAttempts ====="

    $attemptOutput = if (Test-Path $attemptLog) { Get-Content $attemptLog -Raw } else { "" }
    if ($lastExitCode -eq 0 -and (Test-AnsibleOutputHasFailure -OutputText $attemptOutput)) {
      $lastExitCode = 1
    }

    if ($lastExitCode -eq 0) {
      $isSuccess = $true
      break
    }

    $isTransientConnectivity = $attemptOutput -match "UNREACHABLE|ConnectTimeoutError|timed out|Connection refused|Connection reset"
    if ($attempt -lt $maxAttempts -and $isTransientConnectivity) {
      Write-Host "Attempt $attempt failed due to transient connectivity. Retrying in $retryDelaySeconds seconds..." -ForegroundColor DarkYellow
      Start-Sleep -Seconds $retryDelaySeconds
      continue
    }

    break
  }

  if (-not $isSuccess) {
    Write-Host ""
    Write-Host "Provisioning failed. Full output:" -ForegroundColor Red
    Write-Host "---------------------------------------------------------------------------------------------" -ForegroundColor Red
    Get-Content $outputLog | ForEach-Object { Write-Host $_ }
    Write-Host "---------------------------------------------------------------------------------------------" -ForegroundColor Red
    throw "Ansible provisioning failed (exit code: $lastExitCode)"
  }

  Write-Host ""
  Write-Host "Provisioning completed. Output:" -ForegroundColor Green
  Write-Host "---------------------------------------------------------------------------------------------" -ForegroundColor Green
  Get-Content $outputLog | ForEach-Object { Write-Host $_ }
  Write-Host "---------------------------------------------------------------------------------------------" -ForegroundColor Green
} finally {
  if (Test-Path $extraVarsFile) {
    Remove-Item -Path $extraVarsFile -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $attemptLog) {
    Remove-Item -Path $attemptLog -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "================================================================================================" -ForegroundColor Cyan
Write-Host "ANSIBLE PROVISIONING COMPLETED SUCCESSFULLY" -ForegroundColor Cyan
Write-Host "================================================================================================" -ForegroundColor Cyan
