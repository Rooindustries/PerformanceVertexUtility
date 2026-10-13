param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[switch]$Hold,[switch]$TimeoutOnly,[switch]$CacheOnly,[switch]$TrackingOnly)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'harness-checks' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'checks'
if(@($Hold,$TimeoutOnly,$CacheOnly,$TrackingOnly|Where-Object {$_}).Count -gt 1){throw 'Choose only one harness check mode.'}
if($Hold){Write-HarnessResult $directory 'holding.json' @{pid=$PID;nonce=$nonce}|Out-Null;Start-Sleep -Seconds 30;Complete-HarnessInvocation 'pass' -Cleanup|Out-Null;return}
$rows=[Collections.Generic.List[object]]::new();$status='fail';$main=$script:Harness
function Passed([string]$Name,$Value){$rows.Add(@{check=$Name;status='pass';observed=$Value})}
function Rejected([string]$CaseName,[scriptblock]$Action,[scriptblock]$Unchanged){
 $message=$null;try{& $Action}catch{$message=$_.Exception.Message}
 $retained=[bool](& $Unchanged)
 if(-not$message -or -not$retained){throw ($CaseName+' did not safely refuse: '+$message+'; unchanged='+$retained)}
 Passed $CaseName $message
}
function Fixture([string]$Name,[string]$Text='untouched'){
 $folder=Join-Path $directory $Name;New-HarnessDirectory $folder 'targeted-fixture'|Out-Null
 $file=Join-Path $folder 'keep.txt';New-HarnessText $file $Text 'targeted-fixture'|Out-Null;return $folder
}
function CacheLifecycle([string]$Clean,[string]$Version){
 $path=Join-Path $Clean $Version
 [RooHarnessWindow]::CreateDirectory($path);$before=Register-HarnessCache $Version;Remove-HarnessDirectory $path
 if((Register-HarnessCache $Version) -or (Get-HarnessEntryById $before.id).state -cne 'removed'){throw 'App-deleted cache identity was not retired.'}
 [RooHarnessWindow]::CreateDirectory($path);$after=Register-HarnessCache $Version
 if($after.id -ceq $before.id -or $after.identity.creationTimeFileTimeUtc -ceq $before.identity.creationTimeFileTimeUtc){throw 'Recreated cache reused the earlier identity.'}
 Remove-HarnessEntry $after;Passed 'app-deleted cache retires before a later download creates it' @{before=$before.id;after=$after.id;version=$Version}
}
if($TrackingOnly){& (Join-Path $Source 'tools\validation\Update\Invoke-TraceOwnershipChecks.ps1') -Source $Source -OutRoot $OutRoot;return}
if($CacheOnly){
 try{$clean=Fixture 'cache-lifecycle';Initialize-HarnessCache $clean @('4.2.7-beta','4.2.8-beta');CacheLifecycle $clean '4.2.8-beta';$status='pass'}
 finally{$status=Complete-HarnessInvocation $status -Cleanup;Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows)}|Out-Null}
 return
}
if($TimeoutOnly){
 try{
  $message="Couldn't check for updates. The request timed out."
  $values=@(foreach($seconds in 17.9,18,30,30.1){@{text=$message;seconds=$seconds;accepted=(Test-ShippedRequestTimeout $message $seconds)}})
  if($values[0].accepted -or -not$values[1].accepted -or -not$values[2].accepted -or $values[3].accepted -or (Test-ShippedRequestTimeout "Couldn't check for updates. Other failure." 20)){throw 'Hanging-network predicate accepts an incorrect status or deadline.'}
  Passed 'F12 hanging check requires the exact request timeout at 18 through 30 seconds' $values;$status='pass'
 }finally{$status=Complete-HarnessInvocation $status -Cleanup;Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows)}|Out-Null}
 return
}
function ForeignScope{
 $root='C:\RooBuild\roo-industries-harness-'+[Guid]::NewGuid().ToString('N')
 $entry=New-HarnessDirectory $root 'foreign-ledger-fixture'
 $id=$root.Substring($root.Length-32);$manifest='0'*64
 $ledger=@{protocol='roo-harness-ledger/v1';machine=$env:COMPUTERNAME;frameId=$id;manifestSha256=$manifest;entries=@();invocations=@()}
 $stream=[IO.FileStream]::new((Join-Path $root 'ledger.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 20));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
 Open-HarnessRun $root $id $manifest ([Guid]::NewGuid().ToString('N'))
 return @{scope=$script:Harness;rootEntry=$entry}
}
function LongFrame([bool]$Unrecorded){
 $root='C:\RooBuild\roo-industries-long-path-'+[Guid]::NewGuid().ToString('N')
 New-HarnessDirectory $root 'long-path-fixture' 'invocation'|Out-Null
 $source=Join-Path $root 'source';New-HarnessDirectory $source 'long-path-source' 'invocation'|Out-Null
 $id=$root.Substring($root.Length-32)
 $manifestPath=Join-Path $source 'source-verification.json'
 New-HarnessText $manifestPath (@{frameId=$id;files=@{}}|ConvertTo-Json) 'long-path-manifest' 'invocation'|Out-Null
 $path=$root
 foreach($segment in @(('a'*80),('b'*80),('c'*80))){$path=Join-Path $path $segment;New-HarnessDirectory $path 'long-path-fixture' 'invocation'|Out-Null}
 $file=Join-Path $path 'long-evidence.json'
 New-HarnessText $file (@{nonce=$nonce;value='long path bytes'}|ConvertTo-Json) 'long-path-file' 'invocation'|Out-Null
 if($file.Length -lt 300 -or $path.Length -lt 300){throw 'Fixture did not reach the long path.'}
 $owned=@(Get-HarnessEntries|Where-Object {$_.state -eq 'active' -and $_.identity.path -and ($_.identity.path -ieq $root -or $_.identity.path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))})
 $entries=@($owned|ForEach-Object {$copy=$_|ConvertTo-Json -Depth 30|ConvertFrom-Json;if($copy.kind -eq 'folder'){$copy.purpose='source-frame'};if(-not$Unrecorded -or $copy.identity.path -notin @($path,$file)){$copy}})
 $ledgerPath=Join-Path $root 'ledger.json'
 $ledger=@{protocol='roo-harness-ledger/v1';machine=$env:COMPUTERNAME;frameId=$id;manifestSha256=(Get-HarnessFileSha256 $manifestPath).ToLowerInvariant();entries=$entries;invocations=@()}
 New-HarnessText $ledgerPath ($ledger|ConvertTo-Json -Depth 60) 'long-path-ledger' 'invocation'|Out-Null
 return @{root=$root;path=$file;unrecordedDirectory=$path;ledger=$ledgerPath;owned=@(Get-HarnessEntries|Where-Object {$_.state -eq 'active' -and $_.identity.path -and ($_.identity.path -ieq $root -or $_.identity.path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))})}
}
function CloseLongFrame($Fixture){
 $closed=& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $Fixture.root -ExpectedMachine $env:COMPUTERNAME|ConvertFrom-Json
 $script:Harness=$main
 if([IO.Directory]::Exists((Get-HarnessLongPath $Fixture.root)) -or @($closed.entries|Where-Object state -EQ 'active').Count){throw 'Long frame or active ledger entry remained.'}
 foreach($entry in $Fixture.owned){Set-HarnessEntryState $entry.id 'removed'}
 return $closed
}
try{
 $fixture=Fixture 'present-data';$sentinel=Join-Path $fixture 'keep.txt'
 Rejected 'active current data root present in preflight' {Move-ShippedFreshData $fixture @{dataRoots=@(@{path=$fixture;exists=$true})} (Join-Path $directory 'moved-data')} {[IO.File]::ReadAllText($sentinel) -ceq 'untouched'}
 $staleP0=@{dataRoots=@(@{path=$fixture;exists=$false})}
 $p5=@{dataRoots=@(@{path=$fixture;exists=(Test-Path $fixture)})}
 Rejected 'F1 P5 resnapshot refuses root created since P0' {Assert-HarnessFreshData $fixture $p5} {[IO.File]::ReadAllText($sentinel) -ceq 'untouched' -and -not$staleP0.dataRoots[0].exists}
 $foreign=ForeignScope
 $name='RooTest-ShippedOffline-'+[Guid]::NewGuid().ToString('N');$foreignNonce='OtherOwner-'+[Guid]::NewGuid().ToString('N')
 New-ShippedFirewall $name $foreignNonce "$env:SystemRoot\System32\PING.EXE"
 $script:Harness=$main
 Rejected 'existing offline firewall rule retained' {try{New-ShippedFirewall $name 'different-owner' "$env:SystemRoot\System32\PING.EXE"}finally{Remove-ShippedFirewall $name 'different-owner' $false}} {(Get-NetFirewallRule -Name $name).Description -ceq $foreignNonce}
 $script:Harness=$foreign.scope;Remove-HarnessEntry (@(Get-HarnessEntries|Where-Object kind -EQ 'firewall')[0]);$script:Harness=$main
 $script:Harness=$foreign.scope
 $image=Join-Path $foreign.scope.Root 'RooHarnessGame.exe';Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $image|Out-Null
 $older=Start-HarnessExplorerProcess $image '-t 127.0.0.1';$script:Harness=$main
 try{
  Rejected 'pre-running app instance retained' {Assert-NoForeignInstance $image} {-not$older.process.HasExited}
  $after=[DateTime]::UtcNow;$second=Start-OwnedProcess -FilePath $image -ArgumentList '-t 127.0.0.1' -Purpose fixture
  try{Rejected 'second fixture with an earlier instance retained' {Get-ShippedFixture $image $after} {-not$older.process.HasExited -and -not$second.process.HasExited}}finally{Stop-HarnessProcess $second}
  Rejected 'earlier fixture instance retained' {Get-ShippedFixture $image $after} {-not$older.process.HasExited}
  Rejected 'Current refuses an app before its check launch window' {Assert-ShippedFreshApp $older.process $after} {-not$older.process.HasExited}
  Rejected 'F2 foreign process cannot be adopted as a descendant' {if(-not(Test-OwnedDescendant $older.Identity.pid)){throw 'Foreign process chain refused'}} {-not$older.process.HasExited}
  Rejected 'F2 process trace refuses a foreign anchor receipt' {Start-ProcessTrace -Anchor $older} {-not$older.process.HasExited}
 }finally{$script:Harness=$foreign.scope;Stop-HarnessProcess $older;$script:Harness=$main}

 $wizardSource=Join-Path $directory 'window-fixture.iss'
 $wizardText=@'
[Setup]
AppName=Roo Industries recovery fixture
AppVersion=1.0
DefaultDirName={tmp}\roo-owned-wizard-fixture
OutputBaseFilename=window-fixture
Uninstallable=no
CreateAppDir=no
PrivilegesRequired=admin
[Code]
procedure InitializeWizard;
var InfoButton: TNewButton;
begin
  WizardForm.Caption := ExpandConstant('{param:FixtureTitle|Setup Roo Industries recovery fixture}');
  InfoButton := TNewButton.Create(WizardForm);
  InfoButton.Parent := WizardForm;
  InfoButton.Caption := 'More info';
  InfoButton.Left := 8;
  InfoButton.Top := 8;
end;
'@
 New-HarnessText $wizardSource $wizardText 'wizard-fixture'|Out-Null
 $iscc=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe';if(-not(Test-Path $iscc)){$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'}
 Invoke-HarnessProcess $iscc ('/Q /O"'+$directory+'" "'+$wizardSource+'"') 'wizard-compile'|Out-Null
 $windowExe=Join-Path $directory 'window-fixture.exe';Register-HarnessFile $windowExe 'window-fixture'|Out-Null
 Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
 foreach($title in 'Setup Roo Industries recovery fixture','Windows protected your PC'){
  $script:Harness=$foreign.scope
  $foreignWindowExe=Join-Path $foreign.scope.Root ([IO.Path]::GetFileName($windowExe))
  if(-not(Test-Path $foreignWindowExe)){Copy-HarnessFile $windowExe $foreignWindowExe|Out-Null}
  $windowProcess=Start-HarnessExplorerProcess $foreignWindowExe ('/FixtureTitle="'+$title+'"') 'explorer-window'
  try{
   $until=[DateTime]::UtcNow.AddSeconds(30);$window=$null
   do{
    foreach($candidate in @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition))){
     if($candidate.Current.ClassName -eq 'TWizardForm' -and $candidate.Current.Name -ceq $title -and (Test-OwnedDescendant ([int]$candidate.Current.ProcessId))){$window=$candidate;break}
    }
    if($window){break};Start-Sleep -Milliseconds 100
   }while([DateTime]::UtcNow -lt $until)
   if(-not$window){throw 'Owned foreign wizard fixture did not render'}
   $windowOwner=Test-OwnedDescendant ([int]$window.Current.ProcessId) -PassThru
   $script:Harness=$main
   if($title -like 'Setup*'){Rejected 'F2 foreign copy-failure TWizardForm is refused' {Register-HarnessWindow $window} {-not$windowOwner.process.HasExited}}
   else{Rejected 'F4 SmartScreen evidence stops without clicking' {Assert-HarnessSmartScreen $window $directory} {-not$windowOwner.process.HasExited -and $window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition).Count -ge 2}}
  }finally{
   $script:Harness=$foreign.scope
   $ownedChildren=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active'});[array]::Reverse($ownedChildren)
   foreach($entry in $ownedChildren){Remove-HarnessEntry $entry};$script:Harness=$main
  }
 }
 $sequence=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $nonce -and $_.purpose -eq 'result'}).Count+1
 $stale=Join-Path $directory ('collision-'+$nonce+'-'+('{0:D4}'-f$sequence)+'.json');New-HarnessText $stale '{"nonce":"earlier","data":"stale"}' 'targeted-fixture'|Out-Null
 Rejected 'F3 existing invocation result is never overwritten or read' {Write-HarnessResult $directory 'collision.json' @{fresh=$true}} {[IO.File]::ReadAllText($stale).Contains('stale')}
 $bound=Write-HarnessResult $directory 'bound.json' @{fresh=$true}
 Rejected 'F3 result reader refuses another nonce' {Read-HarnessResult $bound ('0'*32)} {Test-Path $bound}
 $frame='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N');New-HarnessDirectory $frame 'frame-guard-fixture'|Out-Null
 $stay=Join-Path $frame 'stay.ps1';New-HarnessText $stay 'Start-Sleep -Seconds 180' 'targeted-fixture'|Out-Null
 $owned=Start-OwnedProcess -FilePath powershell.exe -ArgumentList ('-NoProfile -File "'+$stay+'"') -Purpose fixture
 try{Rejected 'frame script in PowerShell command line retained' {Assert-HarnessFrameIdle $frame} {Test-Path $stay}}finally{Stop-HarnessProcess $owned}
 $target=Fixture 'junction-target';$junction='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N')
 New-Item -ItemType Junction -Path $junction -Target $target|Out-Null
 $junctionItem=Get-Item -LiteralPath $junction -Force;$junctionEntry=Add-HarnessEntry 'folder' @{path=$junction;creationTimeFileTimeUtc=$junctionItem.CreationTimeUtc.ToFileTimeUtc().ToString()} 'junction-fixture' 'invocation' @{reparseTarget=$target}
 try{Rejected 'junction frame retained without touching target' {& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $junction -ExpectedMachine $env:COMPUTERNAME} {[IO.File]::ReadAllText((Join-Path $target 'keep.txt')) -ceq 'untouched'}}finally{Remove-HarnessEntry $junctionEntry}
 $unownedDownload=Fixture 'unowned-download'
 $entry=@(Get-HarnessEntries|Where-Object {$_.identity.path -ieq $unownedDownload})[0];Set-HarnessEntryState $entry.id 'retained'
 Complete-HarnessInvocation 'running' -Cleanup|Out-Null
 if(-not(Test-Path (Join-Path $unownedDownload 'keep.txt'))){throw 'Unowned download was removed'}
 Set-HarnessEntryState $entry.id 'active';Passed 'F5 cleanup ignores a download folder absent from the active ledger' $unownedDownload
 $cache=Fixture 'foreign-cache';$version='4.2.8-beta';$folder=Join-Path $cache $version;New-HarnessDirectory $folder 'targeted-fixture'|Out-Null
 Rejected 'F9 foreign B cache is refused and retained' {Initialize-HarnessCache $cache @('4.2.7-beta',$version)} {Test-Path $folder}
 $clean=Fixture 'cache-preflight';Initialize-HarnessCache $clean @('4.2.7-beta',$version)
 $b=Join-Path $clean $version;New-HarnessDirectory $b 'targeted-cache'|Out-Null
 $entry=Register-HarnessCache $version
 if($entry.metadata.version -cne $version){throw 'Reset used a hardcoded version'};Remove-HarnessEntry $entry
 if(Test-Path $b){throw 'Owned actual-version cache remained'};Passed 'F9 reset selects actual B version from preflight' @{version=$version;absent=$true}
 CacheLifecycle $clean $version
 $hosts=Join-Path $directory 'hosts-fixture';$original=[byte[]]@(239,187,191,35,32,195,169,10)
 $stream=[IO.FileStream]::new($hosts,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($original,0,$original.Length)}finally{$stream.Dispose()}
 $marker='# RooShipped-fixture';$line='192.0.2.1 example.test '+$marker
 Add-HarnessHostsLine $hosts $line $marker;Remove-HarnessEntry (@(Get-HarnessEntries|Where-Object {$_.kind -eq 'hosts' -and $_.identity.marker -eq $marker})[0])
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes($hosts)) -cne [Convert]::ToBase64String($original)){throw 'Hosts cleanup changed unrelated bytes.'}
 Passed 'hosts cleanup preserves BOM, UTF-8 and original line endings' 'byte-identical after marked line removal'
 Add-HarnessHostsLine $hosts $line $marker
 $writerCode='$ErrorActionPreference="Stop";for($i=0;$i -lt 100;$i++){try{$f=[IO.FileStream]::new("'+$hosts+'",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$f.Position=$f.Length;$b=[Text.Encoding]::ASCII.GetBytes("SECOND-WRITER");$f.Write($b,0,$b.Length);$f.Dispose();exit 0}catch [IO.IOException]{Start-Sleep -Milliseconds 50}};exit 1'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($writerCode));$script:competingWriter=$null
 Remove-HarnessHostsLine $hosts $line $marker {
  $script:competingWriter=Start-OwnedProcess -FilePath powershell.exe -ArgumentList ('-NoProfile -EncodedCommand '+$encoded) -Purpose competing-hosts-writer
  Start-Sleep -Milliseconds 1000
  if($script:competingWriter.process.HasExited ){throw 'Second writer was not blocked by the exclusive cleanup stream'}
 }
 if(-not$script:competingWriter.process.WaitForExit(10000) -or $script:competingWriter.process.ExitCode -ne 0 -or -not[IO.File]::ReadAllText($hosts).EndsWith('SECOND-WRITER') -or [IO.File]::ReadAllText($hosts).Contains($marker)){throw 'Competing hosts edit did not survive after cleanup'}
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'hosts' -and $_.identity.marker -eq $marker -and $_.state -eq 'active'})[0];Set-HarnessEntryState $entry.id 'removed'
 Passed 'F13 concurrent hosts writer is blocked then its edit survives' 'SECOND-WRITER present after cleanup released its exclusive handle'
 $log=Join-Path $directory 'app.log';[IO.File]::WriteAllText($log,'before');$cursor=Get-ShippedLogCursor $log
 [IO.File]::AppendAllText($log,' old-tail');[IO.File]::Move($log,$log+'.old');[IO.File]::WriteAllText($log,'new-head')
 $read=Read-ShippedLog $cursor;if($read -cne ' old-tailnew-head'){throw 'Rotated log tail was lost.'};Passed 'app-log rotation retains old tail' $read
 $before=@{pid=100;creationTimeUtc='2026-10-01T00:00:00Z'}
 if((Test-ShippedGovernorReplacement $before $before) -or (Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc=$before.creationTimeUtc}) -or (Test-ShippedGovernorReplacement $before @{pid=100;creationTimeUtc='2026-10-02T00:00:00Z'}) -or -not(Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc='2026-10-02T00:00:00Z'})){throw 'Governor identity checks do not discriminate.'}
 Passed 'governor needs new PID and creation time' 'unchanged, PID-only and time-only refused; both changed accepted'
 if((Get-ShippedFinalStatus 'pass' @('Governor pause timeout')) -cne 'fail'){throw 'Cleanup failure was reported as pass.'};Passed 'cleanup error changes a pass to fail' 'Governor pause timeout => fail'
 $script:Harness=$foreign.scope
 Invoke-HarnessLedger {param($ledger) $ledger.invocations=@([pscustomobject]@{nonce=$script:Harness.Nonce;scenario='failed-cleanup-fixture';scope=$script:Harness.Root;status='fail';cleanupErrors=@('Governor pause timeout')})}|Out-Null
 if((Complete-HarnessInvocation 'pass') -cne 'fail'){throw 'The wrapper overwrote a completed cleanup failure.'}
 $script:Harness=$main;Passed 'shared ledger never turns an earlier cleanup failure into pass' 'fail remains fail when the wrapper finishes successfully'
 $nested=Join-Path $directory 'nested-output\builds';New-HarnessDirectory $nested 'nested-output' 'invocation'|Out-Null
 $parent=Split-Path $nested -Parent;Ensure-HarnessOutputDirectory $parent
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -in @($nested,$parent) -and $_.state -eq 'active'})
 if($entries.Count -ne 2 -or -not($entries|Where-Object {$_.identity.path -ieq $parent}).metadata.emptyOnly){throw 'Recursive output creation left an unrecorded ancestor or broad parent cleanup.'}
 try{[RooHarnessWindow]::CreateDirectory($parent);throw 'Atomic directory creation adopted an existing path.'}catch{if($_.Exception.Message -like '*adopted an existing*'){throw}}
 Passed 'nested output records every created ancestor' @{folders=$entries.identity.path;parentCleanup='empty-only';existingNativeCreate='refused'}
 $projectRoot=Fixture 'foreign-build-folder';New-HarnessText (Join-Path $projectRoot 'Example.csproj') '<Project/>' 'project-fixture'|Out-Null
 $script:Harness=$foreign.scope;$foreignBin=Join-Path $projectRoot 'bin';New-HarnessDirectory $foreignBin 'foreign-build'|Out-Null;New-HarnessText (Join-Path $foreignBin 'keep.txt') 'foreign build output'|Out-Null;$script:Harness=$main
 $refusal=$null;try{Initialize-HarnessBuildFolders $projectRoot}catch{$refusal=$_.Exception.Message}
 if($refusal -cne 'An existing build folder is not owned by this run; retained.' -or [IO.File]::ReadAllText((Join-Path $foreignBin 'keep.txt')) -cne 'foreign build output' -or @(Get-HarnessEntries|Where-Object {$_.identity.path -ieq $foreignBin}).Count){throw 'Foreign build folder was not refused for its ownership.'}
 Passed 'foreign generated folder is never adopted by timestamp' $refusal
 $script:Harness=$foreign.scope;$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq (Join-Path $foreignBin 'keep.txt')})[0];Remove-HarnessEntry $entry;$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $foreignBin})[0];Remove-HarnessEntry $entry;$script:Harness=$main
 Initialize-HarnessBuildFolders $projectRoot
 if(@(Get-HarnessEntries|Where-Object {$_.purpose -eq 'generated-build' -and $_.identity.path -in @((Join-Path $projectRoot 'bin'),(Join-Path $projectRoot 'obj'))}).Count -ne 2){throw 'Prepared build folders were not recorded.'}
 $long=LongFrame $false
 $longHash=Get-HarnessFileSha256 $long.path
 $closed=CloseLongFrame $long
 Write-HarnessResult $directory 'long-recorded-closed.json' $closed|Out-Null
 Passed 'CR8 recorded 300+ character frame clears with a closed ledger' @{path=$long.path;length=$long.path.Length;sha256=$longHash;frameGone=$true;activeEntries=0}
 $long=LongFrame $true
 $longHash=Get-HarnessFileSha256 $long.path;$message=$null
 try{& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $long.root -ExpectedMachine $env:COMPUTERNAME|Out-Null}catch{$message=$_.Exception.Message}finally{$script:Harness=$main}
 if($message -notmatch 'Unrecorded frame (file|directory) retained' -or -not($message.Contains($long.path) -or $message.Contains($long.unrecordedDirectory)) -or -not[IO.File]::Exists((Get-HarnessLongPath $long.ledger)) -or (Get-HarnessFileSha256 $long.path) -cne $longHash){throw ('Long unrecorded entry was not safely refused: '+$message)}
 $retained=[IO.File]::ReadAllText((Get-HarnessLongPath $long.ledger))|ConvertFrom-Json
 Write-HarnessResult $directory 'long-unrecorded-retained.json' @{message=$message;path=$long.path;pathLength=$long.path.Length;directory=$long.unrecordedDirectory;hash=$longHash;ledger=$retained}|Out-Null
 Passed 'CR8 unrecorded 300+ character directory and file are retained' @{message=$message;path=$long.path;length=$long.path.Length;sha256=$longHash;ledgerKept=$true}
 foreach($path in @($long.path,$long.unrecordedDirectory)){$entry=@($long.owned|Where-Object {$_.identity.path -ieq $path})[0];Remove-HarnessEntry $entry}
 CloseLongFrame $long|Out-Null
 $long=LongFrame $false
 $archive=Get-HarnessOutputPath $directory 'long-evidence.zip'
 New-HarnessArchive $long.root $archive {param($item,$relative) [IO.Path]::GetExtension($item.FullName) -ieq '.json'}|Out-Null
 $zip=[IO.Compression.ZipFile]::OpenRead((Get-HarnessLongPath $archive))
 $relative=$long.path.Substring($long.root.Length+1).Replace('\','/')
 try{$entry=$zip.GetEntry($relative);if(-not$entry){throw 'Long JSON archive member was omitted.'};$stream=$entry.Open();$reader=[IO.StreamReader]::new($stream);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};if($text -cne [IO.File]::ReadAllText((Get-HarnessLongPath $long.path))){throw 'Long JSON archive bytes differ.'}}finally{$zip.Dispose()}
 Passed 'CR8 archive includes 300+ character JSON with its relative name and bytes' @{path=$long.path;length=$long.path.Length;entry=$relative;archive=$archive;bytesMatch=$true}
 CloseLongFrame $long|Out-Null
 $status='pass'
}finally{
 $script:Harness=$main
 foreach($item in @($foreign.scope.Handles.Values)){if($item){$script:Harness=$foreign.scope;Stop-HarnessProcess $item;$script:Harness=$main}}
 $status=Complete-HarnessInvocation $status -Cleanup
 Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows);nonce=$nonce}|Out-Null
}
'PASS '+$rows.Count+' owned fixture checks'
