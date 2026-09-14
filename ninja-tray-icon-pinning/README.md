# Pinning the NinjaRMM Tray Icon to the Taskbar (Win10 + Win11)

## The Problem

NinjaRMM's agent runs a systray icon (`njbar.exe`) that, by default, lands in
the Windows notification area overflow ("chevron") menu rather than staying
pinned on the visible taskbar. For an MSP, having the RMM agent icon visibly
pinned across the fleet is useful — end users and techs can see agent status
at a glance without digging into the overflow tray.

Windows exposes no supported API to pin a specific third-party tray icon.
The only way to do it "for real" is to manually drag the icon out of the
overflow menu — not something you can push at scale across hundreds of
endpoints.

**The workaround:** the pinned/unpinned state of each tray icon is stored in
the registry, per-user. The storage mechanism is completely different between
Windows 10 and Windows 11, and neither is documented by Microsoft.

## How It Works

The script detects the OS build and takes one of two paths:

### Windows 11 (build 22000+)
Each tray icon has its own subkey under
`HKCU:\Control Panel\NotifyIconSettings`, keyed by GUID, with an
`ExecutablePath` value identifying the owning executable. Setting
`IsPromoted = 1` on the matching subkey pins the icon — **no Explorer
restart required**. It behaves identically to a manual drag-to-taskbar and
persists across logoffs.

### Windows 10
Pre-Win11, tray icon state lives in a single binary blob:
`HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify\IconStreams`.

This blob has no public schema. Reverse-engineered structure:
- Icon entries are stored in fixed-size 1640-byte records
- Each record contains the owning executable's path, obfuscated with a
  ROT13-style byte transform
- A single byte within each record (offset +528 from the record start)
  controls visibility: `2` = always show / pinned

The script builds the same ROT13-encoded byte signature for the target
executable, locates the matching record in the blob, and flips that
visibility byte. Because this method requires an Explorer restart to take
effect, the script stamps a per-profile registry marker so the restart only
ever happens once per user — not on every run.

## Design Notes

- **Runs in user context (HKCU)** — must run as the logged-on user, not
  SYSTEM, since tray icon state lives in the interactive user's registry
  hive. Built for RMM "run as current logged-on user" execution.
- **Idempotent and safe to run repeatedly or on a schedule.** Every branch
  checks current state before writing and exits cleanly if the icon isn't
  registered yet (e.g. agent hasn't started yet on a fresh install) or is
  already in the desired state.
- **Non-interactive.** No prompts; all status is written to stdout for RMM
  script-run logging.
- **Minimizes user-visible disruption.** The Windows 11 path never restarts
  Explorer at all. The Windows 10 path restarts Explorer at most once per
  user profile, ever.

## Script

See [`Promote-TrayIcon.ps1`](./Promote-TrayIcon.ps1).

## Notes

- Targets a single executable name (`njbar.exe` in this example) — easily
  adapted to pin any other tray icon by changing the `$target` variable.
- The 1640-byte record size and +528 visibility byte offset were determined
  by inspecting the `IconStreams` blob directly; this is undocumented
  internal Windows behavior and could change in future builds.
