# New Teams OS-Aware Update

A PowerShell script that updates **New Microsoft Teams** to the latest version, automatically choosing the correct install method based on the detected OS.

## The Problem

Microsoft's official bulk-install method for New Teams (`teamsbootstrapper.exe`) relies on MSIX, which is **not supported for bulk provisioning on Windows Server 2019** — even though Server 2019 itself supports the MSIX file format. Running the bootstrapper there fails with:

```
"errorMessage": "MSIX installer is not supported on your Windows Operating System version."
```

Server 2019 (commonly used for RDS/terminal server session hosts) requires a different install path: DISM, plus a sideloading registry change most environments don't have enabled by default.

This script detects the OS and branches automatically, so techs don't have to remember which method applies to which machine.

## What It Does

| OS Detected | Method Used |
|---|---|
| Windows 10 / 11 | `teamsbootstrapper.exe -p` |
| Windows Server 2022+ | `teamsbootstrapper.exe -p` |
| Windows Server 2019 (build 17763) | Enables sideloading (`AppModelUnlock`) → installs via `Dism /Online /Add-ProvisionedAppxPackage` |
| Bootstrapper fails for any reason | Falls back to the DISM method automatically |

It also reports the installed MSTeams version before and after, so you can confirm the update actually landed — useful for closing out vulnerability remediation tickets that flag a specific target version.

## Usage

Run elevated (Administrator). No parameters needed — paste and run:

```powershell
.\Update-NewTeams.ps1
```

Safe to re-run; both install methods are idempotent if Teams is already current.

## Known Limitation

On Server 2019 / RDS hosts, DISM provisions the package for **new logons**. Users already logged in when the script runs won't see the update reflected until they log off and back on.
