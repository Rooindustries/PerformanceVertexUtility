param([string]$DotNetPath=$env:ROO_DOTNET_EXE)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$caseId=[Guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-host-contract-'+$caseId)
$hostDirectory=Join-Path $root 'host'
$registrationRoot='Software\Microsoft\Windows\CurrentVersion\Uninstall'
$dataRoot='Software\RooHostFixture-'+$caseId
$apps=@();$reviews=@()
$hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Core([string]$CoreAction,[object]$Fields){
    $request=@{schemaVersion=1;repoRoot=$repoRoot}
    foreach($key in $Fields.Keys){$request[$key]=$Fields[$key]}
    $path=Join-Path $root ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    Write-RooOperationJson $request $path
    $text=@(& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction $path) -join "`n"
    $exitCode=$LASTEXITCODE
    $result=$text|ConvertFrom-Json
    if($exitCode -ne 0 -or $result.status -ne 'completed'){throw ($CoreAction+' failed (exit '+$exitCode+'): '+$result.error.message)}
    return $result.data
}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $hostDirectory|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Optimizer host publish failed.'}
    $remover=Join-Path $root 'RooHostRemover.exe'
    Add-Type @'
using System;
using System.IO;
using Microsoft.Win32;
public class RooHostRemover {
 public static int Main(string[] args) {
  if(args.Length!=3 || !args[0].StartsWith("RooHostFixture-",StringComparison.Ordinal) || !args[2].StartsWith(@"Software\RooHostFixture-",StringComparison.Ordinal) || !Path.GetFullPath(args[1]).StartsWith(Path.GetTempPath(),StringComparison.OrdinalIgnoreCase))return 2;
  using(var root=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall",true))root.DeleteSubKeyTree(args[0],false);
  File.WriteAllText(Path.Combine(args[1],"vendor-created.txt"),"created by fixture vendor");
  using(var key=Registry.CurrentUser.CreateSubKey(args[2]))key.SetValue("VendorCreated",17,RegistryValueKind.DWord);
  return 0;
 }
}
'@ -OutputAssembly $remover -OutputType WindowsApplication
    foreach($label in @('One','Two')){
        $keyName='RooHostFixture-'+$caseId+'-'+$label
        $display='Roo Host '+$label+' '+$caseId.Substring(0,8)
        $install=Join-Path $root ($label+' application files')
        [IO.Directory]::CreateDirectory($install)|Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'preferences.txt'),$label+' original preferences')
        $dataPath=$dataRoot+'\'+$display
        $key=$hive.CreateSubKey($dataPath)
        try {$key.SetValue('Original',$label+' original registry',[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
        $shared=$hive.CreateSubKey($dataRoot+'\SharedReferences')
        try {$shared.SetValue($label,$install,[Microsoft.Win32.RegistryValueKind]::String)}finally{$shared.Dispose()}
        $registration=$hive.CreateSubKey($registrationRoot+'\'+$keyName)
        try {
            $registration.SetValue('DisplayName',$display);$registration.SetValue('Publisher','Roo');$registration.SetValue('DisplayVersion','1.0');$registration.SetValue('InstallLocation',$install)
            $registration.SetValue('UninstallString',('"'+$remover+'" "'+$keyName+'" "'+$install+'" "'+$dataPath+'"'))
        } finally {$registration.Dispose()}
        $apps+=@{keyName=$keyName;displayName=$display;install=$install;dataPath=$dataPath;label=$label}
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
    $applied=Core 'cleanup-batch-apply' @{previewPath=$batchPath;reviewHash=(Get-FileHash -LiteralPath $batchPath -Algorithm SHA256).Hash;journalPath=$batchJournal;confirm=$true}
    Assert ($applied.status -eq 'applied') 'The public batch endpoint completes both reviewed cleanup operations'
    foreach($app in $apps){$key=$hive.OpenSubKey($app.dataPath);try{Assert (-not(Test-Path -LiteralPath $app.install) -and $null -eq $key) 'Independent Windows reads confirm the selected file and registry resources are absent'}finally{if($key){$key.Dispose()}}}
    $restored=Core 'cleanup-batch-restore' @{journalPath=$batchJournal;confirm=$true}
    Assert ($restored.status -eq 'restored') 'The public batch endpoint restores the captured data'
    foreach($app in $apps){
        $key=$hive.OpenSubKey($app.dataPath)
        try {Assert ($key.GetValue('Original') -eq ($app.label+' original registry') -and $key.GetValue('VendorCreated') -eq 17 -and [IO.File]::ReadAllText((Join-Path $app.install 'vendor-created.txt')) -eq 'created by fixture vendor' -and [IO.File]::ReadAllText((Join-Path $app.install 'preferences.txt')) -eq ($app.label+' original preferences')) 'Recovery includes both original and vendor-created leftovers'}finally{$key.Dispose()}
    }
} finally {
    foreach($app in $apps){$hive.DeleteSubKeyTree($registrationRoot+'\'+$app.keyName,$false)}
    foreach($review in $reviews){if($review.preview.registry){$registry=(Get-Content -LiteralPath $review.preview.registry.previewPath -Raw|ConvertFrom-Json);$hive.DeleteSubKeyTree($registry.receipt.keyPath,$false)}}
    $hive.DeleteSubKeyTree($dataRoot,$false);$hive.Dispose()
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Host validation removes its registrations, receipts, binaries, journals and leftovers'
