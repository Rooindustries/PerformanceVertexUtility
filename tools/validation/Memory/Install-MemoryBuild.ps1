param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][string]$Sha256)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'memory-install' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$exe='C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
try{
 Assert-HarnessInstallStart $exe
 if((Get-HarnessFileSha256 $Installer) -cne $Sha256){throw 'Installer identity differs'}
 $log=Get-HarnessOutputPath $OutRoot 'setup.log';$started=Start-OwnedProcess -FilePath (Get-HarnessToolPath $Installer) -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG="'+(Get-HarnessToolPath $log)+'"') -Purpose memory-setup
 if(-not$started.process.WaitForExit(180000)){throw 'Installer timeout'}
 if($started.process.ExitCode -ne 0){throw ('Setup exit '+$started.process.ExitCode)}
 Register-HarnessFile $log 'setup-log'|Out-Null
 $display=(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1').DisplayVersion
 $version=(Get-HarnessItem $exe).VersionInfo.ProductVersion.TrimEnd(' ')
 if($display -cne $ExpectedVersion -or $version -cne $ExpectedVersion){throw 'Installed version differs'}
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';displayVersion=$display;productVersion=$version;installerSha256=$Sha256;setup=$started.Identity}|Out-Null
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
}catch{Complete-HarnessInvocation 'fail' -Cleanup|Out-Null;throw}
