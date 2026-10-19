<#
.SYNOPSIS
  Emails an alert when a Microsoft 365 user signs in from outside approved countries.
  API version: reads the Office 365 Management Activity API instead of Search-UnifiedAuditLog.

.DESCRIPTION
  Source : Office 365 Management Activity API, content type Audit.AzureActiveDirectory, operation UserLoggedIn
  Geo    : IPinfo Lite API (country level)
  Mail   : Microsoft Graph sendMail from a shared mailbox (managed identity)
  Host   : Azure Automation, PowerShell 7.2 runbook, system-assigned managed identity

  DETECTION ONLY. Covers interactive sign-in events that reach the audit log.
  Background (non-interactive) sign-ins are NOT covered.
  Needs: ActivityFeed.Read app role on "Office 365 Management APIs" + a started
  Audit.AzureActiveDirectory subscription. No Exchange module or audit-log role needed.

.PARAMETER DryRun
  $true (default) = print what would be sent; do not email and do not save state.
  The schedule must pass DryRun = false to go live.

.PARAMETER LookbackHours
  How far back to read (1-24). Events older than this are ignored.

.PARAMETER TestAllowedCountries
  TEST ONLY, requires DryRun. Overrides the allowed-country list (for example ZZ) and ignores
  per-user exceptions, so every sign-in is treated as out-of-country, to preview the alert body.
#>

param(
    [bool]$DryRun = $true,
    [int]$LookbackHours = 24,
    [string]$TestAllowedCountries = ''
)

$ErrorActionPreference = 'Stop'
if ($LookbackHours -gt 24) { $LookbackHours = 24 }
if ($LookbackHours -lt 1)  { $LookbackHours = 1 }
if ($TestAllowedCountries -and -not $DryRun) { throw 'TestAllowedCountries can only be used with DryRun = true.' }

# ---------- Config ----------
$Org            = Get-AutomationVariable -Name 'GeoAlert-Organization'
$IpInfoToken    = Get-AutomationVariable -Name 'GeoAlert-IPinfoToken'
$MailFrom       = Get-AutomationVariable -Name 'GeoAlert-FromMailbox'
$MailTo         = @((Get-AutomationVariable -Name 'GeoAlert-Recipients') -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Allowed        = @((Get-AutomationVariable -Name 'GeoAlert-AllowedCountries') -split '[;,]' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
$ExceptionsJson = Get-AutomationVariable -Name 'GeoAlert-UserExceptions'
$StateJson      = Get-AutomationVariable -Name 'GeoAlert-State'

if ($TestAllowedCountries) {
    $Allowed = @($TestAllowedCountries -split '[;,]' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
}

$DedupeHours = 24   # same user + IP alerts again only after this long
$now         = (Get-Date).ToUniversalTime()
$eventCutoff = $now.AddHours(-$LookbackHours)

# Per-user country exceptions (permanent non-US staff, approved travelers)
$Exceptions = @{}
if ($ExceptionsJson) {
    $parsed = $ExceptionsJson | ConvertFrom-Json -AsHashtable
    foreach ($k in $parsed.Keys) { $Exceptions[$k.ToLower()] = @($parsed[$k] | ForEach-Object { $_.ToString().ToUpper() }) }
}

if ($TestAllowedCountries) { $Exceptions = @{} }   # test preview shows every sign-in, including excepted users

# De-dupe state: "user|ip" -> last alerted (ISO 8601)
$State = @{}
if ($StateJson) { $State = $StateJson | ConvertFrom-Json -AsHashtable }
foreach ($k in @($State.Keys)) {
    if (([datetime]$State[$k]).ToUniversalTime() -lt $now.AddHours(-$DedupeHours)) { $State.Remove($k) }
}

# ---------- Helpers ----------
$geoCache = @{}

function ConvertTo-Utc($v) {
    if ($v -is [datetime]) {
        if ($v.Kind -eq 'Local') { return $v.ToUniversalTime() }
        return [datetime]::SpecifyKind($v, 'Utc')
    }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

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

# ---------- Pull sign-ins from the Office 365 Management Activity API ----------
$tr = Invoke-RestMethod -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } `
        -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://manage.office.com&api-version=2019-08-01"
$mgmtToken = $tr.access_token
$pl = $mgmtToken.Split('.')[1].Replace('-','+').Replace('_','/')
switch ($pl.Length % 4) { 2 { $pl += '==' } 3 { $pl += '=' } }
$tenantId = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pl)) | ConvertFrom-Json).tid
$mh   = @{ Authorization = "Bearer $mgmtToken" }
$feed = "https://manage.office.com/api/v1.0/$tenantId/activity/feed"

# Blob timestamps (contentCreated) can move between listings, so list a wide window
# and rely on the event CreationTime cutoff + user|IP de-dupe instead of blob times.
$s   = $now.AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ss')
$e   = $now.ToString('yyyy-MM-ddTHH:mm:ss')
$uri = "$feed/subscriptions/content?contentType=Audit.AzureActiveDirectory&startTime=$s&endTime=$e&PublisherIdentifier=$tenantId"
$blobs = @()
while ($uri) {
    $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $mh -ResponseHeadersVariable rh
    $blobs += @($page)
    $uri = $null
    if ($rh -and $rh.ContainsKey('NextPageUri')) { $uri = @($rh['NextPageUri'])[0] }
}

$records = @{}   # event Id -> event (de-dupes events that appear in more than one blob)
foreach ($b in $blobs) {
    $raw = Invoke-RestMethod -Method Get -Uri $b.contentUri -Headers $mh
    $events = @()
    foreach ($item in @($raw)) {
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) { $events += @($item) } else { $events += $item }
    }
    foreach ($ev in $events) {
        if ($ev.Operation -ne 'UserLoggedIn') { continue }
        if ((ConvertTo-Utc $ev.CreationTime) -lt $eventCutoff) { continue }
        $records[[string]$ev.Id] = $ev
    }
}
$newest = $null
if ($records.Count -gt 0) { $newest = ($records.Values | ForEach-Object { ConvertTo-Utc $_.CreationTime } | Sort-Object -Descending | Select-Object -First 1) }
$newestText = 'none'
if ($newest) { $newestText = "{0:yyyy-MM-dd HH:mm:ss} UTC ({1} min old)" -f $newest, [math]::Round(($now - $newest).TotalMinutes, 1) }
Write-Output "Blobs listed: $($blobs.Count) | UserLoggedIn events in last $LookbackHours h: $($records.Count) | Newest: $newestText"

# ---------- Evaluate ----------
$hits = foreach ($d in ($records.Values | Sort-Object { ConvertTo-Utc $_.CreationTime })) {
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
        TimeUtc = (ConvertTo-Utc $d.CreationTime).ToString('yyyy-MM-dd HH:mm:ss')
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
Note: detection only. Based on the Office 365 Management Activity API (interactive sign-in events). Background (non-interactive) sign-ins are not covered, and events usually arrive within minutes but can occasionally be delayed by hours.
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