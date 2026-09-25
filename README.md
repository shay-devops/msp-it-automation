# IT Automation Scripts

Real-world automation and admin scripts written to solve production problems across a multi-tenant MSP environment. Each folder documents one specific problem, the reasoning behind the fix, and the script itself. Client names, tenant IDs, and other identifiers have been replaced with generic placeholders throughout.

## Contents

- **[Dynamic Distribution Lists + CustomAttribute1 Stamping](./dynamic-distribution-lists)** — Workaround for the Exchange Online DDL domain-filter regression, using an Azure Automation runbook with Managed Identity to stamp a custom attribute on mailboxes nightly.

- **[Pinning the NinjaRMM Tray Icon (Win10 + Win11)](./ninja-tray-icon-pinning)** — Reverse-engineered the undocumented per-user tray icon pinning mechanism on both Windows 10 (binary registry blob) and Windows 11 (NotifyIconSettings), to force an RMM agent icon to stay visible on the taskbar fleet-wide.

- **[ScoutDNS Callout Driver Workaround](./ScoutDNSCallout-Workaround)** — Fix for a ScoutDNS Windows Endpoint Client installer bug where the required ScoutDNSCallout kernel driver service is never created, causing every install attempt to fail with Error 1920 and roll back identically. Deployed as a NinjaRMM script.

- [New Teams OS-Aware Update](new-teams-os-aware-update) — Auto-detects Windows 10/11 vs. Server 2019 to pick the correct New Teams install method, since the standard bootstrapper's MSIX install silently fails on Server 2019/RDS hosts.

## About

These scripts come from day-to-day work supporting client environments as part of an MSP — spanning Microsoft 365/Entra ID, Azure automation, Windows endpoint management, and network/security tooling. More entries will be added over time.
