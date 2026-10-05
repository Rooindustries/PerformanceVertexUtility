param([Parameter(Mandatory)][string]$Runner,[Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'CS2-GEN4'){throw 'Blackwell-only private fixture proof'}
if(Test-Path -LiteralPath $Evidence){throw 'Retain existing evidence'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path (Split-Path $Runner -Parent) '..\LoadTimes\CleanupOwnership.Common.ps1')
Assert-SealedRecovery (Split-Path $Evidence -Parent);New-SealedDirectory $Evidence
$script:backup=Join-Path $Evidence 'backup';New-SealedDirectory $backup
$script:log=Join-Path $Evidence 'runner.log'
$results=[Collections.Generic.List[object]]::new();$started=[DateTime]::UtcNow
function Assert([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Log([string]$Text){Add-Content -LiteralPath $log -Value $Text;Write-Output $Text}
function Fixture([string]$Name,[switch]$PriorLog){
    $script:case=Join-Path $Evidence $Name;New-SealedDirectory $case
    $script:local=Join-Path $case 'local';New-SealedDirectory $local
    $script:backup=Join-Path $case 'backup';New-SealedDirectory $backup
    $script:rootName='RooIndustriesOptimizationSuite';$script:path=Join-Path $local $rootName;New-SealedDirectory $path
    New-SealedDirectory (Join-Path $path 'settings');[IO.File]::WriteAllText((Join-Path $path 'settings\kept.txt'),'baseline')
    if($PriorLog){New-SealedDirectory (Join-Path $path 'logs');[IO.File]::WriteAllText((Join-Path $path 'logs\data-folder-migration.log'),'pre-existing-log')}
    [IO.Directory]::SetCreationTimeUtc($path,[DateTime]::Parse('2020-01-02T03:04:05Z').ToUniversalTime())
    $script:original=@(Get-RecoveryRows $path);Copy-VerifiedTree $path (Join-Path $backup $rootName) -SealTarget|Out-Null
    $script:scope=[pscustomobject]@{folders=@([pscustomobject]@{name=$rootName;expected=@(Recovery-Lines $original)})}
    $script:lease=[pscustomobject]@{label='validators';startUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');siblings=@($rootName)}
    $script:legacy=$path+'.legacy-'+[Guid]::NewGuid().ToString('N');[IO.Directory]::Move($path,$legacy)
    $script:kept=$path+'.untrusted-'+[Guid]::NewGuid().ToString('N');[IO.Directory]::Move($legacy,$kept)
    New-SealedDirectory $path
    $script:manifest=@{Id=[Guid]::NewGuid().ToString('N');Source=$path;Legacy=$legacy;Started=[DateTime]::UtcNow.ToString('o')}
    Save-RecoveryJson (Join-Path $path '.migrated') $manifest
    New-SealedDirectory (Join-Path $path 'logs');$script:migrationLog=Join-Path $path 'logs\data-folder-migration.log'
    [IO.File]::WriteAllText($migrationLog,('Entries that were not carried over are kept at '+$kept+"`r`n"))
    [IO.Directory]::SetLastWriteTimeUtc($kept,[DateTime]::UtcNow)
    $script:epochDir=Join-Path $case 'epoch';New-SealedDirectory $epochDir
}
function Case([string]$Name,[scriptblock]$Mutation,[switch]$Qualifying,[switch]$PriorLog,[switch]$Reparse){
    try {
        Fixture $Name -PriorLog:$PriorLog;&$Mutation
        $before=if($Reparse){@((Get-Item -LiteralPath (Join-Path $kept 'junction') -Force).Attributes.ToString())}else{@(Get-TreeFingerprint $kept)}
        $companions=@(Get-RecoveryCompanions $scope $lease)
        Save-RecoveryJson (Join-Path $case 'decision.json') @{companions=$companions;lease=$lease;manifest=$manifest;before=$before;kept=$kept}
        if($Qualifying){
            Assert ($companions.Count -eq 1 -and $companions[0].path -ceq $kept) 'Qualifying companion was not adopted'
            $stage=Join-Path $local 'prepared-original';Copy-VerifiedTree (Join-Path $backup $rootName) $stage -OriginalRows $original|Out-Null
            $plan=[pscustomobject]@{scope=$scope;companions=$companions}
            $refused=$false;try{Restore-RecoveryCompanions $plan}catch{$refused=$true}
            Assert $refused 'Companion could be removed before original root restoration'
            Assert (Test-Path -LiteralPath $kept) 'Premature refusal removed companion'
            Restore-Folder $rootName ([pscustomobject]@{stage=$stage;live=@(Get-TreeFingerprint $path);original=@(Recovery-Lines $original)})
            Assert-RecoveryEqual (Recovery-Lines $original) @(Get-TreeFingerprint $path) 'original verified before companion removal'
            Restore-RecoveryCompanions $plan
            Assert (-not(Test-Path -LiteralPath $kept)) 'Qualifying companion still in siblings'
            $q=Join-Path $epochDir 'quarantine-companion-000000';Assert-SealedRecovery $q
            Assert-RecoveryEqual (Recovery-Lines @($before|ForEach-Object {$_|ConvertFrom-Json}) -DataOnly) (Recovery-Lines @(Get-RecoveryRows $q) -DataOnly) 'quarantined companion bytes/metadata'
            Save-RecoveryJson (Join-Path $case 'restore-proof.json') @{root=@(Get-RecoveryRows $path);quarantine=@(Get-RecoveryRows $q);rootExact=$true;keptRemoved=$true}
        } else {
            Assert ($companions.Count -eq 0) 'A disqualified companion was adopted'
            Assert (Test-Path -LiteralPath $kept) 'A disqualified companion was removed'
            if($Reparse){Assert-RecoveryEqual $before @((Get-Item -LiteralPath (Join-Path $kept 'junction') -Force).Attributes.ToString()) 'disqualified reparse unchanged'}else{Assert-RecoveryEqual $before @(Get-TreeFingerprint $kept) 'disqualified companion unchanged'}
        }
        $results.Add(@{name=$Name;passed=$true});Log ('PASS '+$Name)
    } catch {$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;position=$_.InvocationInfo.PositionMessage;stack=$_.ScriptStackTrace});Log ('FAIL '+$Name+' :: '+$_.Exception.Message)}
}
Case 'qualifying-kept-folder-restored-then-quarantined' {} -Qualifying
Case 'preexisting-sibling-kept' {$lease.siblings+=@(Split-Path $kept -Leaf)}
Case 'multiple-new-siblings-kept' {New-SealedDirectory ($path+'.untrusted-'+[Guid]::NewGuid().ToString('N'))}
Case 'different-creation-kept' {[IO.Directory]::SetCreationTimeUtc($kept,[DateTime]::UtcNow)}
Case 'write-outside-lease-kept' {[IO.Directory]::SetLastWriteTimeUtc($kept,[DateTime]::Parse($lease.startUtc).AddSeconds(-1))}
Case 'write-before-manifest-kept' {[IO.Directory]::SetLastWriteTimeUtc($kept,[DateTime]::Parse($manifest.Started).AddSeconds(-1))}
Case 'log-another-path-kept' {[IO.File]::WriteAllText($migrationLog,('Entries that were not carried over are kept at '+$path+'.untrusted-'+[Guid]::NewGuid().ToString('N')))}
Case 'log-duplicate-path-kept' {[IO.File]::AppendAllText($migrationLog,('Entries that were not carried over are kept at '+$kept+"`r`n"))}
Case 'preexisting-log-kept' {} -PriorLog
Case 'missing-manifest-kept' {[IO.File]::Move((Join-Path $path '.migrated'),(Join-Path $case 'retained-manifest.json'))}
Case 'unknown-extra-file-kept' {[IO.File]::WriteAllText((Join-Path $kept 'unknown.txt'),'unknown');[IO.Directory]::SetLastWriteTimeUtc($kept,[DateTime]::UtcNow)}
Case 'changed-file-kept' {[IO.File]::WriteAllText((Join-Path $kept 'settings\kept.txt'),'changed!')}
Case 'changed-length-kept' {[IO.File]::WriteAllText((Join-Path $kept 'settings\kept.txt'),'longer-than-baseline')}
Case 'reparse-point-kept' {New-SealedDirectory (Join-Path $case 'private-target');New-Item -ItemType Junction -Path (Join-Path $kept 'junction') -Target (Join-Path $case 'private-target')|Out-Null;[IO.Directory]::SetLastWriteTimeUtc($kept,[DateTime]::UtcNow)} -Reparse
$passed=@($results|Where-Object {-not$_.passed}).Count -eq 0
$script:backup=Join-Path $Evidence 'backup'
Save-RecoveryJson (Join-Path $Evidence 'result.json') @{machine=$env:COMPUTERNAME;runnerSha256=(Get-FileHash $Runner).Hash;testSha256=(Get-FileHash $PSCommandPath).Hash;realRootsRead=$false;registryWritten=$false;checks=@($results);passed=$passed;durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds}
if(-not$passed){exit 1}
