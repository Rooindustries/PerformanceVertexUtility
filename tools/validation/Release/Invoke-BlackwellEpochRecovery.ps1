param([Parameter(Mandatory)][string]$Runner,[Parameter(Mandatory)][string]$OriginalFrame,[Parameter(Mandatory)][string]$Evidence,[switch]$InspectOnly)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'CS2-GEN4'){throw 'Blackwell-only recovery'}
if($OriginalFrame -cne 'C:\RooBuild\roo-industries-final-run-25fedf20f8e842dc924d86b133e235b1'){throw 'Wrong original sealed frame'}
if(Test-Path -LiteralPath $Evidence){throw 'Evidence already exists'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path (Split-Path $Runner -Parent) '..\LoadTimes\LauncherChecks.Common.ps1')
. (Join-Path (Split-Path $Runner -Parent) '..\LoadTimes\CleanupOwnership.Common.ps1')
Assert-SealedRecovery (Split-Path $Evidence -Parent);New-SealedDirectory $Evidence
$script:log=Join-Path $Evidence 'recovery.log';$script:Failures=0
$script:backup=Join-Path $Evidence 'native-backup';New-SealedDirectory $backup;Initialize-RecoveryNative
$script:backup=Join-Path $OriginalFrame 'recovery'
$script:baseline=Read-RecoveryJson (Join-Path $backup 'machine-state.json')
if($baseline.backupFormat -ne 3 -or $baseline.appFolder -or @($baseline.uninstallEntries).Count){throw 'Original baseline has no authorized rollback contract'}
$script:local=[Environment]::GetFolderPath('LocalApplicationData')
$script:app='C:\Program Files\Roo Industries\Optimization Suite'
$script:rooHklm='HKLM\SOFTWARE\RooIndustries';$script:stateKey='HKLM\SOFTWARE\RooIndustriesOptimizationSuite'
$script:markerKey='HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$script:personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:userEnvironment='HKCU:\Environment';$script:plantedName='DOTNET_STARTUP_HOOKS';$script:plantedValue='C:\RooIndustriesNoSuchFolder\hook.dll'
$script:Source=Split-Path (Split-Path (Split-Path (Split-Path $Runner -Parent) -Parent) -Parent) -Parent
$script:Phase='validators';$script:epochDir=$null
$scope=Read-RecoveryScope;$lease=Require-RecoveryEpoch 'validators'
$root=@($scope.folders|Where-Object name -ceq 'RooIndustriesOptimizationSuite')
if($root.Count -ne 1 -or @($root[0].expected).Count -ne 299){throw 'Wrong original data-root baseline'}
if($InspectOnly){
    $companions=@(Get-RecoveryCompanions $scope $lease)
    foreach($folder in $scope.folders){Assert-RecoveryFolderContract $folder $lease|Out-Null}
    @{machine=$env:COMPUTERNAME;originalFrame=$OriginalFrame;companions=$companions;contractPassed=$true;inspectedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Evidence 'inspection.json') -Encoding UTF8
    if($companions.Count -ne 1 -or $companions[0].path -cne (Join-Path $local 'RooIndustriesOptimizationSuite.untrusted-fe4560ae54f348a9af2ec978ed0dbe8e')){throw 'Actual kept companion did not meet the exact qualification'}
    Write-Output 'PASS exact actual companion and folder contracts inspected without activating recovery';return
}
$started=[DateTime]::UtcNow;$failure=$null
try {
    Invoke-EpochRecovery
    $rows=@(foreach($folder in $scope.folders){$actual=@(Get-TreeFingerprint (Join-Path $local $folder.name));Assert-RecoveryEqual @($folder.expected) $actual ('restored '+$folder.name);@{name=$folder.name;expected=$folder.expected;actual=$actual;equal=$true}})
    $creation=@(foreach($f in $scope.folders){foreach($r in @($f.expected|Where-Object {$_ -cne '<missing>'}|ForEach-Object {$_|ConvertFrom-Json})){$i=Get-Item -LiteralPath ((Join-Path $local $f.name)+$r.relative) -Force;@{root=$f.name;relative=$r.relative;directory=$r.directory;before=$r.creation;after=$i.CreationTimeUtc.Ticks.ToString();equal=($r.creation -ceq $i.CreationTimeUtc.Ticks.ToString())}}})
    if(@($creation|Where-Object {-not$_.equal}).Count){throw ('Restored creation differs: '+(ConvertTo-Json -InputObject @($creation|Where-Object {-not$_.equal}) -Compress))}
} catch {$failure=$_}
@{machine=$env:COMPUTERNAME;originalFrame=$OriginalFrame;runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash;lease=$lease;scopeSha256=(Get-FileHash -LiteralPath (Join-Path $backup 'recovery-scope.json')).Hash;startedUtc=$started.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds;rootRows=$rows;creation=$creation;passed=(-not$failure);error=[string]$failure;position=$(if($failure){$failure.InvocationInfo.PositionMessage});stack=$(if($failure){$failure.ScriptStackTrace})}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Evidence 'result.json') -Encoding UTF8
if($failure){throw $failure}
Write-Output 'PASS original sealed validators recovery and exact restored creation times'
