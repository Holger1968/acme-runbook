<#
.DESCRIPTION
Runbook (Azure Automation) that orders or renews an x.509 ("tls-") certificate through ACME (f.e. letsencrypt) and stores it in Azure keyvault.
Parameters $domains (hostnames to get certificate for), f.e. @("www1.vankoll.ch","www2.vankoll.ch"), $acme_rg: name of the rg with the acme stuff(keyvault etc.), $ACMEDNSDomain: a (dns-sub-)domain where this runbook can create and delete TXT records and a CNAME called _acme.$domain points to for every $domains (1st parameter)
NOT FINISHED, look for FIXME

.NOTES
for a test run on powershell command prompt see the end of this file
this runbook is (normally) installed through setup_azure_infrastructure_for_acme.ps1 and is not intended to be run / installed manually

#>

# create $ACMEDNSdomain in Azure public dns, it can have any name, f.e. acme.example.com; of course you must control (the apex) example.com
# create ns entry for $acmedomain on the dns-servers for $apex ($apex might be on Azure DNS or not) and point it to Azure DNS Servers (4 servers, you are told them when creating $acmedomain in Azure DNS or you can list them in Azure DNS)
#FIXME PAServer LE_PROD
#FIXME in Doku erwähnen (readme.md), dass einfach neue Zertifikate hinzugefügt werden können (im Schedule!)
#FIXME test von "check if certificate schon vorhanden, sonst neues"
#FIXME output was gemacht wurde (new cert, renewal, key vault updates)
#region params, vars, checks etc
param (
  [Parameter(Mandatory = $true)]
  [array]$domains,
  
  [Parameter(Mandatory = $true)]
  [string] $acme_rg,
  
  [Parameter(Mandatory = $true)]
  [string]$ACMEDNSDomain
  )    

$PAServer = "LE_STAGE"
$workingDirectory = Join-Path -Path $pwd -ChildPath "posh-acme"
$poshcontainer = "posh-acme"
$poshfile = "posh-acme.zip"
$GLOBAL:DebugPreference="Continue"  # comment out in order to NOT get debug output

$errorActionPreference = "Stop"
trap {$errmsg = ($_ | format-list * -force | out-string) ; "TRAP CALLED : $errmsg" ; break}  # Error: $_ and Exception: $_.Exception.Message and 

if (!(Get-AzAccessToken -ErrorAction SilentlyContinue)){
  if (!$env:AZUREPS_HOST_ENVIRONMENT) {
    $az = Connect-AzAccount -TenantId 84d7ef22-1ddc-48ce-bf9b-0f099c1ebdf8 -Subscription 6933d5e6-880a-4d60-a474-35b1816d0d62 # Swisscom Azure Testlab
  }      
  else {
    $az = Connect-AzAccount -Identity
  }      
}  
#endregion
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
  Write-Output "Cannot get write access to the blob container file. Check if another process has crashed!"
  throw "Cannot get write access to the blob container file!"
}

Set-AutomationVariable -Name 'WriteLock' -Value $true

try {
  $s_acc_obj=Get-AzStorageAccount -ResourceGroupName $acme_rg
  if (($s_acc_obj).Count -gt 1) { throw("More than one storage account in $acme_rg detected - cannot handle this - exiting.")}
  $kv_obj = (Get-AzKeyVault -ResourceGroupName $acme_rg)
  if (($kv_obj).Count -gt 1) { throw("More than one keyvault in $acme_rg detected - cannot handle this - exiting.")}
  $null = Set-AzCurrentStorageAccount -ResourceGroupName $acme_rg -Name $s_acc_obj.StorageAccountName
  $null = Get-AzStorageBlobContent -Container $poshcontainer -Blob $poshfile -Destination "."
  Expand-Archive $poshfile -DestinationPath .
  Remove-Item -Force $poshfile
  $env:POSHACME_HOME = $workingDirectory
  Import-Module Posh-ACME -Force
  Set-PAServer $PAServer

  for ($i = 0; $i -lt $domains.Count; $i++) {
    "Listing certificate for " + $domains[$i]
    $cert = Get-PACertificate $domains[$i]
    if ( -not ( $cert ) ) { # no certificate found, so lets order one
      $pfxpwd = (-join([char[]](33..122) | Get-Random -Count 30))
      $pArgs = @{
          AZSubscriptionId = $az.Context.Subscription.Id
          AZAccessToken = (Get-AzAccessToken -ResourceUrl "https://management.core.windows.net/" -TenantId $az.Context.Tenant ).Token
      }
      $cert = New-PACertificate $domains[$i] -DnsAlias $ACMEDNSDomain -PfxPass $pfxpwd -Plugin Azure -PluginArgs $pArgs -AcceptTOS -Force # FIXME force raus
      "Created new certificate : $cert"
    }
    else {
      $cert = Submit-Renewal $domains[$i] -Force # FIX force raus
      "Renewed certificate : $cert"
    }
    $domain = $domains[$i] -replace ('\.',"") -replace ('[^a-zA-Z0-9-]', '')
    $null = Import-AzKeyVaultCertificate -VaultName $kv_obj.VaultName -Name $domain -FilePath $cert.PfxFile -Password $cert.PfxPass
    }
}
finally {
  $null = Compress-Archive -Path $workingDirectory -DestinationPath $env:TEMP\$poshfile -CompressionLevel Fastest -Force
  $null = Set-AzStorageBlobContent -File $env:TEMP\$poshfile -Container $poshcontainer -Blob $poshfile -BlobType Block -Context $s_acc_obj.Context -Force
  Set-AutomationVariable -Name 'WriteLock' -Value $false
}
Return





