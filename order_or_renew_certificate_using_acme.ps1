<#
.DESCRIPTION
Runbook (Azure Automation) that orders or renews an x.509 ("tls"-) certificate through ACME (f.e. letsencrypt). NOT FINISHED
needs the following 
.NOTES
for a test run on powershell command prompt see the end of this file
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Domains,

    [Parameter(Mandatory = $true)]
    [string]$DNSDomain,

    [Parameter(Mandatory = $true)]
    [string]$Keyvaults

)

$errorActionPreference = "Stop"
trap {"Error: $_" ; break}
if (!(Get-AzAccessToken -ErrorAction SilentlyContinue)){
  if (!$env:AZUREPS_HOST_ENVIRONMENT) {
    $az = Connect-AzAccount -TenantId 84d7ef22-1ddc-48ce-bf9b-0f099c1ebdf8 -Subscription 6933d5e6-880a-4d60-a474-35b1816d0d62 # Swisscom Azure Testlab
  }
  else {
    $az = Connect-AzAccount -Identity
  }
}

$PAServer = Get-AutomationVariable -Name 'PAServer'
$ACMEContact = Get-AutomationVariable -Name 'ACMEContact'
$BlobStorageName = Get-AutomationVariable -Name 'BlobStorageName'
$PfxPass = Get-AutomationVariable -Name 'PfxPass'
$WriteLock = Get-AutomationVariable -Name 'WriteLock'

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
    Write-Output "Cannot get write access to the configuration file. Check if another process has crashed!"
    throw "Cannot get write access to configuration file!"
}
# Set WriteLock to true
Set-AutomationVariable -Name 'WriteLock' -Value $true


Return


#test in powershell, you must be in the directoy where this script - file resides

$rbname = "order_or_renew_certificate_using_acme"
$rg = "acme"
$automacc = "atm-acme"

switch ((Get-AzContext).Name) {
{ $_.contains("6933d5e6-880a-4d60-a474-35b1816d0d62") }   # Azure Testlab
{ 
  "running on Azure Testlab (Holger)"
  $null = Import-AzAutomationRunbook -Name $rbname -Path .\renew_certificate_using_acme.ps1 -ResourceGroup $rg -AutomationAccountName $automacc -Type PowerShell -Force -Published
  $rb_out=Start-AzAutomationRunbook -Name $rbname -ResourceGroupName $rg -AutomationAccountName $automacc # -Parameters @{"action"="$action"}
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

