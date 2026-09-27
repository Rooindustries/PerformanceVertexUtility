param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[switch]$SharedQueuePaths)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$caseId=[Guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-host-contract-'+$caseId)
$hostDirectory=Join-Path $root 'host'
$registrationRoot='Software\Microsoft\Windows\CurrentVersion\Uninstall'
$dataRoot='Software\RooIndustriesHostFixture-'+$caseId
$apps=@();$reviews=@()
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$exclusionPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'cleanup-exclusions.json'
$exclusionBefore=if(Test-Path $exclusionPath){[IO.File]::ReadAllBytes($exclusionPath)}else{$null}
$ownedExclusionHash=$null
$hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Core([string]$CoreAction,[object]$Fields){
    $request=@{schemaVersion=1;repoRoot=$repoRoot}
    foreach($key in $Fields.Keys){$request[$key]=$Fields[$key]}
    $path=Join-Path $root ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    Write-RooIndustriesOperationJson $request $path
    $text=@(& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction $path) -join "`n"
    $exitCode=$LASTEXITCODE
    $result=$text|ConvertFrom-Json
    if($exitCode -ne 0 -or $result.status -ne 'completed'){throw ($CoreAction+' failed (exit '+$exitCode+'): '+$result.error.message)}
    return $result.data
}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $rootSecurity=[Security.AccessControl.DirectorySecurity]::new()
    $rootSecurity.SetAccessRuleProtection($true,$false)
    foreach($sid in 'S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value){$rootSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    ([IO.DirectoryInfo]::new($root)).SetAccessControl($rootSecurity)
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $hostDirectory|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Optimizer host publish failed.'}
    $remover=Join-Path $root 'RooIndustriesHostRemover.exe'
    Add-Type @'
using System;
using System.IO;
using Microsoft.Win32;
public class RooIndustriesHostRemover {
 public static int Main(string[] args) {
  if(args.Length!=3 || !args[0].StartsWith("RooIndustriesHostFixture-",StringComparison.Ordinal) || !args[2].StartsWith(@"Software\RooIndustriesHostFixture-",StringComparison.Ordinal) || !Path.GetFullPath(args[1]).StartsWith(Path.GetTempPath(),StringComparison.OrdinalIgnoreCase))return 2;
  using(var root=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall",true))root.DeleteSubKeyTree(args[0],false);
  File.WriteAllText(Path.Combine(args[1],"vendor-created.txt"),"created by fixture vendor");
  using(var key=Registry.CurrentUser.CreateSubKey(args[2]))key.SetValue("VendorCreated",17,RegistryValueKind.DWord);
  return 0;
 }
}
'@ -OutputAssembly $remover -OutputType WindowsApplication
    foreach($label in @('One','Two')){
        $keyName='RooIndustriesHostFixture-'+$caseId+'-'+$label
        $display='Roo Industries Host '+$label+' '+$caseId.Substring(0,8)
        $install=Join-Path $root ($label+' application files')
        if($SharedQueuePaths -and $label -eq 'Two'){$install=Join-Path $apps[0].install 'Shared add-on'}
        [IO.Directory]::CreateDirectory($install)|Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'preferences.txt'),$label+' original preferences')
        $dataPath=$dataRoot+'\'+$display
        $key=$hive.CreateSubKey($dataPath)
        try {$key.SetValue('Original',$label+' original registry',[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
        $shared=$hive.CreateSubKey($dataRoot+'\SharedReferences')
        try {$shared.SetValue($label,$install,[Microsoft.Win32.RegistryValueKind]::String)}finally{$shared.Dispose()}
        $registration=$hive.CreateSubKey($registrationRoot+'\'+$keyName)
        try {
            $registration.SetValue('DisplayName',$display);$registration.SetValue('Publisher','Roo Industries');$registration.SetValue('DisplayVersion','1.0');$registration.SetValue('InstallLocation',$install)
            $registration.SetValue('UninstallString',('"'+$remover+'" "'+$keyName+'" "'+$install+'" "'+$dataPath+'"'))
        } finally {$registration.Dispose()}
        $apps+=@{keyName=$keyName;displayName=$display;install=$install;dataPath=$dataPath;label=$label}
    }
    if($SharedQueuePaths){
        $key=$hive.OpenSubKey($apps[0].dataPath,$true)
        try {$key.SetValue('SharedOwner',$apps[1].install,[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
    }
    $inventory=(& (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1'))|ConvertFrom-Json
    Assert ($inventory.complete -eq $true) 'Production inventory explicitly reports complete ownership-provider reads'
    foreach($app in $apps){$matches=@($inventory.apps|Where-Object {$_.displayName -ceq $app.displayName});Assert ($matches.Count -eq 1) 'Disposable registration has one exact production inventory identity';$app.appId=$matches[0].appId}
    $planPath=Join-Path $root 'removal-review.json'
    $plan=(& (Join-Path $PSScriptRoot 'New-BulkUninstallPlan.ps1') -AppId @($apps|ForEach-Object {$_.appId}) -OutputPath $planPath)|ConvertFrom-Json
    Assert ($plan.status -eq 'preview') 'Production removal planning accepts the exact disposable registry identities'
    $queue=Join-Path $root 'removal-journal.json'
    $removal=(& (Join-Path $PSScriptRoot 'Invoke-BulkUninstall.ps1') -Action Apply -InputPath $planPath -ReviewSha256 (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -JournalPath $queue -ConfirmApply -ManualReviewApproved)|ConvertFrom-Json
    Assert ($removal.status -eq 'cleanup-review-required' -and @($removal.data.entries|Where-Object {$_.attemptCount -ne 1 -or $_.state -ne 'removed'}).Count -eq 0) 'Both disposable vendor removers finish once through the production queue'
    if($SharedQueuePaths){
        $fresh=(& (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1'))|ConvertFrom-Json
        Assert ($fresh.complete -eq $true -and @($fresh.apps|Where-Object {$_.appId -in @($apps.appId)}).Count -eq 0) 'Both shared-resource owners are absent from fresh installed inventory'
        $scan=Core 'cleanup-scan' @{queueJournalPath=$queue;appId=$apps[0].appId}
        $folder=@($scan.candidates|Where-Object {$_.target -eq $apps[0].install})
        $key=@($scan.candidates|Where-Object {$_.registry.kind -eq 'key' -and $_.registry.keyPath -eq $apps[0].dataPath})
        Assert ($folder.Count -eq 1 -and $folder[0].sharedOwners -contains $apps[1].displayName) 'A removed, unselected queue peer still protects its nested installation files'
        Assert ($key.Count -eq 1 -and $key[0].sharedOwners -contains $apps[1].displayName) 'A removed queue peer still protects whole-key data that references its installation'
        foreach($candidate in @($folder[0],$key[0])){
            $reviewPath=Join-Path $root ([Guid]::NewGuid().ToString('N')+'-rejected-review.json')
            $rejected=$false
            try {Core 'cleanup-preview' @{queueJournalPath=$queue;appId=$apps[0].appId;itemIds=@($candidate.itemId);outputPath=$reviewPath;ownershipReviewed=$true;acceptKeyRecreation=$true}|Out-Null}
            catch {if($_.Exception.Message -notlike '*This leftover is protected, shared or has incomplete ownership evidence*'){throw};$rejected=$true}
            Assert ($rejected -and -not(Test-Path -LiteralPath $reviewPath)) 'Ownership confirmation cannot authorize another removed app''s shared resource'
        }
        $queueBytes=[IO.File]::ReadAllBytes($queue)
        try {
            foreach($invalid in @('missing','mismatched')){
                $changed=[Text.Encoding]::UTF8.GetString($queueBytes).TrimStart([char]0xfeff)|ConvertFrom-Json
                $peer=@($changed.plan.entries|Where-Object {$_.appId -eq $apps[1].appId})[0]
                if($invalid -eq 'missing'){$peer.PSObject.Properties.Remove('appSnapshot');$expected='Removal queue ownership metadata is incomplete.'}
                else {$peer.appSnapshot.appId=$apps[0].appId;$expected='Saved ownership metadata belongs to another queue entry.'}
                Write-RooIndustriesOperationJson $changed $queue
                $rejected=$false
                try {Core 'cleanup-scan' @{queueJournalPath=$queue;appId=$apps[0].appId}|Out-Null}
                catch {if(-not $_.Exception.Message.EndsWith($expected)){throw};$rejected=$true}
                Assert $rejected ('Cleanup rejects '+$invalid+' ownership evidence for an unselected queue peer')
            }
        } finally {[IO.File]::WriteAllBytes($queue,$queueBytes)}
        $key=$hive.OpenSubKey($apps[0].dataPath)
        try {Assert ([IO.File]::ReadAllText((Join-Path $apps[1].install 'preferences.txt')) -eq 'Two original preferences' -and $key.GetValue('SharedOwner') -eq $apps[1].install) 'Rejected cleanup preserves the unselected app''s file and registry evidence'}finally{$key.Dispose()}
    } else {
        foreach($app in $apps){
            $authority=Core 'cleanup-authority' @{queueJournalPath=$queue;appId=$app.appId}
            Assert ($authority.providerQueryComplete -and -not $authority.registrationPresent -and -not $authority.removerRunning -and $authority.removalResolved) 'Native cleanup receives fresh authority from an actual completed remover journal'
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $scan=Core 'cleanup-scan' @{queueJournalPath=$queue;appId=$app.appId}
            Write-Output ('Scan '+$app.label+': '+[Math]::Round($clock.Elapsed.TotalSeconds,2)+' s; '+$scan.registryKeysVisited+' registry keys; '+@($scan.candidates).Count+' candidates; complete='+$scan.complete)
            $selected=@($scan.candidates|Where-Object {($_.target -eq $app.install) -or ($_.registry.keyPath -eq $app.dataPath -and $_.registry.kind -eq 'key') -or ($_.registry.keyPath -eq ($dataRoot+'\SharedReferences') -and $_.registry.valueName -eq $app.label)})
            Assert ($selected.Count -eq 3 -and @($selected|Where-Object {$_.protected -or -not $_.ownershipComplete -or @($_.sharedOwners).Count -gt 0}).Count -eq 0) 'Broad discovery finds the owned folder, whole key and shared-container value'
            $reviewPath=Join-Path $root ($app.label+'-cleanup-review.json')
            $preview=Core 'cleanup-preview' @{queueJournalPath=$queue;appId=$app.appId;itemIds=@($selected|ForEach-Object {$_.itemId});outputPath=$reviewPath;ownershipReviewed=$true;acceptKeyRecreation=$true}
            $reviews+=@{preview=$preview;operation=@{previewPath=$reviewPath;reviewHash=(Get-FileHash -LiteralPath $reviewPath -Algorithm SHA256).Hash;journalPath=(Join-Path $root ($app.label+'-cleanup-journal.json'))}}
        }
        $batchPath=Join-Path $root 'batch-review.json'
        Core 'cleanup-batch-preview' @{cleanupOperations=@($reviews|ForEach-Object {$_.operation});outputPath=$batchPath}|Out-Null
        $batchJournal=Join-Path $root 'batch-journal.json'
        $originalExclusions=Core 'cleanup-exclusions-status' @{}
        $protectedExclusions=@{paths=@($originalExclusions.exclusions.paths)+@((Join-Path $apps[0].install 'preferences.txt'));registry=@($originalExclusions.exclusions.registry)}
        $savedExclusions=Core 'cleanup-exclusions-save' @{exclusions=$protectedExclusions;expectedRevision=$originalExclusions.revision;confirm=$true}
        $ownedExclusionHash=$savedExclusions.revision
        $excluded=Core 'cleanup-batch-apply' @{previewPath=$batchPath;reviewHash=(Get-FileHash -LiteralPath $batchPath).Hash;journalPath=$batchJournal;confirm=$true}
        Assert ($excluded.status -eq 'needsReconciliation' -and $excluded.entries[0].error -like '*Excluded path:*') 'The public batch endpoint enforces exclusions added after review'
        foreach($app in $apps){$key=$hive.OpenSubKey($app.dataPath);try{Assert ((Test-Path (Join-Path $app.install 'preferences.txt')) -and $null -ne $key) 'Late exclusions preserve both applications before deletion'}finally{if($key){$key.Dispose()}}}
        $savedExclusions=Core 'cleanup-exclusions-save' @{exclusions=$originalExclusions.exclusions;expectedRevision=$ownedExclusionHash;confirm=$true}
        $ownedExclusionHash=$savedExclusions.revision
        $applied=Core 'cleanup-batch-apply' @{previewPath=$batchPath;reviewHash=(Get-FileHash -LiteralPath $batchPath -Algorithm SHA256).Hash;journalPath=$batchJournal;confirm=$true}
        Assert ($applied.status -eq 'applied') 'The public batch endpoint completes both reviewed cleanup operations'
        foreach($app in $apps){$key=$hive.OpenSubKey($app.dataPath);try{Assert (-not(Test-Path -LiteralPath $app.install) -and $null -eq $key) 'Independent Windows reads confirm the selected file and registry resources are absent'}finally{if($key){$key.Dispose()}}}
        [IO.File]::WriteAllText($exclusionPath,'{"schemaVersion":1}')
        $ownedExclusionHash=(Get-FileHash $exclusionPath).Hash
        $partial=Core 'cleanup-batch-restore' @{journalPath=$batchJournal;restoreAppIds=@($apps[0].appId);confirm=$true}
        Assert ($partial.status -eq 'partiallyRestored' -and (Test-Path $apps[0].install) -and -not(Test-Path $apps[1].install)) 'Public selective recovery works despite an unreadable exclusion policy and leaves the other app deleted'
        $restored=Core 'cleanup-batch-restore' @{journalPath=$batchJournal;confirm=$true}
        Assert ($restored.status -eq 'restored') 'The public batch endpoint restores the captured data'
        foreach($app in $apps){
            $key=$hive.OpenSubKey($app.dataPath)
            try {Assert ($key.GetValue('Original') -eq ($app.label+' original registry') -and $key.GetValue('VendorCreated') -eq 17 -and [IO.File]::ReadAllText((Join-Path $app.install 'vendor-created.txt')) -eq 'created by fixture vendor' -and [IO.File]::ReadAllText((Join-Path $app.install 'preferences.txt')) -eq ($app.label+' original preferences')) 'Recovery includes both original and vendor-created leftovers'}finally{$key.Dispose()}
        }
    }
} finally {
    try {
        if($ownedExclusionHash){
            if(-not(Test-Path $exclusionPath) -or (Get-FileHash $exclusionPath).Hash -ne $ownedExclusionHash){throw 'Cleanup settings changed outside the fixture; current exclusions were preserved'}
            if($null -eq $exclusionBefore){Remove-Item -LiteralPath $exclusionPath}else{[IO.File]::WriteAllBytes($exclusionPath,$exclusionBefore)}
        }
    } finally {
        foreach($app in $apps){$hive.DeleteSubKeyTree($registrationRoot+'\'+$app.keyName,$false)}
        foreach($review in $reviews){if($review.preview.registry){$registry=(Get-Content -LiteralPath $review.preview.registry.previewPath -Raw|ConvertFrom-Json);$hive.DeleteSubKeyTree($registry.receipt.keyPath,$false)}}
        $hive.DeleteSubKeyTree($dataRoot,$false);$hive.Dispose()
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}
Assert (-not(Test-Path -LiteralPath $root)) 'Host validation removes its registrations, receipts, binaries, journals and leftovers'
if(-not $SharedQueuePaths){& $PSCommandPath -DotNetPath $DotNetPath -SharedQueuePaths}
