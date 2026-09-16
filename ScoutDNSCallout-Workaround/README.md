# ScoutDNS Callout Driver Workaround

## Problem

ScoutDNS's Windows Endpoint Client installer (tested against v2.2.9.0)
has a driver-service registration bug that causes the install to fail
consistently on some machines.

This issue often occurs on machines that have had ScoutDNS v1 in the past.

The client depends on two pieces:
- **`sdnscallout.sys`** — a kernel-mode network filter driver
- **`ScoutDNS Service`** — the main enforcement service, which declares
  `ScoutDNSCallout` as a required service dependency

During install, the MSI correctly stages `sdnscallout.sys` into the
Windows DriverStore (signature verifies, package registers, catalog
installs cleanly). But it never runs the step that promotes that staged
driver into an actual `ScoutDNSCallout` Windows service.

When `ScoutDNS Service` tries to start, Windows checks its dependency
list, can't find a `ScoutDNSCallout` service (because one was never
created), waits the standard 30-second service-start timeout, then
fails with:


Because the install failed, the MSI automatically rolls back — deleting
the files, unregistering the driver, removing the partially-created
services — leaving the machine in a clean state. Every retry starts
from scratch and hits the identical failure, which is why this looks
like an unfixable loop on affected machines.

Confirmed **not** caused by: license/install key issues, EDR/AV
interference (reproduced with SentinelOne fully disabled), missing
Base Filtering Engine dependency, a stale PnP device-class registry
key, or pending-reboot state. The installer itself is simply missing
one step.

Not every machine hits this — some installs succeed on the first
attempt with no workaround needed. This appears to be timing/
environment-dependent rather than universal.

## Fix

The script does the step the installer forgot:

1. Runs the installer once and races to copy `sdnscallout.sys` out of
   `C:\Program Files\ScoutDNS\` before the failed install's automatic
   rollback deletes it.
2. Verifies the captured driver's Authenticode signature.
3. Manually creates and starts `ScoutDNSCallout` as a kernel-driver
   service (`sc.exe create` / `sc.exe start`) from the saved copy.
4. Re-runs the installer. With `ScoutDNSCallout` already present and
   running, the main service's dependency check succeeds immediately
   and the install completes normally.

## Usage

```powershell
.\Invoke-ScoutDNSDriverWorkaround.ps1 -InstallKey '<your-install-key>'
```

Run as SYSTEM / elevated administrator. The install key (UUID) comes
from the ScoutDNS admin console under **Configure → [Install Profile]
→ Install**.

## Notes

- Consider attempting a plain install first and falling back to this
  script only if `Get-Service ScoutDNS*` comes back empty afterward —
  it adds unnecessary steps on machines that would've installed
  cleanly on their own.
- Also cleans up `C:\Program Files\ScoutDNS\DeviceAgent`, a leftover
  folder from older (pre-2.x) ScoutDNS agent versions that was
  frequently found sitting alongside fresh installs.
   
