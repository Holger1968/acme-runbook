<#
.DESCRIPTION
Runbook (Azure Automation) that orders or renews an x.509 ("tls"-) certificate through ACME (f.e. letsencrypt) and stores it in Azure keyvault.
Parameters $domains, f.e. @("www1.vankoll.ch","www2.vankoll.ch") and its corresponding certs in key vault, f.e. = @("https://appgwtestvault.vault.azure.net/certificates/holgervkwebapp1/1cb1126b458d412e99a065ed8ead0e43","https://appgwtestvault.vault.azure.net/certificates/holgervkwebapp2/2c31c26bg58g412g99ag65rdre3d2e13")
NOT FINISHED

.NOTES
for a test run on powershell command prompt see the end of this file
# things to do before running this runbook:

# create $ACMEDNSdomain in Azure public dns, it can have any name, f.e. acme.example.com; of course you must control (the apex) example.com
# create ns entry for $acmedomain on the dns-servers for $apex ($apex might be on Azure DNS or not) and point it to Azure DNS Servers (4 servers, you are told them when creating $acmedomain in Azure DNS or you can list them in Azure DNS)
#>

#region params, vars etc
param (
    [Parameter(Mandatory = $true)]
    [array]$domains,

    [Parameter(Mandatory = $true)]
    [array]$certs,

    [Parameter(Mandatory = $true)]
    [string]$ACMEDNSDomain
)

$rg = "acmerg"
$loc = "Switzerlandnorth"
$hostname = $domains[0]
$PAServer = "LE_PROD"
$s_acc_name = "saccforacme"

$errorActionPreference = "Stop"
trap {"Error: $_" ; Get-Error ; break}

if ($domains.Count -ne $certs.Count) {
  throw("Number of domains not equal to number of certs.")
}  

if (!(Get-AzAccessToken -ErrorAction SilentlyContinue)){
  if (!$env:AZUREPS_HOST_ENVIRONMENT) {
    $az = Connect-AzAccount -TenantId 84d7ef22-1ddc-48ce-bf9b-0f099c1ebdf8 -Subscription 6933d5e6-880a-4d60-a474-35b1816d0d62 # Swisscom Azure Testlab
  }  
  else {
    $az = Connect-AzAccount -Identity
  }  
}  

$apex=$hostname.Substring($hostname.IndexOf(".") + 1)    # f.e. www.ibm.ch -> ibm.ch
$acmedomain="acme." + $apex

# $PfxPass = Get-AutomationVariable -Name 'PfxPass'
$WriteLock = Get-AutomationVariable -Name 'WriteLock'
#endregion

$i = 0
while ( $WriteLock -eq $true -and $i -lt 3 ) {
    $i++
    Write-Output "Currently no write access is allowed ($i/3)"
    $WaitPeriod = Get-Random -Minimum 30 -Maximum 90
    Write-Output "Wait for $WaitPeriod seconds and try again"
    Start-Sleep -Seconds $WaitPeriod
    $WriteLock = Get-AutomationVariable -Name 'WriteLock'
  }
  if ( $WriteLock -eq $true ) {
    Write-Output "Cannot get write access to the blob container file. Check if another process has crashed!"
    throw "Cannot get write access to the blob container file!"
  }
# Set WriteLock to true
Set-AutomationVariable -Name 'WriteLock' -Value $true

Set-AzCurrentStorageAccount -ResourceGroupName $rg -Name $s_acc_name
Get-AzStorageBlobContent -Container "posh-acme" -Blob "posh-acme.zip" -Destination "."


$domains
$certs
$ACMEDNSDomain




Set-AutomationVariable -Name 'WriteLock' -Value $false
Return

$pArgs = @{
  AZSubscriptionId = $az.Context.Subscription.Id
  AZAccessToken = $token
}
New-PACertificate $hostname -DnsAlias $acmedomain -Plugin Azure -PluginArgs $pArgs -AcceptTOS

Return


#Get-AzKeyVaultCertificate -VaultName holger-vault1 -Name holgerwebappcert
#New-AzWebAppSSLBinding -ResourceGroupName webtest -WebAppName webapptest3 -Thumbprint 1A9A35E2ADE3956F4E26CC96A8D71A04EAC225C5 -Name webapptest3.vankoll.ch 
# Get-AzADServicePrincipal -ServicePrincipalName abfa0a7c-a6b6-4736-8310-5855508787cd
# Get-AzADServicePrincipal -ServicePrincipalName "abfa0a7c-a6b6-4736-8310-5855508787cd"
# Import-AzWebAppKeyVaultCertificate -KeyVaultName appgwtestvault -CertName holgervkwebapp1 -ResourceGroupName appgwtest -WebAppName holgervk-webapp1 -verbose

#New-AzWebAppSSLBinding -ResourceGroupName appgwtest -WebAppName holgervk-webapp1 -Thumbprint 6055E06A242D8CC4FC5F9C00C90B657A7989BBA9 -Name holgervk-webapp1.azure.vankoll.ch -Debug


#test in powershell, you must be in the directoy where this script - file resides

$ErrorActionPreference = 'Stop'
$rbname = "order_or_renew_certificate_using_acme"
$rg = "acmerg"
$automacc = "atm-acme"
$domains = @("www1.vankoll.ch","www2.vankoll.ch")
$certs = @("https://appgwtestvault.vault.azure.net/certificates/holgervkwebapp1/1cb1126b458d412e99a065ed8ead0e43","kv2")
$ACMEDNSDomain = "acme.vankoll.ch"
$rbparams = @{"domains" = "$domains";"certs" = "$certs";"ACMEDNSDomain" = $ACMEDNSDomain}

switch ((Get-AzContext).Name) {
{ $_.contains("6933d5e6-880a-4d60-a474-35b1816d0d62") }   # Azure Testlab
{ 
  "running on Azure Testlab (Holger)"
  $null = Import-AzAutomationRunbook -Name $rbname -Path .\order_or_renew_certificate_using_acme.ps1 -ResourceGroup $rg -AutomationAccountName $automacc -Type PowerShell -Force -Published
  $rb_out=Start-AzAutomationRunbook -Name $rbname -ResourceGroupName $rg -AutomationAccountName $automacc -Parameters $rbparams
  do { $x=(Get-AzAutomationJob -Id $rb_out.JobId.Guid -ResourceGroupName $rg -AutomationAccountName $automacc) ; $x.Status; Start-Sleep -Seconds 5 } until ( $x.Status.Equals("Failed") -OR $x.Status.Equals("Completed") )
  $jobout = Get-AzAutomationJobOutput -Id $rb_out.JobId -ResourceGroupName $rg -AutomationAccountName $automacc -Stream Any
  $joboutput_sum=$jobout.Summary
  $joboutput = ($jobout | Get-AzAutomationJobOutputRecord).value
  if ( $null -ne $joboutput.Values ) { "joboutput.Values is : " + $joboutput.Values } ; if ( $null -ne $joboutput_sum ) { "joboutput_sum is : " + $joboutput_sum }
}

{ $_.contains("xxxxxxxxxx") }
  {
  "running on xxxxxxxxxxxxxxxxx"
}
Default {"Illegal subsciption - set it correctly with Set-AzContext" ; Return}
}

Return
