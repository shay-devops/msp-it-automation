# Geo-Login Alert

Emails an alert when a Microsoft 365 user signs in from outside your approved countries. Runs as an Azure Automation PowerShell 7.2 runbook under a system-assigned managed identity. No Entra ID P1 is required (no sign-in log API, no Conditional Access).

**Detection only.** This cannot block a sign-in. It reports sign-ins after the fact.

## Which script to use

| Script | Source | Needs | Use when |
|---|---|---|---|
| `Send-GeoLoginAlert-API.ps1` (**recommended**) | Office 365 Management Activity API (`Audit.AzureActiveDirectory`) | `ActivityFeed.Read` app role + a started subscription | Default choice. No Exchange module, no audit-log role, faster to set up |
| `Send-GeoLoginAlert.ps1` | Purview Unified Audit Log (`Search-UnifiedAuditLog`) | ExchangeOnlineManagement 3.5.0, `Exchange.ManageAsApp`, View-Only Audit Logs role | You already use the Exchange module in Automation |

Both scripts share the same alert format, de-dupe logic, per-user exceptions and Automation variables.

## How it works

1. Pulls `UserLoggedIn` events from the last `LookbackHours` hours.
2. Looks up each source IP's country with the IPinfo Lite API (cached per run).
3. Skips users and countries on the allow lists.
4. De-dupes on `user|IP` for 24 hours using an Automation variable (`GeoAlert-State`).
5. Sends one plain-text email via Microsoft Graph `sendMail` from a shared mailbox.

State is saved only after a successful send, so a mail failure retries on the next run. A failed geo lookup is skipped and retried on the next run.

## Setup (once per tenant)

Use the tenant owner's own Azure subscription so runtime costs bill to them.

1. **Confirm audit logging is on:**
   `Connect-ExchangeOnline; Get-AdminAuditLogConfig | fl UnifiedAuditLogIngestionEnabled`
2. **Create an Automation account** with the system-assigned managed identity enabled.
3. **Create or choose a shared mailbox** for alerts (no license needed).
4. **Get a free IPinfo Lite token** at [ipinfo.io/lite](https://ipinfo.io/lite).
5. **Create the Automation variables:**

   | Variable | Type | Example |
   |---|---|---|
   | `GeoAlert-Organization` | string | `contoso.onmicrosoft.com` |
   | `GeoAlert-IPinfoToken` | **encrypted** | your token |
   | `GeoAlert-FromMailbox` | string | `alerts@contoso.com` |
   | `GeoAlert-Recipients` | string | `security@contoso.com;other@contoso.com` |
   | `GeoAlert-AllowedCountries` | string | `US` |
   | `GeoAlert-UserExceptions` | string | `{}` or `{"jane@contoso.com":["MX"],"bob@contoso.com":["CA","GB"]}` |
   | `GeoAlert-State` | string | `{}` |

6. **Grant permissions** to the managed identity (its display name is the Automation account name). See the script you chose below. Both need the mail-send scoping in step 7.
7. **Scope mail sending to the alert mailbox** (both scripts), using Exchange RBAC for Applications:

   ```powershell
   Connect-ExchangeOnline -Device
   $miId  = '<managed identity object id>'
   $appId = (Get-MgServicePrincipal -ServicePrincipalId $miId).AppId
   New-ServicePrincipal -AppId $appId -ObjectId $miId -DisplayName '<Automation account name>'
   New-ManagementScope -Name 'GeoAlert-SenderMailbox' -RecipientRestrictionFilter "PrimarySmtpAddress -eq '<alert mailbox>'"
   New-ManagementRoleAssignment -App $miId -Role 'Application Mail.Send' -CustomResourceScope 'GeoAlert-SenderMailbox'
   ```

   Do **not** grant the Graph `Mail.Send` app role. It is tenant-wide and bypasses this scope. Allow up to an hour for Exchange role assignments to take effect.

### API version (`Send-GeoLoginAlert-API.ps1`)

1. Grant the `ActivityFeed.Read` app role on **Office 365 Management APIs** to the managed identity (Microsoft Graph PowerShell):

   ```powershell
   Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
   $miId = '<managed identity object id>'
   $api  = Get-MgServicePrincipal -Filter "appId eq 'c5393580-f805-4401-95e8-94b6a79bd5f4'"   # Office 365 Management APIs; verify in your tenant
   $ar   = $api.AppRoles | Where-Object { $_.Value -eq 'ActivityFeed.Read' }
   New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miId -PrincipalId $miId -ResourceId $api.Id -AppRoleId $ar.Id
   ```

2. Start the `Audit.AzureActiveDirectory` subscription once (POST to `https://manage.office.com/api/v1.0/<tenantId>/activity/feed/subscriptions/start?contentType=Audit.AzureActiveDirectory&PublisherIdentifier=<tenantId>`). Microsoft notes the first content can take up to 12 hours to appear after a subscription starts.
3. No Exchange module and no audit-log role are needed.

### Unified Audit Log version (`Send-GeoLoginAlert.ps1`)

1. Import **ExchangeOnlineManagement 3.5.0** for the PowerShell 7.2 runtime (upload a zip). Newer versions (3.5.1+) target .NET 8 and fail to load on the 7.2 runtime.
2. Grant the `Exchange.ManageAsApp` app role (resource appId `00000002-0000-0ff1-ce00-000000000000`) to the managed identity.
3. Assign the Exchange role `View-Only Audit Logs` to the managed identity:
   `New-ManagementRoleAssignment -App $miId -Role 'View-Only Audit Logs'`
4. No Entra directory role was required in testing.

## Running it

1. Import the runbook (PowerShell 7.2) and run it with the default `DryRun = true`. It prints what it would send and saves no state.
2. To preview the alert body with real data, run the API version with `TestAllowedCountries = ZZ` (requires `DryRun = true`). It treats every sign-in as out-of-country and ignores user exceptions.
3. Publish the runbook and link a schedule that passes `DryRun = false`. Hourly is typical for the Unified Audit Log version; the API version also works on shorter intervals.

## Parameters

| Parameter | Script | Default | Notes |
|---|---|---|---|
| `DryRun` | both | `true` | Must be `false` in the schedule to send mail |
| `LookbackHours` | API | `24` | Clamped to 1-24 |
| `TestAllowedCountries` | API | empty | Test only, requires `DryRun = true` |

## Limitations

- Detection only; it cannot block or revoke anything.
- Covers interactive sign-in events that reach the audit log. Background (non-interactive) sign-ins are **not** covered.
- Events usually arrive within minutes but can be delayed by hours.
- Country-level geolocation only. VPNs, proxies and mobile carriers can produce false positives.
- Alert emails go out as plain text with the user agent and result, so recipients should confirm with the user before acting.

## Suggested response to an alert

Confirm with the user (travel or VPN). If it is not legitimate: revoke sessions, reset the password, and review mailbox rules and MFA methods.

## Disclaimer

Use at your own risk. Test with `DryRun = true` in a non-production tenant before scheduling. Review the permissions you grant to the managed identity.

## Attribution

IP geolocation by [IPinfo](https://ipinfo.io).

## License

MIT. See the repository's LICENSE file.
