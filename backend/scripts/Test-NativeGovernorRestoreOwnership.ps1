$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Host "PASS $Message"}
function Read-Result($Lines){return ($Lines -join [Environment]::NewLine)|ConvertFrom-Json}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-native-restore-ownership-'+[guid]::NewGuid().ToString('N'))
$probe=$null
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $exe=Join-Path $root 'RooIndustriesRestoreProbe.exe'
    Add-Type -TypeDefinition 'using System.Threading; public class RooIndustriesRestoreProbe {public static void Main(){Thread.Sleep(120000);}}' -OutputAssembly $exe -OutputType ConsoleApplication
    $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $probe=[Diagnostics.Process]::new();$probe.StartInfo=$start;$probe.Start()|Out-Null
    $build=Read-Result (& (Join-Path $PSScriptRoot 'Build-NativeProcessGovernor.ps1') -OutputPath (Join-Path $root 'RooIndustriesProcessGovernor.exe'))
    if($build.status -ne 'built' -and $build.status -ne 'success'){Write-Host ($build|ConvertTo-Json -Depth 12)}
    $worker=@(Get-ChildItem $root -Recurse -Filter RooIndustriesProcessGovernor.exe)[0].FullName
    $originalAffinity=$probe.ProcessorAffinity.ToInt64()
    $snapshot=@{processId=$probe.Id;processName=$probe.ProcessName;executablePath=$exe;processStartTimeUtc=$probe.StartTime.ToUniversalTime().ToString('o');
        originalPriorityClass='Normal';originalAffinityMask=$originalAffinity;originalIoPriority='Normal';originalGpuPriority='Normal';
        appliedControls=@(@{control='priorityClass';proposedValue='BelowNormal';blocked=$false})}
    $backup=Join-Path $root 'backup.json';@{snapshots=@($snapshot)}|ConvertTo-Json -Depth 12|Set-Content $backup -Encoding UTF8
    $probe.PriorityClass='High'
    $lowBit=$originalAffinity -band (-$originalAffinity);$probe.ProcessorAffinity=[IntPtr]::new($lowBit)
    $result=Read-Result (& $worker --restore $backup)
    $probe.Refresh()
    Assert ($probe.PriorityClass -eq 'High' -and $probe.ProcessorAffinity.ToInt64() -eq $lowBit -and $result.status -eq 'failed') 'Native restore preserves external priority changes and controls the governor never applied'
    $probe.PriorityClass='BelowNormal'
    $result=Read-Result (& $worker --restore $backup)
    $probe.Refresh()
    Assert ($result.status -eq 'completed' -and $probe.PriorityClass -eq 'Normal' -and $probe.ProcessorAffinity.ToInt64() -eq $lowBit) 'Owned priority restores normally while unrelated affinity remains unchanged'
    $again=Read-Result (& $worker --restore $backup)
    Assert ($again.status -eq 'completed') 'Native restore is idempotent once its own control is original'
    $latest=@{};foreach($name in $snapshot.Keys){$latest[$name]=$snapshot[$name]};$latest.originalPriorityClass='High'
    @{snapshots=@($snapshot,$latest)}|ConvertTo-Json -Depth 12|Set-Content $backup -Encoding UTF8
    $probe.PriorityClass='BelowNormal'
    $latestRestore=Read-Result (& $worker --restore $backup)
    $probe.Refresh()
    Assert ($latestRestore.status -eq 'completed' -and $probe.PriorityClass -eq 'High') 'Repeated native restraint cycles restore the latest captured original rather than a superseded cycle'
    @{snapshots=@($snapshot)}|ConvertTo-Json -Depth 12|Set-Content $backup -Encoding UTF8
    $probe.PriorityClass='High'
    $fallback=Read-Result (& (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -BackupPath $backup -ConfirmApply)
    $probe.Refresh()
    Assert ($probe.PriorityClass -eq 'High' -and $probe.ProcessorAffinity.ToInt64() -eq $lowBit) 'PowerShell governor restore also preserves external and unowned controls'
    $probe.PriorityClass='BelowNormal'
    $fallback=Read-Result (& (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -BackupPath $backup -ConfirmApply)
    $probe.Refresh()
    Assert ($probe.PriorityClass -eq 'Normal' -and $probe.ProcessorAffinity.ToInt64() -eq $lowBit) 'PowerShell governor restores its recorded priority without overwriting unrelated affinity'
} finally {
    if($null -ne $probe){if(-not $probe.HasExited){$probe.Kill()};if(-not $probe.WaitForExit(10000)){throw 'Native restore fixture did not exit'};$probe.Dispose()}
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
