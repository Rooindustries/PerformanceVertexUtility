param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$PrivateDir,
    [Parameter(Mandatory)][string]$ExpectedScriptSha256,
    [string]$ExpectedMachine='SERVI-WINDOWS-D',
    [string]$InstallRoot='C:\Program Files\Roo Industries\Optimization Suite'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LoadTimesHandoff.Common.ps1')
$checks=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$dependencyRows=[Collections.Generic.List[object]]::new()
$passed=$false
$restored=$false
$mutationAttempted=$false
$ownedRevision=$null
$beforeStamp=$null
$afterStamp=$null
$phase='initialization'
$started=[DateTime]::UtcNow
function Check([bool]$Ok,[string]$Name){$checks.Add(@{passed=$Ok;check=$Name});if(-not$Ok){throw $Name};'PASS '+$Name}
function Hash-Bytes([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
function Stamp-Policy {
    if(-not[IO.File]::Exists($script:policy)){return @{exists=$false;sha256=$null;bytes=0}}
    Assert-HandoffProtected $script:policy
    $bytes=[IO.File]::ReadAllBytes($script:policy)
    @{exists=$true;sha256=(Hash-Bytes $bytes);bytes=$bytes.Length}
}
function Assert-Installed([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked installed dependency refused'};$p=[IO.Path]::GetDirectoryName($p)}
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl=Get-Acl -LiteralPath $Path
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Installed dependency owner refused'}
    foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($ace.AccessControlType -ne 'Allow'){continue}
        if($ace.IdentityReference.Value -ceq 'S-1-3-0' -and ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
        if($ace.IdentityReference.Value -notin $trusted -and ([long]$ace.FileSystemRights -band 0x500D0156)){throw 'Installed dependency writer refused'}
    }
}
function Assert-Epoch {
    $lease=Read-HandoffJson $script:leasePath
    if($lease.hash -cne $script:leaseHash -or $lease.value.label -cne 'installed' -or $lease.value.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Installed epoch changed'}
    foreach($name in 'restore-journal.json','restore-complete.json'){if(Test-Path -LiteralPath (Join-Path (Split-Path $script:leasePath -Parent) $name)){throw 'Installed epoch is recovering'} }
    if([DateTime]::UtcNow -gt $script:started.AddMinutes(10)){throw 'Installed exclusion proof exceeded its bound'}
}
function Save-Receipt {
    [IO.File]::WriteAllText((Join-Path $PrivateDir 'receipt.json'),(ConvertTo-Json -InputObject ([ordered]@{phase=$script:phase;mutationAttempted=$script:mutationAttempted;ownedRevision=$script:ownedRevision;before=$script:beforeStamp;after=$script:afterStamp;leaseSha256=$script:leaseHash;scriptSha256=$ExpectedScriptSha256}) -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Installed([hashtable]$Arguments,[string]$Name){
    Assert-Epoch
    $raw=@(& $script:command @Arguments) -join "`n"
    [IO.File]::WriteAllText((Join-Path $PrivateDir ($Name+'.json')),$raw,[Text.UTF8Encoding]::new($false))
    $reply=$raw|ConvertFrom-Json
    if($null -eq $reply -or $reply.schemaVersion -ne 1 -or $reply.status -cne 'completed' -or $null -eq $reply.data){throw 'Installed exclusion reply is incomplete'}
    $reply.data
}
function Assert-Lists($Value,$Expected){
    if($null -eq $Value -or $null -eq $Value.paths -or $null -eq $Value.registry){throw 'Exclusion lists missing'}
    $actual=ConvertTo-Json -InputObject $Value -Depth 32 -Compress
    $wanted=ConvertTo-Json -InputObject $Expected -Depth 32 -Compress
    if($actual -cne $wanted){throw 'Exclusion lists differ from this proof request'}
}
function Assert-OwnedRevision([string]$Revision){
    $now=Stamp-Policy
    if($Revision -notmatch '^[0-9a-fA-F]{64}$' -or -not$now.exists -or $now.sha256 -ine $Revision){throw 'Exclusion revision conflict; current data retained'}
    $now
}
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong installed exclusion proof machine'}
Assert-HandoffProtected $RunRoot
Assert-HandoffProtected (Split-Path $OutDir -Parent)
Assert-HandoffProtected (Split-Path $PrivateDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing exclusion evidence retained'}
if(Test-Path -LiteralPath $PrivateDir){throw 'Existing private exclusion receipt retained'}
if([IO.Path]::GetFullPath($PrivateDir).StartsWith([IO.Path]::GetFullPath((Split-Path $OutDir -Parent))+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Private exclusion bytes cannot be inside evidence'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
[IO.Directory]::CreateDirectory($PrivateDir)|Out-Null
Assert-HandoffProtected $OutDir
Assert-HandoffProtected $PrivateDir
try{
    Check ($null -eq [Environment]::GetEnvironmentVariable('DOTNET_ROOT','Process') -and $null -eq [Environment]::GetEnvironmentVariable('ROO_INDUSTRIES_DOTNET_EXE','Process')) 'caller starts without a runtime override'
    $leasePath=Join-Path $RunRoot 'recovery\epoch-installed\lease.json'
    $leaseHash=(Read-HandoffJson $leasePath).hash
    Assert-Epoch
    $command=Join-Path $InstallRoot 'backend\scripts\Invoke-CleanupExclusions.ps1'
    $relative=@('backend\scripts\Invoke-CleanupExclusions.ps1','backend\scripts\OperationState.Common.ps1','backend\scripts\BrandCompatibility.Common.ps1','backend\bin\optimizer\Optimizer.Host.exe','backend\bin\optimizer\Optimizer.Host.dll','backend\bin\optimizer\hostpolicy.dll','backend\bin\optimizer\Optimizer.Host.runtimeconfig.json')
    foreach($name in $relative){
        $path=Join-Path $InstallRoot $name
        Assert-Installed $path
        $stream=[IO.File]::Open($path,'Open','Read','Read');$pins.Add($stream)
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose()};$stream.Position=0
        $dependencyRows.Add(@{relativePath=$name;sha256=$hash;bytes=$stream.Length})
    }
    Check ($ExpectedScriptSha256 -match '^[0-9a-fA-F]{64}$' -and $dependencyRows[0].sha256 -ieq $ExpectedScriptSha256) 'installed exclusion script matches the pinned release script hash'
    . (Join-Path $InstallRoot 'backend\scripts\OperationState.Common.ps1')
    . (Join-Path $InstallRoot 'backend\scripts\BrandCompatibility.Common.ps1')
    $dataRoot=Get-RooIndustriesLocalDataRoot -Protected
    $policy=Join-Path $dataRoot 'cleanup-exclusions.json'
    $beforeStamp=Stamp-Policy
    $beforeBytes=if($beforeStamp.exists){[IO.File]::ReadAllBytes($policy)}else{$null}
    if($beforeStamp.exists -and (Hash-Bytes $beforeBytes) -cne $beforeStamp.sha256){throw 'Original policy changed during private capture'}
    if($beforeStamp.exists){[IO.File]::WriteAllBytes((Join-Path $PrivateDir 'original-policy.bin'),$beforeBytes)}
    $phase='status';Save-Receipt
    $original=Invoke-Installed @{Action='Status'} 'original-status'
    if($null -eq $original.exclusions){throw 'Original exclusion lists absent'}
    Assert-Lists $original.exclusions $original.exclusions
    Check ($(if($beforeStamp.exists){$original.revision -ieq $beforeStamp.sha256 -and (Stamp-Policy).sha256 -ieq $beforeStamp.sha256}else{$null -eq $original.revision -and -not(Stamp-Policy).exists})) 'installed Status revision agrees with the privately captured policy'
    $fixture=Join-Path $PrivateDir 'fixture'
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    $target=Join-Path $fixture 'excluded.txt'
    [IO.File]::WriteAllText($target,'Roo Industries owned exclusion fixture')
    $fixtureLists=[ordered]@{paths=@($original.exclusions.paths)+@($target);registry=@($original.exclusions.registry)}
    $fixtureInput=Join-Path $PrivateDir 'fixture-exclusions.json'
    Write-RooIndustriesOperationJson $fixtureLists $fixtureInput
    $restoreInput=Join-Path $PrivateDir 'original-exclusions.json'
    Write-RooIndustriesOperationJson $original.exclusions $restoreInput
    $phase='save';$mutationAttempted=$true;Save-Receipt
    $saved=Invoke-Installed @{Action='Save';InputPath=$fixtureInput;ExpectedRevision=$original.revision;ConfirmApply=$true} 'fixture-save'
    Assert-Lists $saved.exclusions $fixtureLists
    $null=Assert-OwnedRevision $saved.revision
    $ownedRevision=[string]$saved.revision;Save-Receipt
    Check $true 'confirmed installed Save persists only the original lists plus the private fixture exclusion'
    $phase='stale-save';Save-Receipt
    $stale=$false
    try{Invoke-Installed @{Action='Save';InputPath=$fixtureInput;ExpectedRevision=$original.revision;ConfirmApply=$true} 'unexpected-stale-save'|Out-Null}catch{if($_.Exception.Message -notlike '*Cleanup exclusions changed*'){throw};$stale=$true}
    $null=Assert-OwnedRevision $ownedRevision
    Check $stale 'stale installed Save refuses without changing this proof revision'
    $phase='check';Save-Receipt
    $denied=$false
    try{Invoke-Installed @{Action='Check';FileTarget=@($target)} 'unexpected-allowed-check'|Out-Null}catch{if($_.Exception.Message -notlike '*Excluded path:*'){throw};$denied=$true}
    $null=Assert-OwnedRevision $ownedRevision
    Check $denied 'installed Check refuses the exact excluded private target'
    $phase='restore';Save-Receipt
    $restoredReply=Invoke-Installed @{Action='Save';InputPath=$restoreInput;ExpectedRevision=$ownedRevision;ConfirmApply=$true} 'original-restore'
    Assert-Lists $restoredReply.exclusions $original.exclusions
    $null=Assert-OwnedRevision $restoredReply.revision
    $ownedRevision=[string]$restoredReply.revision;Save-Receipt
    Check $true 'installed Save restores the original exclusion lists with the owned revision'
    if(-not$beforeStamp.exists){
        Assert-Epoch
        $lock=Lock-RooIndustriesOperation $policy
        try{
            $null=Assert-OwnedRevision $ownedRevision
            $restoredDocument=Read-RooIndustriesOperationJson $policy -ExpectedSha256 $ownedRevision
            Assert-Lists $restoredDocument.data.exclusions $original.exclusions
            if(@($original.exclusions.paths).Count -or @($original.exclusions.registry).Count){throw 'Absent original policy had nonempty exclusions'}
            $handle=[RooValidationOwnership.Native]::CreateFile($policy,0,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
            try{if($handle.IsInvalid){throw 'Restored policy identity unavailable'};$fileId=[RooValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
            $ownedFile=[RooValidationOwnership.ProbeFile]::Open($policy,$fileId,$ownedRevision.ToUpperInvariant())
            try{$ownedFile.Remove()}finally{$ownedFile.Dispose()}
        }finally{$lock.Dispose()}
    }
    $afterStamp=Stamp-Policy
    $equal=if($beforeStamp.exists){$afterStamp.exists -and $afterStamp.bytes -eq $beforeStamp.bytes -and $afterStamp.sha256 -ceq $beforeStamp.sha256 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($policy)) -ceq [Convert]::ToBase64String($beforeBytes)}else{-not$afterStamp.exists}
    Check $equal 'exclusions policy is byte-equal to its original file or original absence'
    $restored=$true
    Check ($null -eq [Environment]::GetEnvironmentVariable('DOTNET_ROOT','Process')) 'caller session has no DOTNET_ROOT after installed Status Save Check and restore'
    $phase='completed';$passed=$true;Save-Receipt
}catch{
    if(-not$checks.Count -or $checks[$checks.Count-1].passed){$checks.Add(@{passed=$false;check='installed exclusion proof refused and retained its private receipt'});'FAIL installed exclusion proof refused and retained its private receipt'}
    [IO.File]::WriteAllText((Join-Path $PrivateDir 'failure.txt'),[string]$_,[Text.UTF8Encoding]::new($false))
    Save-Receipt
    throw 'Installed cleanup-exclusions proof failed; inspect its retained private receipt before recovery.'
}finally{
    foreach($pin in $pins){$pin.Dispose()}
    [ordered]@{phase='rf2-installed-cleanup-exclusions';passed=$passed;policyRestored=$restored;checks=@($checks);before=$beforeStamp;after=$afterStamp;dependencies=@($dependencyRows);callerHasDotNetRoot=($null -ne [Environment]::GetEnvironmentVariable('DOTNET_ROOT','Process'));privatePayloadExported=$false;durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}
