param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [string]$Scenario,[string]$InstallerPath,[string]$EvidenceName,[switch]$CurrentData)
$ErrorActionPreference='Stop'
$requestedCurrentData=[bool]$CurrentData
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Invoke-UpdateScenario.ps1')) -Source (Get-HarnessToolPath $Source) -OutRoot (Get-HarnessToolPath $OutRoot) -Scenario manual-install -EvidenceName $EvidenceName -HelpersOnly
Assert-HarnessHostLease
if(-not$requestedCurrentData -or $global:RooVerificationInvocationContext.protocol -cne 'roo-industries-verification-invocation/v2'){throw 'Background install did not opt into its fresh Update frame.'}
$snapshot=CapturePreservation
Preserved $snapshot
Save 'compat-install.json' @{protocol=$global:RooVerificationInvocationContext.protocol;leaseHeld=$true;installerStarted=$false;preservation=$snapshot}
