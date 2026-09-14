# Dynamic Distribution Lists + Azure Automation CustomAttribute1 Stamping

## Purpose

Automatically stamp `CustomAttribute1` on tenant mailboxes by domain, enabling
Exchange Online Dynamic Distribution Lists (DDLs) to auto-populate membership
without manual intervention.

## The Problem

Exchange Online DDLs cannot filter membership by email domain natively —
neither through the GUI nor via PowerShell wildcard prefix matching (this
capability broke as of August 2024). For a multi-domain tenant (e.g. one
Microsoft 365 tenant serving several branded domains), there's no built-in way
to say "everyone whose email ends in `@contoso.com`."

**The workaround:** stamp a custom attribute on each mailbox with its domain
value, then filter the DDL on that attribute instead of the domain string
itself.

## Example Setup

Domains covered (illustrative):
- `contoso.com`
- `fabrikam.com`
- `northwind.com`

| DDL Name | Email Address | Filter |
|---|---|---|
| Contoso Employees | all@contoso.com | CustomAttribute1 = contoso.com |
| Fabrikam Employees | all@fabrikam.com | CustomAttribute1 = fabrikam.com |
| Northwind Employees | all@northwind.com | CustomAttribute1 = northwind.com |

DDL filter settings in Exchange Admin Center:
- Recipient type: Users with Exchange mailboxes
- Attribute: Custom Attribute 1
- Value: domain value per DDL above

## Automation

- **Runbook:** PowerShell 5.1 runbook in an Azure Automation Account
- **Schedule:** Nightly, recurring, no expiration
- **Auth:** System-assigned Managed Identity — no stored credentials

### Managed Identity Permissions

- Exchange Online role: `Mail Recipients` (via `New-ManagementRoleAssignment`)
- Entra app role: `Exchange.ManageAsApp` (via `New-MgServicePrincipalAppRoleAssignment`)

```powershell
# Step 1 -- Connect to Exchange Online
Connect-ExchangeOnline

# Step 2 -- Register Managed Identity service principal in Exchange Online
New-ServicePrincipal `
  -AppId "<managed-identity-app-id>" `
  -ObjectId "<managed-identity-object-id>" `
  -DisplayName "EmailAccountAutomation"

# Step 3 -- Assign Mail Recipients role
New-ManagementRoleAssignment `
  -Role "Mail Recipients" `
  -App "<managed-identity-app-id>"

# Step 4 -- Assign Exchange.ManageAsApp permission
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

$ExchangeSP = Get-MgServicePrincipal -Filter "AppId eq '00000002-0000-0ff1-ce00-000000000000'"
$ManagedIdentitySP = Get-MgServicePrincipal -Filter "Id eq '<managed-identity-object-id>'"
$AppRole = $ExchangeSP.AppRoles | Where-Object {$_.Value -eq "Exchange.ManageAsApp"}

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $ManagedIdentitySP.Id `
  -PrincipalId $ManagedIdentitySP.Id `
  -ResourceId $ExchangeSP.Id `
  -AppRoleId $AppRole.Id
```

### Modules Required

| Module | Runtime | Version |
|---|---|---|
| PackageManagement | 5.1 | 1.0.0.1 |
| PowerShellGet | 5.1 | 1.0.0.1 |
| ExchangeOnlineManagement | 5.1 | Latest |

> Note: `ExchangeOnlineManagement` versions above 3.5.0 require the PowerShell
> 7.4 runtime. The 5.1 runtime avoids compatibility issues with Managed
> Identity connections.

### Runbook Script

See [`Stamp-TenantCustomAttribute.ps1`](./Stamp-TenantCustomAttribute.ps1) for the full runbook.

## How New Users Are Handled

New mailboxes provisioned under any covered domain automatically get
`CustomAttribute1` stamped within 24 hours by the nightly runbook run. No
manual action required. For immediate membership, the runbook can be run
manually from the Azure portal or triggered via webhook.

## Adding a New Domain

1. Add a new block to the runbook script following the existing pattern.
2. Create a new DDL in EAC with `CustomAttribute1 = newdomain.com` as the filter.
3. Run the runbook manually once to stamp existing mailboxes immediately.

## Cost

Azure Automation's free tier includes 500 job runtime minutes/month per
subscription. This runbook uses roughly 30–60 minutes/month — effectively
$0.00 at this scale.

## Notes

- `CustomAttribute1` values match the primary SMTP domain of each mailbox exactly.
- The `-ne` check ensures only untagged mailboxes are updated — safe to re-run anytime.
- Managed Identity avoids storing any credentials.
