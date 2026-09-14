Connect-ExchangeOnline -ManagedIdentity -Organization "contoso.onmicrosoft.com"

# Repeat this block per domain
Get-Mailbox -ResultSize Unlimited | Where-Object {
    $_.PrimarySmtpAddress -like "*@contoso.com" -and
    $_.CustomAttribute1 -ne "contoso.com"
} | Set-Mailbox -CustomAttribute1 "contoso.com"

# ... additional domain blocks follow the same pattern ...

# Verify all
Get-Mailbox -ResultSize Unlimited | Where-Object {
    $_.PrimarySmtpAddress -like "*@contoso.com" -or
    $_.PrimarySmtpAddress -like "*@fabrikam.com" -or
    $_.PrimarySmtpAddress -like "*@northwind.com"
} | Select-Object DisplayName, PrimarySmtpAddress, CustomAttribute1

Disconnect-ExchangeOnline -Confirm:$false
