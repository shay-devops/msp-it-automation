<#
.SYNOPSIS
  Emails an alert when a Microsoft 365 user signs in from outside approved countries.
  Built for tenants WITHOUT Entra P1 (no sign-in log API, no Conditional Access).

.DESCRIPTION
  Source : Purview Unified Audit Log (Audit Standard), operation UserLoggedIn
  Geo    : IPinfo Lite API (free, country level, attribution required)
  Mail   : Microsoft Graph sendMail from a shared mailbox (managed identity)
  Host   : Azure Automation, PowerShell 7.2 runbook, system-assigned managed identity

  DETECTION ONLY. This cannot block a sign-in. Audit events arrive late (not real time),
  so the runbook looks back $LookbackHours and de-duplicates.

.PARAMETER DryRun
  $true (default) = print what would be sent; do not email and do not save state.
  The schedule must pass DryRun = false to go live.

------------------------------------------------------------------------------
ONE-TIME SETUP PER TENANT (the tenant owner's own Azure subscription)
VALIDATED in a pilot tenant.
------------------------------------------------------------------------------
1. Confirm audit is on:   Connect-ExchangeOnline; Get-AdminAuditLogConfig | fl UnifiedAuditLogIngestionEnabled
2. Create an Automation account (system-assigned managed identity ON).
3. Import ExchangeOnlineManagement 3.5.0 for the PowerShell 7.2 runtime (upload a zip).
   Newer versions (3.5.1+) target .NET 8 and fail to load on the 7.2 runtime.
4. Create or choose a shared mailbox for alerts (no license needed).
5. Grant the managed identity (display name = Automation account name):
   a) Exchange.ManageAsApp app role (Microsoft Graph PowerShell):
        Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
        $miId = '<managed identity object id>'
        $exo  = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
        $ar   = $exo.AppRoles | Where-Object { $_.Value -eq 'Exchange.ManageAsApp' -and $_.AllowedMemberTypes -contains 'Application' }
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miId -PrincipalId $miId -ResourceId $exo.Id -AppRoleId $ar.Id
   b) Exchange RBAC (Connect-ExchangeOnline -Device):
        $appId = (Get-MgServicePrincipal -ServicePrincipalId $miId).AppId
        New-ServicePrincipal -AppId $appId -ObjectId $miId -DisplayName '<Automation account name>'
        New-ManagementRoleAssignment -App $miId -Role 'View-Only Audit Logs'
        New-ManagementScope -Name 'GeoAlert-SenderMailbox' -RecipientRestrictionFilter "PrimarySmtpAddress -eq '<alert mailbox>'"
        New-ManagementRoleAssignment -App $miId -Role 'Application Mail.Send' -CustomResourceScope 'GeoAlert-SenderMailbox'
   NO Entra directory role was required (Security Reader / Global Reader not needed).
   Do NOT grant the Graph Mail.Send app role; it is tenant-wide and bypasses the scope above.
   Allow up to an hour for the Exchange role assignments to take effect.
6. Get a free IPinfo Lite token (ipinfo.io/lite).
7. Create Automation variables:
     GeoAlert-Organization      (string)     contoso.onmicrosoft.com
     GeoAlert-IPinfoToken       (ENCRYPTED)  token
     GeoAlert-FromMailbox       (string)     alerts@contoso.com
     GeoAlert-Recipients        (string)     security@contoso.com;other@contoso.com
     GeoAlert-AllowedCountries  (string)     US
     GeoAlert-UserExceptions    (string)     {}   e.g. {"jane@contoso.com":["MX"],"bob@contoso.com":["CA","GB"]}
     GeoAlert-State             (string)     {}
8. Import this runbook (PowerShell 7.2), test with the default DryRun = true, then publish and link an hourly
   schedule that passes DryRun = false.
#>

param(
    [bool]$DryRun = $true
)

$ErrorActionPreference = 'Stop'

