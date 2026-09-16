<#
.SYNOPSIS
    Installs the ScoutDNS Endpoint Client, working around a driver-service
    registration bug present in some versions of the installer.

.DESCRIPTION
    ScoutDNS's MSI installer stages its network-filter driver
    (sdnscallout.sys) into the Windows DriverStore correctly, but on some
    machines it never creates the ScoutDNSCallout kernel service that the
    driver needs to actually run. Because the main ScoutDNS Service
    declares ScoutDNSCallout as a service dependency, Windows waits the
    full 30-second service-start timeout for a dependency that was never
    created, the start fails with Error 1920, and the whole MSI
    transaction rolls back -- deleting the files it just installed. This
    repeats identically on every retry, because each attempt starts from
    scratch and hits the same missing step.

    Root cause: the installer never runs the step that promotes the
    staged driver package into an actual Windows service. This script
    works around that gap by:
      1. Running the installer once and racing to copy sdnscallout.sys
         out of C:\Program Files\ScoutDNS before the failed install rolls
         back and deletes it.
      2. Verifying the captured driver's Authenticode signature.
      3. Manually creating and starting the ScoutDNSCallout kernel-driver
         service from the saved copy (sc.exe create / start).
      4. Re-running the installer. With ScoutDNSCallout already present
         and running, the main service's dependency check now succeeds
         immediately and the install completes normally.

    Not every machine hits this bug -- some installs succeed on the
    first plain attempt with no workaround needed. Consider attempting a
    plain install first and only falling back to this script if that
    attempt leaves the ScoutDNS services missing.

.PARAMETER InstallKey
    The ScoutDNS install key (UUID) for the target tenant/site, from the
    ScoutDNS admin console under Configure > [Install Profile] > Install.
    Required -- do not hardcode this in a shared copy of the script.

.PARAMETER DownloadUrl
    URL to the ScoutDNS Windows x64 MSI. Override only if ScoutDNS
    changes their distribution path.

.PARAMETER WorkFolder
    Scratch directory for the downloaded MSI, saved driver, and logs.

.NOTES
    Run as SYSTEM / elevated administrator.
    Tested against ScoutDNS Endpoint Client 2.2.9.0.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallKey,

    [string]$DownloadUrl = 'https://download.scoutdns.com/assets/device_agent/installers/scoutdns-client-win-x64.msi',

    [string]$WorkFolder = 'C:\ProgramData\ScoutDNS-Workaround'
)

$ErrorActionPreference = 'Stop'

$MsiPath    = Join-Path $WorkFolder 'scoutdns-client-win-x64.msi'
$SavedDriver = Join-Path $WorkFolder 'sdnscallout_saved.sys'
$FirstLog   = Join-Path $WorkFolder 'ScoutDNS-first-pass.log'
$FinalLog   = Join-Path $WorkFolder 'ScoutDNS-final-pass.log'

New-Item -Path $WorkFolder -ItemType Directory -Force | Out-Null

Write-Output 'Downloading ScoutDNS installer.'
Invoke-WebRequest -Uri $DownloadUrl -OutFile $MsiPath -UseBasicParsing

# Optional: clean up leftover files from a prior partial/legacy install so
# they don't interfere with this attempt.
Remove-Item -Path 'C:\Program Files\ScoutDNS\DeviceAgent' -Recurse -Force -ErrorAction SilentlyContinue

Write-Output 'Starting first MSI pass and capturing the driver before rollback.'
$FirstInstall = Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" /qn INSTALLKEY=$InstallKey /L*v `"$FirstLog`"" -PassThru

$DriverCaptured = $false
for ($Attempt = 1; $Attempt -le 120; $Attempt++) {
    $InstalledDriver = 'C:\Program Files\ScoutDNS\sdnscallout.sys'
    if (Test-Path -LiteralPath $InstalledDriver) {
        Copy-Item -LiteralPath $InstalledDriver -Destination $SavedDriver -Force
        $DriverCaptured = $true
        break
    }
    Start-Sleep -Milliseconds 250
}

$FirstInstall.WaitForExit()

if (-not $DriverCaptured -or -not (Test-Path -LiteralPath $SavedDriver)) {
    throw "The ScoutDNS driver could not be captured. Review $FirstLog"
}

$Signature = Get-AuthenticodeSignature -LiteralPath $SavedDriver
if ($Signature.Status -ne 'Valid') {
    throw "The captured driver signature is not valid: $($Signature.Status)"
}

Write-Output 'Creating and starting the missing ScoutDNSCallout kernel-driver service.'
& sc.exe create ScoutDNSCallout type= kernel start= demand error= normal binPath= $SavedDriver
if ($LASTEXITCODE -notin @(0, 1073)) {
    throw "Failed to create ScoutDNSCallout. sc.exe exit code: $LASTEXITCODE"
}

& sc.exe start ScoutDNSCallout
if ($LASTEXITCODE -notin @(0, 1056)) {
    throw "Failed to start ScoutDNSCallout. sc.exe exit code: $LASTEXITCODE"
}

Write-Output 'Rerunning the ScoutDNS MSI with ScoutDNSCallout present.'
$FinalInstall = Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" /qn INSTALLKEY=$InstallKey /L*v `"$FinalLog`"" -Wait -PassThru

Write-Output "Final MSI exit code: $($FinalInstall.ExitCode)"
Get-Service -Name 'ScoutDNS*' -ErrorAction SilentlyContinue | Select-Object Status, Name, DisplayName

exit $FinalInstall.ExitCode