#test-run of this runbook in powershell, you must be in the directoy where this script - file resides

Get-Date; $ErrorActionPreference = 'Stop' ; $rbname = "order_or_renew_certificate_using_acme"; $acme_rg = "acme-rg01"; $automacc = "acme-atm01"; $domains = @("www3.azure.vankoll.ch","www4.azure.vankoll.ch"); $ACMEDNSDomain = "acme.vankoll.ch"; $rbparams = @{"domains" = $domains; "acme_rg" = $acme_rg; "ACMEDNSDomain" = $ACMEDNSDomain}; 
switch ((Get-AzContext).Name) {
  { $_.contains("6933d5e6-880a-4d60-a474-35b1816d0d62") }   # Azure Testlab Holger
    {
      "Running on Azure Testlab (Holger)"
      $null = Import-AzAutomationRunbook -Name $rbname -Path .\order_or_renew_certificate_using_acme.ps1 -ResourceGroup $acme_rg -AutomationAccountName $automacc -Type PowerShell -Force -Published
      $rb_out = Start-AzAutomationRunbook -Name $rbname -ResourceGroupName $acme_rg -AutomationAccountName $automacc -Parameters $rbparams
      do { $x = (Get-AzAutomationJob -Id $rb_out.JobId.Guid -ResourceGroupName $acme_rg -AutomationAccountName $automacc) ; $x.Status; Start-Sleep -Seconds 5 } until ( $x.Status.Equals("Failed") -OR $x.Status.Equals("Completed") )
      $jobout = Get-AzAutomationJobOutput -Id $rb_out.JobId -ResourceGroupName $acme_rg -AutomationAccountName $automacc -Stream Any
      $joboutput_sum=$jobout.Summary
      $joboutput = ($jobout | Get-AzAutomationJobOutputRecord).value
      if ( $null -ne $joboutput_sum ) { "joboutput_sum is : " ; $joboutput_sum } ; if ( $null -ne $joboutput.Values ) { Write-Host -NoNewline -ForegroundColor Red -BackgroundColor Yellow "Error details in $env:TEMP\jobout_exception.txt" ; Out-File -InputObject $joboutput.Values -FilePath $env:TEMP\jobout_exception.txt -ErrorAction SilentlyContinue }
    }
  Default {"Illegal subsciption - set it correctly with Set-AzContext" ; Return}
  }
# Get-Content -Tail 30 C:\Users\holge\AppData\Local\Temp\jobout_exception.txt

Return


# PS C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell> Get-PACertificate www3.vankoll.ch|Get-Member -MemberType NoteProperty
#    TypeName: PoshACME.PACertificate
# Name          MemberType   Definition
# ----          ----------   ----------
# AllSANs       NoteProperty Object[] AllSANs=System.Object[]
# CertFile      NoteProperty System.String CertFile=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\cert.cer
# ChainFile     NoteProperty System.String ChainFile=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\chain.cer
# FullChainFile NoteProperty System.String FullChainFile=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\fullchain.cer
# KeyFile       NoteProperty System.String KeyFile=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\cert.key
# KeyLength     NoteProperty string KeyLength=2048
# NotAfter      NoteProperty datetime NotAfter=24.12.2022 01:28:58
# NotBefore     NoteProperty datetime NotBefore=25.09.2022 02:28:59
# PfxFile       NoteProperty System.String PfxFile=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\cert.pfx
# PfxFullChain  NoteProperty System.String PfxFullChain=C:\Users\holge\OneDrive\cloud-sc\azure\hvk\powershell\posh-acme\LE_STAGE\69239914\www3.vankoll.ch\fullchain.pfx
# PfxPass       NoteProperty System.Security.SecureString PfxPass=System.Security.SecureString
# Subject       NoteProperty string Subject=CN=www3.vankoll.ch
# Thumbprint    NoteProperty string Thumbprint=9AADD2891C4EF0CB65CA33122BB010E69508548B