# ---------- Config ----------
$Org            = Get-AutomationVariable -Name 'GeoAlert-Organization'
$IpInfoToken    = Get-AutomationVariable -Name 'GeoAlert-IPinfoToken'
$MailFrom       = Get-AutomationVariable -Name 'GeoAlert-FromMailbox'
$MailTo         = @((Get-AutomationVariable -Name 'GeoAlert-Recipients') -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Allowed        = @((Get-AutomationVariable -Name 'GeoAlert-AllowedCountries') -split '[;,]' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
$ExceptionsJson = Get-AutomationVariable -Name 'GeoAlert-UserExceptions'
$StateJson      = Get-AutomationVariable -Name 'GeoAlert-State'

$LookbackHours = 24    # audit events land late; overlap + de-dupe covers it
$DedupeHours   = 24   # same user + IP alerts again only after this long
$now           = (Get-Date).ToUniversalTime()

# Per-user country exceptions (permanent non-US staff, approved travelers)
$Exceptions = @{}
if ($ExceptionsJson) {
    $parsed = $ExceptionsJson | ConvertFrom-Json -AsHashtable
    foreach ($k in $parsed.Keys) { $Exceptions[$k.ToLower()] = @($parsed[$k] | ForEach-Object { $_.ToString().ToUpper() }) }
}

# De-dupe state: "user|ip" -> last alerted (ISO 8601)
$State = @{}
if ($StateJson) { $State = $StateJson | ConvertFrom-Json -AsHashtable }
foreach ($k in @($State.Keys)) {
    if (([datetime]$State[$k]).ToUniversalTime() -lt $now.AddHours(-$DedupeHours)) { $State.Remove($k) }
}

# ---------- Helpers ----------
$geoCache = @{}

function Get-CleanIp([string]$ip) {
    if (-not $ip) { return $null }
    $ip = $ip.Trim()
    if ($ip -match '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { return $Matches[1] }   # ipv4:port
    if ($ip -match '^\[(.+)\]:\d+$')               { return $Matches[1] }   # [ipv6]:port
    return $ip
}

function Get-CountryCode([string]$ip) {
    if ($geoCache.ContainsKey($ip)) { return $geoCache[$ip] }
    try {
        $r  = Invoke-RestMethod -Uri "https://api.ipinfo.io/lite/$($ip)?token=$IpInfoToken" -Method Get -TimeoutSec 20
        $cc = ([string]$r.country_code).ToUpper()
        if (-not $cc) { $cc = $null }
    } catch {
        Write-Warning "Geo lookup failed for $ip : $($_.Exception.Message)"
        $cc = $null
    }
    $geoCache[$ip] = $cc
    return $cc
}

# ---------- Pull sign-ins from the Unified Audit Log ----------
Connect-ExchangeOnline -ManagedIdentity -Organization $Org -ShowBanner:$false

$start   = $now.AddHours(-$LookbackHours)
$session = [guid]::NewGuid().ToString()
$records = New-Object System.Collections.Generic.List[object]
$pages   = 0
do {
    $batch = @(Search-UnifiedAuditLog -StartDate $start -EndDate $now -Operations 'UserLoggedIn' `
                -ResultSize 5000 -SessionId $session -SessionCommand ReturnLargeSet)
    foreach ($b in $batch) { $records.Add($b) }
    $pages++
} while ($batch.Count -gt 0 -and $pages -lt 20)

Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Write-Output "Audit records pulled: $($records.Count)"

# ---------- Evaluate ----------
$hits = foreach ($r in ($records | Sort-Object Identity -Unique)) {
    $d    = $r.AuditData | ConvertFrom-Json
    $user = ([string]$d.UserId).ToLower()
    $ip   = Get-CleanIp ([string]($d.ClientIP ?? $d.ActorIPAddress))
    if (-not $user -or $user -notmatch '@' -or -not $ip) { continue }   # skips "Not Available" / non-UPN records

    $cc = Get-CountryCode $ip
    if (-not $cc) { continue }   # lookup failed: skip, not saved to state, so it retries next run

    $extra = if ($Exceptions.ContainsKey($user)) { $Exceptions[$user] } else { @() }
    if ((@($Allowed) + @($extra)) -contains $cc) { continue }

    $key = "$user|$ip"
    if ($State.ContainsKey($key)) { continue }
    $State[$key] = $now.ToString('o')

    $agent = ($d.ExtendedProperties | Where-Object { $_.Name -eq 'UserAgent' } | Select-Object -First 1).Value
    [pscustomobject]@{
        TimeUtc = $d.CreationTime
        User    = $user
        IP      = $ip
        Country = $cc
        Result  = $d.ResultStatus
        AppId   = $d.ApplicationId
        Agent   = $agent
    }
}
$hits = @($hits)
Write-Output "New out-of-country sign-ins: $($hits.Count)"

# ---------- Alert ----------
if ($hits.Count -gt 0) {
    $lines = $hits | ForEach-Object {
        "$($_.TimeUtc) UTC | $($_.User) | $($_.IP) | $($_.Country) | $($_.Result) | $($_.Agent)"
    }
    $body = @"
Sign-ins from outside approved countries ($($Allowed -join ', ')) for $Org.

Time | User | IP | Country | Result | User agent
$($lines -join "`n")

Next steps: confirm with the user (travel/VPN). If not legitimate: revoke sessions, reset password, review mailbox rules and MFA methods.
Note: detection only, based on the Unified Audit Log, which is delayed and may not include every sign-in type.
IP geolocation by IPinfo (https://ipinfo.io).
"@
    $subject = "[GEO ALERT] $($hits.Count) sign-in(s) outside approved countries - $Org"

    if ($DryRun) {
        Write-Output "DRY RUN - would send to $($MailTo -join ', '):"
        Write-Output $subject
        Write-Output $body
        return
    }

    $tok = Invoke-RestMethod -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } `
            -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01"
    $msg = @{
        message = @{
            subject      = $subject
            body         = @{ contentType = 'Text'; content = $body }
            toRecipients = @($MailTo | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/users/$MailFrom/sendMail" `
        -Headers @{ Authorization = "Bearer $($tok.access_token)" } -ContentType 'application/json' -Body $msg
    Write-Output "Alert sent."
}

# State is saved only after a successful send, so a mail failure retries next run
if (-not $DryRun) {
    Set-AutomationVariable -Name 'GeoAlert-State' -Value ($State | ConvertTo-Json -Compress)
}
