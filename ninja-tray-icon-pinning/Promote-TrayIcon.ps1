<#
.SYNOPSIS
Pins ONLY the target systray icon (njbar.exe) to the taskbar.
The chevron / overflow menu is preserved for all other icons.

.DESCRIPTION
Detects the OS and uses the correct per-app mechanism:
  - Windows 11 (build 22000+): HKCU\Control Panel\NotifyIconSettings -> IsPromoted = 1
                               Written WITHOUT an Explorer restart, so it behaves
                               like a manual drag-to-taskbar and persists across
                               logoffs. No flicker.
  - Windows 10:                IconStreams binary blob -> visibility byte = 2.
                               Requires one Explorer restart to take effect, so it
                               is gated behind a per-profile marker to fire at most
                               once per user (single flicker, never repeats).

Runs in USER context (HKCU). Designed for RMM "Current Logged-on User" execution.
Non-interactive safe: no Read-Host. Writes log lines to stdout only.

.NOTES
Do NOT run elevated / as SYSTEM. The tray data lives in the interactive user's hive.
Safe to run recurring or at logon; both branches stay quiet once applied.
#>

$target = 'njbar.exe'
$build  = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber

Write-Output "Starting tray icon promotion. Target: $target | OS Build: $build"

# ============================================================
# WINDOWS 11 (22000+) -- NotifyIconSettings / IsPromoted
# No Explorer restart: the value persists like a manual drag.
# ============================================================
if ($build -ge 22000) {
    Write-Output "Windows 11 path: NotifyIconSettings / IsPromoted (no restart)."
    $base = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path $base)) {
        Write-Output "NotifyIconSettings not present yet for this user. Exiting clean."
        exit 0
    }

    $found = $false
    Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.ExecutablePath -and $props.ExecutablePath -like "*$target") {
            $found = $true
            if ($props.IsPromoted -ne 1) {
                Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Type DWord -Force
                Write-Output "Promoted $target (key $($_.PSChildName)). No restart needed."
            } else {
                Write-Output "$target already promoted. No change."
            }
        }
    }

    if (-not $found) {
        Write-Output "$target not registered in NotifyIconSettings yet. Will catch on a later run."
    }
    exit 0
}

# ============================================================
# WINDOWS 10 -- IconStreams blob byte-flip, gated to one restart per profile
# ============================================================
Write-Output "Windows 10 path: IconStreams binary blob byte-flip."

# Per-profile marker so the (required) Explorer restart fires at most once.
$flagKey = 'HKCU:\Software\Contoso\TrayIconPin'
$done    = (Get-ItemProperty -Path $flagKey -Name 'Pinned' -ErrorAction SilentlyContinue).Pinned
if ($done -eq 1) {
    Write-Output "Win10 pin already applied for this profile (marker present). Skipping."
    exit 0
}

$TrayPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify'
if (-not (Test-Path $TrayPath)) {
    Write-Output "TrayNotify key not present yet for this user. Exiting clean."
    exit 0
}

$bytRegKey = (Get-ItemProperty -Path $TrayPath -Name IconStreams -ErrorAction SilentlyContinue).IconStreams
if (-not $bytRegKey -or $bytRegKey.Count -le 20) {
    Write-Output "IconStreams empty or too small. Icon not registered yet. Exiting clean."
    exit 0
}

$encText   = New-Object System.Text.UTF8Encoding
$strRegKey = -join ($bytRegKey | ForEach-Object { '{0:x2}' -f $_ })

function Rot13($b) {
    if ($b -gt 64 -and $b -lt 91)  { return (($b - 64 + 13) % 26 + 64) }
    elseif ($b -gt 96 -and $b -lt 123) { return (($b - 96 + 13) % 26 + 96) }
    else { return $b }
}

$bytTemp = $encText.GetBytes($target)
[byte[]] $bytAppPath = @()
foreach ($b in $bytTemp) { $bytAppPath += [byte](Rot13 $b); $bytAppPath += [byte]0 }
$strAppPath = -join ($bytAppPath | ForEach-Object { '{0:x2}' -f $_ })

if (-not $strRegKey.Contains($strAppPath)) {
    Write-Output "$target not found in IconStreams yet. Will catch on a later run. Exiting clean."
    exit 0
}

$needsChange = $false
for ($x = 0; $x -lt [math]::Floor(($bytRegKey.Count - 20) / 1640); $x++) {
    $start   = 20 + ($x * 1640)
    $item    = $bytRegKey[$start..($start + 1639)]
    $strItem = -join ($item | ForEach-Object { '{0:x2}' -f $_ })
    if ($strItem.Contains($strAppPath)) {
        $visIndex = $start + 528
        if ($bytRegKey[$visIndex] -ne 2) {
            $bytRegKey[$visIndex] = 2   # 2 = always show
            $needsChange = $true
            Write-Output "Stamped $target visibility byte in block starting at $start."
        } else {
            Write-Output "$target block at $start already set to always-show."
        }
    }
}

if ($needsChange) {
    Set-ItemProperty -Path $TrayPath -Name IconStreams -Value $bytRegKey
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer
    Write-Output "IconStreams written and Explorer restarted (one-time)."
}

# Stamp the marker either way so we never restart Explorer again for this profile.
New-Item -Path $flagKey -Force | Out-Null
Set-ItemProperty -Path $flagKey -Name 'Pinned' -Value 1 -Type DWord -Force
Write-Output "Per-profile marker set. Win10 branch will not restart Explorer again."

exit 0
