param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$FrameRoot,[Parameter(Mandatory)][string]$FrameId,[Parameter(Mandatory)][string]$Manifest,[Parameter(Mandatory)][string]$Nonce,[Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Log,[Parameter(Mandatory)][string]$Result)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
Open-HarnessRun $FrameRoot $FrameId $Manifest $Nonce
try{
 Assert-HarnessInstallStart (Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe')
 $start=[Diagnostics.ProcessStartInfo]::new((Get-HarnessToolPath $Installer));$start.UseShellExecute=$true;$start.WorkingDirectory=Get-HarnessToolPath ([IO.Path]::GetDirectoryName($Installer));$start.Arguments='/LOG="'+(Get-HarnessToolPath $Log)+'"'
 $process=[Diagnostics.Process]::Start($start);$owned=Register-HarnessStartedProcess $process 'tour-setup';$process.WaitForExit()
 $data=@{status='exited';exitCode=$process.ExitCode;identity=$owned.Identity}
}catch{$data=@{status='failed';error=$_.Exception.ToString()}}
New-HarnessText $Result (@{nonce=$Nonce;data=$data}|ConvertTo-Json -Depth 12) 'result' 'run'|Out-Null
if($data.status -eq 'failed'){exit 1}
