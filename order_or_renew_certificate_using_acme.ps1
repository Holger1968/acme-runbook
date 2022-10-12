<#
.DESCRIPTION
Runbook (Azure Automation) that orders or renews an x.509 ("tls-") certificate through ACME (f.e. letsencrypt) and stores it in Azure keyvault.
Parameters $domains (hostnames to get certificate for), f.e. @("www1.vankoll.ch","www2.vankoll.ch"), $acme_rg: name of the rg with the acme stuff(keyvault etc.), $ACMEDNSDomain: a (dns-sub-)domain where this runbook can create and delete TXT records and a CNAME called _acme.$domain points to for every $domains (1st parameter)
NOT FINISHED, look for FIXME

.NOTES
for a test run on powershell command prompt see the end of this file
this runbook is (normally) installed through setup_azure_infrastructure_for_acme.ps1 and is not intended to be run / installed manually

#>

#FIXME in Doku erwähnen (readme.md?), dass einfach neue Zertifikate hinzugefügt werden können (in den runbook - Parametern vom Schedule), aber CNAME nicht vergessen
#doku als readme.md in GIT.swisscom.com , unnötige comments im sourcecode weg

#region params, vars, checks etc
param (
  [Parameter(Mandatory = $true)]
  [array]$domains,
  
  [Parameter(Mandatory = $true)]
  [string] $acme_rg,
  
  [Parameter(Mandatory = $true)]
  [string]$PAServer,

  [Parameter(Mandatory = $true)]
  [string]$ACMEDNSDomain
  )    
$errorActionPreference = "Stop"
$WarningPreference = 'SilentlyContinue'
trap {$errmsg = ($_ | format-list * -force | out-string) ; "TRAP CALLED at $(Get-Date) : $errmsg" ; break}  # Error: $_ and Exception: $_.Exception.Message

# $GLOBAL:DebugPreference = "Continue"  # comment out in order to NOT get debug output
$workingDirectory = Join-Path -Path $pwd -ChildPath "posh-acme"
$poshcontainer = "posh-acme"
$poshfile = "posh-acme.zip"

if (!(Get-AzAccessToken -ErrorAction SilentlyContinue)){
  if (!$env:AZUREPS_HOST_ENVIRONMENT) {
  $az = Connect-AzAccount -TenantId 84d7ef22-1ddc-48ce-bf9b-0f099c1ebdf8 -Subscription 6933d5e6-880a-4d60-a474-35b1816d0d62 # Swisscom Azure Testlab Holger
  }
else {
  $az = Connect-AzAccount -Identity
  }
}

# $PAServer  = Get-AutomationVariable -Name 'PAServer'
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

Set-AutomationVariable -Name 'WriteLock' -Value $true

