<#
.SYNOPSIS
    Updates New Microsoft Teams to the latest version, auto-selecting the correct
    install method based on the detected OS.

.DESCRIPTION
    - Windows 10 / Windows 11 / Server 2022+  -> uses teamsbootstrapper.exe (-p)
    - Windows Server 2019                     -> uses DISM /Add-ProvisionedAppxPackage
                                                  (bootstrapper's MSIX install is NOT
                                                  supported on Server 2019) plus the
                                                  AppModelUnlock sideload registry fix
    - Anything else                           -> aborts with a warning, no changes made

.NOTES
    Run elevated (Administrator). Safe to re-run; DISM/bootstrapper are idempotent
    if Teams is already current.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # suppresses the noisy download progress bar
$WorkDir = "$env:TEMP\TeamsUpdate"

function Write-Section($msg) {
    Write-Host ""
    Write-Host "==== $msg ====" -ForegroundColor Cyan
}

function Get-CurrentTeamsVersion {
    try {
        $pkg = Get-AppxPackage -Name "MSTeams" -AllUsers -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) { return $pkg.Version }
    } catch {}
    return $null
}

Write-Section "Detecting OS"

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$caption   = $os.Caption
$buildNum  = [int]$os.BuildNumber
$isServer  = $caption -match 'Server'
$isServer2019 = $isServer -and ($buildNum -eq 17763)   # Server 2019 = build 17763

Write-Host "OS Caption   : $caption"
Write-Host "Build Number : $buildNum"

$before = Get-CurrentTeamsVersion
Write-Host "Current MSTeams version: $(if ($before) { $before } else { 'Not installed' })"

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

if (-not $isServer -or ($isServer -and $buildNum -gt 17763)) {
    # ---- Windows 10 / 11 / Server 2022+ : bootstrapper path ----
    Write-Section "Using teamsbootstrapper.exe path (Win10/11 or Server 2022+)"

    $bootstrapperPath = Join-Path $WorkDir "teamsbootstrapper.exe"
    Write-Host "Downloading bootstrapper..."
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243204" -OutFile $bootstrapperPath

    Write-Host "Running bootstrapper (-p)..."
    $result = & $bootstrapperPath -p
    $resultText = $result -join "`n"

    if ($resultText -match '"success":\s*false') {
        Write-Warning "Bootstrapper reported failure:"
        Write-Host $resultText
        Write-Warning "Falling back to DISM method..."
        $useDism = $true
    } else {
        Write-Host "Bootstrapper completed." -ForegroundColor Green
        $useDism = $false
    }
}
else {
    $useDism = $true
}

if ($isServer2019 -or $useDism) {
    # ---- Windows Server 2019 (or bootstrapper fallback) : DISM path ----
    Write-Section "Using DISM /Add-ProvisionedAppxPackage path (Server 2019)"

    Write-Host "Enabling sideloading (AppModelUnlock)..."
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowAllTrustedApps /d 1 | Out-Null

    $msixPath = Join-Path $WorkDir "teamsbulk.msix"
    Write-Host "Downloading MSIX package..."
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2196106" -OutFile $msixPath

    Write-Host "Installing via DISM..."
    Dism /Online /Add-ProvisionedAppxPackage /PackagePath:"$msixPath" /SkipLicense
}

Write-Section "Verifying"

$after = Get-CurrentTeamsVersion
Write-Host "MSTeams version now: $(if ($after) { $after } else { 'Still not detected' })"

if ($before -eq $after) {
    Write-Warning "Version unchanged. If this is Server 2019, existing user profiles won't reflect the provisioned update until they log off/on. If this is Win10/11, the bootstrapper may report already-current."
} else {
    Write-Host "Update applied: $before -> $after" -ForegroundColor Green
}

if ($isServer2019) {
    Write-Host ""
    Write-Host "NOTE: DISM provisions the package for NEW logons. Existing logged-in users on this RDS host must log off/on to see the update reflected." -ForegroundColor Yellow
}
