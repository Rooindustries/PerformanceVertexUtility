param([Parameter(Mandatory)][string]$Runner,[Parameter(Mandatory)][string]$Evidence,[switch]$Before)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'CS2-GEN4'){throw 'Blackwell-only private fixture proof'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Elevation required'}
if(Test-Path -LiteralPath $Evidence){throw 'Evidence already exists'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path (Split-Path $Runner -Parent) '..\LoadTimes\CleanupOwnership.Common.ps1')
Assert-SealedRecovery (Split-Path $Evidence -Parent)
New-SealedDirectory $Evidence
$script:backup=Join-Path $Evidence 'sealed-backup';New-SealedDirectory $backup
$script:log=Join-Path $Evidence 'runner.log'
$script:results=[Collections.Generic.List[object]]::new()
$script:started=[DateTime]::UtcNow
function Assert([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Log([string]$Text){Add-Content -LiteralPath $log -Value ([DateTime]::UtcNow.ToString('o')+' '+$Text);Write-Output $Text}
function Case([string]$Name,[scriptblock]$Action){
    try{&$Action;$results.Add(@{name=$Name;passed=$true});Log ('PASS '+$Name)}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;position=$_.InvocationInfo.PositionMessage;stack=$_.ScriptStackTrace});Log ('FAIL '+$Name+' :: '+$_.Exception.Message)}
}
function Fixture([string]$Name){
    $script:case=Join-Path $Evidence $Name;New-SealedDirectory $case
    $script:local=Join-Path $case 'local';New-SealedDirectory $local
    $script:rootName='RooIndustriesOptimizationSuite';$script:path=Join-Path $local $rootName
    New-SealedDirectory $path
    $script:directory=Join-Path $path 'cleanup-runs';New-SealedDirectory $directory
    $script:file=Join-Path $path 'kept.txt';[IO.File]::WriteAllText($file,'baseline')
    [IO.File]::SetCreationTimeUtc($file,[DateTime]::Parse('2020-01-02T03:04:05Z').ToUniversalTime())
    [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::Parse('2020-01-02T04:05:06Z').ToUniversalTime())
    [IO.Directory]::SetCreationTimeUtc($directory,[DateTime]::Parse('2020-01-01T01:02:03Z').ToUniversalTime())
    $script:originalRows=@(Get-RecoveryRows $path)
    $script:folder=[pscustomobject]@{name=$rootName;expected=@(Recovery-Lines $originalRows)}
    $script:lease=[pscustomobject]@{label='validators';startUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');siblings=@($rootName)}
}
function Recreate-Directory {
    [IO.Directory]::Move($directory,(Join-Path $case 'retained-original-directory'))
    New-SealedDirectory $directory
    [IO.Directory]::SetCreationTimeUtc($directory,[DateTime]::UtcNow)
    $old=@($originalRows|Where-Object relative -ceq '\cleanup-runs')[0]
    Assert ((Get-Item -LiteralPath $directory).CreationTimeUtc.Ticks.ToString() -cne $old.creation) 'Directory was not recreated with a different creation time'
}
function Manifest([switch]$OutsideLease){
    $at=if($OutsideLease){[DateTime]::Parse($lease.startUtc).AddSeconds(-1)}else{[DateTime]::UtcNow}
    $value=@{Id=[Guid]::NewGuid().ToString('N');Source=$path;Legacy=$null;Started=$at.ToString('o')}
    Save-RecoveryJson (Join-Path $path '.migrated') $value
}
function Refuse([string]$Expected){
    $message=$null;try{Assert-RecoveryFolderContract $folder $lease|Out-Null}catch{$message=$_.Exception.Message}
    Assert ($null -ne $message -and $message -match $Expected) ('Expected refusal '+$Expected+'; got '+$message)
    Save-RecoveryJson (Join-Path $case 'refusal.json') @{message=$message;original=$originalRows;live=@(Get-RecoveryRows $path)}
}
Case 'unchanged-without-manifest-accepted' {Fixture 'unchanged';Assert-RecoveryFolderContract $folder $lease|Out-Null}
Case 'in-lease-directory-creation-and-exact-restoration' {
    Fixture 'in-lease'
    $saved=Join-Path $backup 'original';Copy-VerifiedTree $path $saved -SealTarget|Out-Null
    Recreate-Directory;Manifest;[IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow)
    if($Before){Refuse ' creation';return}
    $live=@(Assert-RecoveryFolderContract $folder $lease)
    $stage=Join-Path $local 'prepared-original';Copy-VerifiedTree $saved $stage -OriginalRows $originalRows|Out-Null
    $script:epochDir=Join-Path $case 'epoch';New-SealedDirectory $epochDir
    Restore-Folder $rootName ([pscustomobject]@{live=$live;original=$folder.expected;stage=$stage})
    $restored=@(Get-RecoveryRows $path)
    Assert-RecoveryEqual $folder.expected (Recovery-Lines $restored) 'all restored fixture rows'
    $creation=@(foreach($r in $originalRows){$now=@($restored|Where-Object relative -ceq $r.relative)[0];@{relative=$r.relative;directory=$r.directory;before=$r.creation;after=$now.creation;equal=($r.creation -ceq $now.creation)}})
    Assert (@($creation|Where-Object {-not$_.equal}).Count -eq 0) 'Restored creation times differ'
    Save-RecoveryJson (Join-Path $case 'restore-proof.json') @{creation=$creation;original=$originalRows;restored=$restored;exact=$true}
}
Case 'directory-creation-without-manifest-refused' {Fixture 'without-manifest';Recreate-Directory;Refuse 'cleanup-runs creation'}
Case 'directory-creation-outside-lease-refused' {Fixture 'outside-lease';Recreate-Directory;Manifest -OutsideLease;Refuse 'outside lease'}
Case 'file-creation-only-in-lease-accepted' {Fixture 'file-creation-only';Manifest;[IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow);if($Before){Refuse 'kept.txt creation'}else{Assert-RecoveryFolderContract $folder $lease|Out-Null}}
Case 'file-creation-only-without-manifest-refused' {Fixture 'file-creation-without-manifest';[IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow);Refuse 'kept.txt creation'}
foreach($field in 'length','sha256','write','attributes'){
    Case ('file-'+$field+'-refused') {
        Fixture ('file-'+$field);Recreate-Directory;Manifest
        switch($field){
            'creation'{[IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow)}
            'length'{[IO.File]::WriteAllText($file,'longer-than-baseline');[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::Parse('2020-01-02T04:05:06Z').ToUniversalTime())}
            'sha256'{[IO.File]::WriteAllText($file,'changed!');[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::Parse('2020-01-02T04:05:06Z').ToUniversalTime())}
            'write'{[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow)}
            'attributes'{[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))}
        }
        if($Before){Refuse ('creation|kept.txt '+$field+'|file timestamp changed.*kept.txt')}elseif($field -ceq 'write'){Refuse 'file timestamp changed.*kept.txt'}else{Refuse ('kept.txt '+$field)}
    }
}
foreach($field in 'length','sha256','write','attributes'){
    Case ('file-creation-plus-'+$field+'-refused') {
        Fixture ('file-creation-plus-'+$field);Manifest;[IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow)
        switch($field){
            'length'{[IO.File]::WriteAllText($file,'longer-than-baseline');[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::Parse('2020-01-02T04:05:06Z').ToUniversalTime())}
            'sha256'{[IO.File]::WriteAllText($file,'changed!');[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::Parse('2020-01-02T04:05:06Z').ToUniversalTime())}
            'write'{[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow)}
            'attributes'{[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))}
        }
        Refuse '(creation|length)'
    }
}
Case 'directory-attributes-refused' {Fixture 'directory-attributes';Manifest;[IO.File]::SetAttributes($directory,([IO.File]::GetAttributes($directory) -bor [IO.FileAttributes]::Hidden));Refuse 'cleanup-runs attributes'}
Case 'directory-existence-refused' {Fixture 'directory-deleted';Manifest;[IO.Directory]::Move($directory,(Join-Path $case 'retained-deleted-directory'));Refuse 'entry deleted.*cleanup-runs'}
Case 'directory-kind-refused' {Fixture 'directory-kind';Manifest;[IO.Directory]::Move($directory,(Join-Path $case 'retained-replaced-directory'));[IO.File]::WriteAllText($directory,'replacement');Refuse 'cleanup-runs directory'}
$passed=@($results|Where-Object {-not$_.passed}).Count -eq 0
Save-RecoveryJson (Join-Path $Evidence 'result.json') @{machine=$env:COMPUTERNAME;runner=$Runner;runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash;testSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;before=[bool]$Before;realRootsRead=$false;registryWritten=$false;privateFixture=$Evidence;checks=@($results);passed=$passed;durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds}
if(-not$passed){exit 1}