try {
  $s_acc_obj = Get-AzStorageAccount -ResourceGroupName $acme_rg
  if (($s_acc_obj).Count -gt 1) { throw("More than one storage account in $acme_rg detected - cannot handle this - exiting.")}
  $kv_obj = (Get-AzKeyVault -ResourceGroupName $acme_rg -WarningAction SilentlyContinue)
  if (($kv_obj).Count -gt 1) { throw("More than one keyvault in $acme_rg detected - cannot handle this - exiting.")}
  $kv_name = $kv_obj.VaultName
  $null = Set-AzCurrentStorageAccount -ResourceGroupName $acme_rg -Name $s_acc_obj.StorageAccountName
  $null = Get-AzStorageBlobContent -Container $poshcontainer -Blob $poshfile -Destination "."
  Expand-Archive $poshfile -DestinationPath .
  Remove-Item -Force $poshfile
  $env:POSHACME_HOME = $workingDirectory
  Import-Module Posh-ACME -Force
  Set-PAServer $PAServer

  for ($i = 0; $i -lt $domains.Count; $i++) {
    if ($domains[$i] -match '[^a-zA-Z0-9-.]') { throw("$domains[$i] contains an illegal character.") }
    "Checking certificate for " + $domains[$i]
    $cert = Get-PACertificate $domains[$i]
    if ( -not ( $cert ) ) { # no certificate found, so lets order one
      $pfxpwd = (-join([char[]](33..122) | Get-Random -Count 30))
      $pArgs = @{
        AZSubscriptionId = $az.Context.Subscription.Id
        AZAccessToken = (Get-AzAccessToken -ResourceUrl "https://management.core.windows.net/" -TenantId $az.Context.Tenant ).Token
      }
      $cert = New-PACertificate $domains[$i] -DnsAlias $ACMEDNSDomain -PfxPass $pfxpwd -Plugin Azure -PluginArgs $pArgs -AcceptTOS #-Force # FIXME force raus
      if ($cert) { "Created new certificate : $cert" } else { throw "New-PACertificate did not fail, but variable cert is empty - ERROR" }
    }
    else {
      $cert = Submit-Renewal $domains[$i] # -Force # FIXME force raus
      if ($cert) { "Renewed certificate : $cert" } else { "No renewal done." }
    }
    if ($cert) {
      "$cert is " + $cert + $cert.PfxFile
      $certname = $domains[$i] -replace ('\.',"") -replace ('[^a-zA-Z0-9-]', '')
      "Uploading cert $certname to keyvault $kv_name"
      $null = Import-AzKeyVaultCertificate -VaultName $kv_name -Name $certname -FilePath $cert.PfxFile -Password $cert.PfxPass
    }
  }
}
finally {
  $null = Compress-Archive -Path $workingDirectory -DestinationPath $env:TEMP\$poshfile -CompressionLevel Fastest -Force
  $null = Set-AzStorageBlobContent -File $env:TEMP\$poshfile -Container $poshcontainer -Blob $poshfile -BlobType Block -Context $s_acc_obj.Context -Force
  Set-AutomationVariable -Name 'WriteLock' -Value $false
}
Return


#test-run of this runbook in powershell, you must be in the directoy where this scriptfile resides.
#set variables beforehand, f.e $domains = @("vrep-int.finma.ch", "vrep.finma.ch") ; $ACMEDNSDomain = "acme.finma.ch" ; $acme_rg = "vrep-prod-chn-rg03" ; $automation_account_name = "vrep-prod-chn-atm02" ; $acme_kv = "acme-kv01" ; $s_acc_name = "vrepprodchn02" ; $location = "Switzerlandnorth" ; $ACMEContact = "holger.vankoll@swisscom.com" ; $PAServer = "LE_PROD"
Get-Date; $ErrorActionPreference = 'Stop' ; $rbname = "order_or_renew_certificate_using_acme"; $rbparams = @{"domains" = $domains; "acme_rg" = $acme_rg; "ACMEDNSDomain" = $ACMEDNSDomain ; PAServer = $PAServer }
$null = Import-AzAutomationRunbook -Name $rbname -Path .\order_or_renew_certificate_using_acme.ps1 -ResourceGroup $acme_rg -AutomationAccountName $automation_account_name -Type PowerShell -Force -Published
$rb_out = Start-AzAutomationRunbook -Name $rbname -ResourceGroupName $acme_rg -AutomationAccountName $automation_account_name -Parameters $rbparams
do { $x = (Get-AzAutomationJob -Id $rb_out.JobId.Guid -ResourceGroupName $acme_rg -AutomationAccountName $automation_account_name) ; Start-Sleep -Seconds 10 } until ( $x.Status.Equals("Failed") -OR $x.Status.Equals("Completed") )
$jobout = Get-AzAutomationJobOutput -Id $rb_out.JobId -ResourceGroupName $acme_rg -AutomationAccountName $automation_account_name -Stream Any
$joboutput_sum=$jobout.Summary
$joboutput = ($jobout | Get-AzAutomationJobOutputRecord).value
$fname = "$env:TEMP\jobout_exception.txt"
if ( $null -ne $joboutput_sum ) { "joboutput_sum is : " ; $joboutput_sum } ; if ($x.Status.Equals("Failed")) { Write-Host -NoNewline -ForegroundColor Red -BackgroundColor Black "Job Failed! Error details in `$joboutput.Values and in $fname (`$fname)" ; Out-File -InputObject $joboutput.Values -FilePath $fname -ErrorAction SilentlyContinue }
# Get-Content -Tail 30 $fname
[console]::beep(500,800)

