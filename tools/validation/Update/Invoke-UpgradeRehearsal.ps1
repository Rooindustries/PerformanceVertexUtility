param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [string]$OldUrl,[string]$OldSha256,[string]$OldVersion,[string]$NewInstaller,[string]$NewVersion,
 [string]$HandoffProbe,[string]$PayloadHashes,[string]$SignedManifest,[switch]$PreflightOnly,[switch]$MoveAsideExistingState,[string]$RestoreStateId,[switch]$LiveFeed)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1'))
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\UpgradeRehearsal.State.ps1'))
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Invoke-UpdateScenario.ps1')) -Source (Get-HarnessToolPath $Source) -OutRoot (Get-HarnessToolPath $OutRoot) -Scenario seed -EvidenceName 'upgrade-rehearsal' -HelpersOnly -InitialDataRoot (Join-Path (Get-RooIndustriesLocalAppData) 'RooIndustriesOptimizationSuite')
$programs=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$desktop=Join-Path $env:PUBLIC 'Desktop'
$oldLinks=@{folder=(Join-Path $programs 'Roo Industries');app=(Join-Path $programs 'Roo Industries\Roo Industries Optimization Suite.lnk');desktop=(Join-Path $desktop 'Roo Industries Optimization Suite.lnk')}
$newLinks=@{folder=(Join-Path $programs 'Performance Vertex Utility');app=(Join-Path $programs 'Performance Vertex Utility\Performance Vertex Utility.lnk');guide=(Join-Path $programs 'Performance Vertex Utility\Beta tester guide.lnk');uninstall=(Join-Path $programs 'Performance Vertex Utility\Uninstall Performance Vertex Utility.lnk');desktop=(Join-Path $desktop 'Performance Vertex Utility.lnk')}
$uninstallKey='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
$script:checks=[Collections.Generic.List[object]]::new()
$script:recording=$null
function Check([string]$name,$observed,[bool]$passed){$script:checks.Add(@{check=$name;status=$(if($passed){'pass'}else{'fail'});observed=$observed});Save 'checks.json' @($script:checks);if(-not$passed){throw ('Check failed: '+$name)}}
function Links($set){$r=@{};foreach($k in $set.Keys){$r[$k]=Test-HarnessPath $set[$k]};$r}
function Target([string]$link){(New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath}
function DataFiles{@(if(Test-HarnessPath $data){Get-HarnessTree $data -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ $data) -and $_.FullName -notlike ($data+'\logs\*') -and $_.FullName -notlike ($data+'\temp\*') -and $_.FullName -notlike ($updates+'\*')}|ForEach-Object {@{path=$_.FullName;sha256=(Get-HarnessFileSha256 $_.LongPath)}}})}
function Setup([string]$file,[string]$arguments,[string]$label){
 Assert-HarnessInstallStart $exe
 $log=Get-HarnessOutputPath $directory ($label+'.log')
 Invoke-RehearsalMutation $stateEntry ('setup:'+ $label) {
  $owned=Start-OwnedProcess -FilePath $file -ArgumentList ($arguments+' /LOG="'+$log+'"') -Purpose $label
  try{if(-not$owned.process.WaitForExit(600000)){throw ($label+' timed out.')};$code=$owned.process.ExitCode}finally{Stop-HarnessProcess $owned}
  Check ($label+' exit code 0') @{exitCode=$code;log=$log} ($code -eq 0)
 }
 return $log
}
function Start-Recording{
 $state=[hashtable]::Synchronized(@{stop=$false;x=0;y=0;w=0;h=0;frames=0;error=$null})
 $path=Get-HarnessOutputPath $directory 'update.mjpeg'
 $ps=[PowerShell]::Create()
 $null=$ps.AddScript({param($state,$path)
  Add-Type -AssemblyName System.Drawing
  $codec=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object MimeType -EQ 'image/jpeg'
  $quality=[Drawing.Imaging.EncoderParameters]::new(1);$quality.Param[0]=[Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality,[long]85)
  $out=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{
   while(-not$state.stop){
    if($state.w -gt 0){$bitmap=[Drawing.Bitmap]::new([int]$state.w,[int]$state.h);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen([int]$state.x,[int]$state.y,0,0,$bitmap.Size);$bitmap.Save($out,$codec,$quality);$state.frames++}finally{$graphics.Dispose();$bitmap.Dispose()}}
    Start-Sleep -Milliseconds 200
   }
  }catch{$state.error=$_.Exception.Message}finally{$out.Dispose()}
 }).AddArgument($state).AddArgument((Get-HarnessLongPath $path))
 $script:recording=@{ps=$ps;handle=$ps.BeginInvoke();state=$state;path=$path}
}
function Follow{$r=$script:window.Current.BoundingRectangle;$s=$script:recording.state;$s.x=[int]$r.X;$s.y=[int]$r.Y;$s.w=[int]$r.Width -band -2;$s.h=[int]$r.Height -band -2}
function Stop-Recording{
 if(-not$script:recording){return}
 $script:recording.state.stop=$true
 try{$script:recording.ps.EndInvoke($script:recording.handle)|Out-Null}finally{$script:recording.ps.Dispose()}
 $recorded=@{path=$script:recording.path;frames=$script:recording.state.frames;intervalMs=200;error=$script:recording.state.error}
 Save 'recording.json' $recorded
 Register-HarnessFile $recorded.path 'recording' 'run'|Out-Null
 $script:recording=$null
 Check 'app-only recording has at least five seconds' $recorded ($recorded.frames -ge 25 -and -not$recorded.error)
}
$paths=@(foreach($name in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){Join-Path (Get-RooIndustriesLocalAppData) $name})
$roots=@($paths)
$paths+=@($oldLinks.folder,$oldLinks.desktop,$newLinks.folder,$newLinks.desktop)
if($RestoreStateId){
 Assert-HarnessHostLease
 if(Test-HarnessPath $uninstallKey){throw 'Remove only the ledger-owned test installation before restoring; retained.'}
 $entry=@(Get-HarnessEntries|Where-Object {$_.id -ceq $RestoreStateId -and $_.purpose -eq 'upgrade-state' -and $_.state -in 'active','error','restored'})
 if($entry.Count -ne 1){throw 'A unique rehearsal state entry is required.'}
 Restore-RehearsalState $entry[0];$persisted=Get-HarnessEntryById $entry[0].id
 if(-not$persisted.metadata.restored -or $persisted.state -cne 'restored'){throw 'Rehearsal restoration is not complete.'}
 Save 'restore-verification.json' @{restored=$persisted.metadata.restored;stateId=$persisted.id}
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null;return
}
$asFound=@{installedVersion=$(if(Test-HarnessPath $uninstallKey){Version}else{$null});installExists=(Test-HarnessPath $install);paths=@($paths|ForEach-Object {Get-RehearsalPathState $_});tasks=@(Get-RehearsalTasks);markers=(Get-RehearsalMarkers $roots)}
Save 'as-found.json' $asFound
$canInstall=-not($asFound.installedVersion -or $asFound.installExists -or @($asFound.paths|Where-Object exists).Count -or $asFound.tasks.Count -or $asFound.markers.values.Count)
Save 'preflight.json' @{canInstall=$canInstall;installerStarted=$false;moveAsideRequested=[bool]$MoveAsideExistingState;handoffOnly=$false;feedDownloadTested=$false}
if($PreflightOnly){
 foreach($row in $asFound.paths){Assert-RehearsalPathState $row $row.path}
 $after=@{paths=@($paths|ForEach-Object {Get-RehearsalPathState $_});tasks=@(Get-RehearsalTasks);markers=(Get-RehearsalMarkers $roots)}
 Save 'preflight-after.json' $after
 Check 'preflight leaves file hashes, tasks and registration unchanged' $after ((Test-RehearsalSnapshot @($after.tasks|Sort-Object {$_.folder},{$_.name}) @($asFound.tasks|Sort-Object {$_.folder},{$_.name})) -and (Test-RehearsalSnapshot $after.markers $asFound.markers))
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null;return
}
if(-not$canInstall -and -not$MoveAsideExistingState){throw 'Existing app state retained. The rehearsal requires an empty installation, data roots, product tasks and shortcuts.'}
if($asFound.installedVersion -or $asFound.installExists){throw 'An existing installation is never moved or uninstalled; retained.'}
Assert-HarnessHostLease
Assert-NoForeignInstance $exe
if(-not$OldUrl -or $OldSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not$OldVersion -or -not$NewInstaller -or -not$NewVersion -or -not$HandoffProbe -or -not$PayloadHashes -or -not$SignedManifest){throw 'Old release identity, candidate, payload hashes, verification probe and signed manifest are required.'}
$env:ROO_HARNESS_NONCE=$nonce
$feed=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'tools\release\update-feed.txt'))).Trim()
$verification=Get-HarnessOutputPath $directory 'signed-input.json'
Invoke-HarnessProcess $HandoffProbe ('"'+$SignedManifest+'" "'+$feed+'" '+$OldVersion+' "'+$verification+'" "'+$NewInstaller+'"') 'verify-signed-input'|Out-Null
Register-HarnessFile $verification 'result' 'run'|Out-Null;$verified=Read-HarnessResult $verification $nonce
Check 'candidate signature and installer verified before mutation' $verified ($verified.result.Kind -eq 2 -and $verified.result.Release.Version -ceq $NewVersion -and $verified.file.Verified)
$oracle=[IO.File]::ReadAllText((Get-HarnessLongPath $PayloadHashes))|ConvertFrom-Json;if($oracle.data){$oracle=$oracle.data}
$sha=Get-HarnessFileSha256 $NewInstaller
if($oracle.installerSha256 -ine $sha -or -not@($oracle.files).Count){throw 'Payload list belongs to another installer or is empty.'}
foreach($file in $oracle.files){if($file.path -notmatch '^[A-Za-z0-9_][A-Za-z0-9_./ -]*$' -or $file.path -match '(^|/)\.\.(/|$)' -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid payload path or hash.'}}
$installParent=Split-Path $install -Parent
$paths+=@($(if(Test-HarnessPath $installParent){$install}else{$installParent}))
if(@(Get-HarnessEntries|Where-Object {$_.purpose -eq 'upgrade-state' -and $_.state -in 'active','error'}).Count){throw 'Restore the earlier rehearsal journal before starting another run.'}
$stateEntry=Save-RehearsalState $paths $roots $exe
Save 'state-journal.json' @{stateId=$stateEntry.id;ledger=$script:Harness.LedgerPath;paths=$stateEntry.metadata.paths}
$status='fail';$installAttempted=$false;$pending=$null
try{
 Suspend-RehearsalState $stateEntry
 Initialize-RehearsalRoots $stateEntry $data
 $selected=Get-RooIndustriesLocalDataRoot -LocalData (Get-RooIndustriesLocalAppData)
 Check 'the product selects the rehearsal data root' @{selected=$selected;expected=$data} ($selected -ieq $data)
 Initialize-HarnessCache $updates @($NewVersion)
 $downloads=Join-Path $directory 'download';New-HarnessDirectory $downloads 'download' 'run'|Out-Null
 $old=Join-Path $downloads ([IO.Path]::GetFileName(([uri]$OldUrl).AbsolutePath))
 [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
 Invoke-WebRequest -UseBasicParsing -Uri $OldUrl -OutFile (Get-HarnessToolPath $old)
 Check 'published old installer has the signed SHA-256' @{path=$old;sha256=(Get-HarnessFileSha256 $old)} ((Get-HarnessFileSha256 $old) -ieq $OldSha256)
 $installAttempted=$true
 Setup $old '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="desktopicon"' 'install-old'|Out-Null
 $before=@{version=Version;key=(Get-ItemProperty $uninstallKey|Select-Object DisplayName,DisplayVersion,InstallLocation,Publisher);old=(Links $oldLinks);new=(Links $newLinks);oldTarget=(Target $oldLinks.app);newTarget=(Target $newLinks.app)}
 Save 'old-installed.json' $before
 Check 'old version installed with its shortcuts' $before ($before.version -ceq $OldVersion -and ($before.old.app -and $before.old.desktop -and $before.oldTarget -ieq $exe -or $before.new.app -and $before.new.desktop -and $before.newTarget -ieq $exe))
 Start-RehearsalApp $stateEntry;Settings
 if($LiveFeed){$current=WaitStatus ('Version '+$NewVersion+' is ready to install') 150}else{$current=WaitStatus 'You have the latest version' 90}
 Shot 'before-old-settings'
 Check 'old app reads the expected live feed' @{status=$current;pid=$script:app.Id;liveDownload=[bool]$LiveFeed} ($current -ceq $(if($LiveFeed){'Version '+$NewVersion+' is ready to install'}else{'You have the latest version'}))
 StopApp
 $ruleRoot=Join-Path $data 'process-rules'
 $fixture=Join-Path $directory 'PerformanceVertexRehearsalGame.exe';Copy-HarnessFile (Join-Path $env:SystemRoot 'System32\PING.EXE') $fixture 'rehearsal-process' 'run'|Out-Null
 $process=Start-OwnedProcess -FilePath $fixture -ArgumentList '-t 127.0.0.1' -Purpose rehearsal-process
 try{
  $operation=Join-Path $data ('operations\rehearsal-'+$nonce)
  [IO.Directory]::CreateDirectory((Get-HarnessLongPath $operation))|Out-Null
  $preview=Join-Path $operation 'preview.json';$journal=Join-Path $operation 'journal.json'
  $originalPriority=(Core 'process-status' @{processId=$process.Identity.pid}).controls.cpuPriority.value
  Core 'process-preview' @{processId=$process.Identity.pid;controls=@{cpuPriority='BelowNormal'};outputPath=$preview}|Out-Null
  Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-HarnessFileSha256 $preview);journalPath=$journal}|Out-Null
  $appliedPriority=(Core 'process-status' @{processId=$process.Identity.pid}).controls.cpuPriority.value
  Core 'process-restore' @{journalPath=$journal;acceptEarlierVersion=$true}|Out-Null
  $restoredPriority=(Core 'process-status' @{processId=$process.Identity.pid}).controls.cpuPriority.value
  Check 'owned probe applies and restores its priority' @{original=$originalPriority;applied=$appliedPriority;restored=$restoredPriority} ($appliedPriority -ceq 'BelowNormal' -and $restoredPriority -ceq $originalPriority)
 }finally{Stop-HarnessProcess $process}
 $rule=@{schemaVersion=1;ruleId=([Guid]::NewGuid().ToString('N'));owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value};name='Upgrade rehearsal';enabled=$false;matchMode='path';executablePath=$fixture;executableHash=$null;cpuSelection=$null;controls=@{cpuPriority='BelowNormal'}}
 $savedRule=Core 'rule-save' @{policyRoot=$ruleRoot;rule=$rule}
 $seed=@(DataFiles);Save 'seed-preservation.json' @{files=$seed;ruleId=$savedRule.ruleId;journal=$journal}
 Check 'saved rule and genuine undo history seeded' @{files=$seed.Count;rule=$savedRule.ruleId;journal=$journal} ($savedRule.ruleId -and (Test-HarnessPath $journal) -and @($seed|Where-Object {$_.path -like '*\rules\*'}).Count -gt 0)
 $folder=Join-Path $updates $NewVersion
 $candidate=Join-Path $folder ('RooIndustries-OptimizationSuite-'+$NewVersion+'-setup.exe')
 if($LiveFeed){
  Check 'old app downloaded the signed live installer' @{path=$candidate;sha256=(Get-HarnessFileSha256 $candidate);bytes=(Get-HarnessItem $candidate).Length} ((Get-HarnessFileSha256 $candidate) -ieq $sha -and (Get-HarnessItem $candidate).Length -eq (Get-HarnessItem $NewInstaller).Length)
  Save 'live-download.json' @{feedDownloadTested=$true;primed=$false;path=$candidate;sha256=$sha}
 }else{
  New-HarnessDirectory $folder 'candidate-ota-cache' 'retained'|Out-Null
  Copy-HarnessFile $NewInstaller $candidate 'candidate-ota-cache' 'retained'|Out-Null
  Copy-HarnessFile $SignedManifest (Join-Path $folder 'manifest.json') 'candidate-signed-manifest' 'retained'|Out-Null
 }
 Start-RehearsalApp $stateEntry;Settings;$ready=WaitStatus ('Version '+$NewVersion+' is ready to install') 15
 Check 'old app accepts signed candidate' @{status=$ready} ($ready -ceq ('Version '+$NewVersion+' is ready to install'))
 Shot 'before-old-ready';$oldApp=$script:owned
 Click 'UpdateInstallButton';WaitFor {ByName 'Install'} 10 'Install confirmation'|Out-Null
 Start-Recording;Follow;Start-Sleep -Seconds 3
 $script:appLogCursor=Get-ShippedLogCursor (Join-Path $data 'logs\app.log');$script:installPressed=[DateTime]::UtcNow;Start-ProcessTrace -Anchor $oldApp|Out-Null
 $script:recording.state.w=0;Start-Sleep -Milliseconds 300
 Assert-HarnessInstallStart $exe;Activate (ByName 'Install')
 $setup=WaitFor {@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $candidate}|ForEach-Object {Test-OwnedDescendant ([int]$_.ProcessId) -Ancestor $oldApp -PassThru})|Select-Object -First 1} 30 'owned update setup'
 $script:setupReceipts.Add($setup)
 $pendingPath=Join-Path $updates 'pending-install.json'
 $pending=[IO.File]::ReadAllText((Get-HarnessLongPath $pendingPath))|ConvertFrom-Json;Save 'pending-install-observed.json' $pending
 Check 'real updater pending record matches both versions' $pending ($pending.fromVersion -ceq $OldVersion -and $pending.toVersion -ceq $NewVersion -and $pending.logPath -ieq (Join-Path $updates ('install-'+$NewVersion+'.log')))
 if(-not$script:app.WaitForExit(30000)){throw 'Owned app did not close for update.'}
 $script:owned=$null;$script:app=$null;$script:window=$null;$script:launchAfter=$script:installPressed
 Attach;Follow;Settings;$updated=WaitStatus ('Updated to version '+$NewVersion) 120;Start-Sleep -Seconds 3;Stop-Recording;Shot 'after-new-settings'
 Check 'new version relaunched with the updated banner' @{status=$updated;pid=$script:app.Id;path=$script:app.Path} ($updated -ceq ('Updated to version '+$NewVersion) -and $script:app.Path -ieq $exe)
 Check 'pending record consumed' @{exists=(Test-HarnessPath $pendingPath)} (-not(Test-HarnessPath $pendingPath))
 $gone=CacheAbsentWithin $NewVersion;Check 'installed update cache removed' $gone $gone.absent
 $after=@{version=Version;key=(Get-ItemProperty $uninstallKey|Select-Object DisplayName,DisplayVersion,InstallLocation,Publisher);old=(Links $oldLinks);new=(Links $newLinks);newTarget=(Target $newLinks.app);desktopTarget=(Target $newLinks.desktop)}
 Save 'new-installed.json' $after
 Check 'same install entry and folder under the new name' @{before=$before.key;after=$after.key} ($after.version -ceq $NewVersion -and $after.key.DisplayName -ceq 'Performance Vertex Utility' -and $after.key.InstallLocation -ieq $before.key.InstallLocation)
 Check 'old shortcuts removed' $after.old (-not($after.old.folder -or $after.old.app -or $after.old.desktop))
 Check 'new shortcuts point at the same app' $after ($after.new.folder -and $after.new.app -and $after.new.guide -and $after.new.uninstall -and $after.new.desktop -and $after.newTarget -ieq $exe -and $after.desktopTarget -ieq $exe)
 $now=@{};foreach($file in DataFiles){$now[$file.path]=$file.sha256}
 $missing=@($seed|Where-Object {-not$now.ContainsKey($_.path)}|ForEach-Object path)
 $changed=@($seed|Where-Object {$now.ContainsKey($_.path) -and $now[$_.path] -ine $_.sha256}|ForEach-Object path)
 Check 'data folder files kept' @{asFound=$seed.Count;missing=$missing;changed=$changed} ($missing.Count -eq 0 -and $changed.Count -eq 0)
 $setupLog=[IO.File]::ReadAllText((Get-HarnessLongPath $pending.logPath))
 $errors=@($setupLog -split "`n"|Where-Object {$_ -match '(?i)\berror\b|\bexception\b' -and $_ -notmatch '^\d{4}-\d{2}-\d{2} .*?\s+(Dest filename|Source filename): '})
 Check 'update setup log has no errors' $errors ($errors.Count -eq 0)
 $rows=@($oracle.files|ForEach-Object {$p=Join-Path $install $_.path;@{path=$_.path;match=([IO.File]::Exists((Get-HarnessLongPath $p)) -and (Get-HarnessFileSha256 $p) -ieq $_.sha256)}})
 Check 'installed files match the new build' @{files=$rows.Count;mismatches=@($rows|Where-Object {-not$_.match}|ForEach-Object path)} ($rows.Count -gt 0 -and @($rows|Where-Object {-not$_.match}).Count -eq 0)
 $rules=@(Core 'rules-list' @{policyRoot=$ruleRoot});Check 'saved rule still readable' $rules (@($rules|Where-Object ruleId -CEQ $savedRule.ruleId).Count -eq 1)
 Click 'UpdateCheckButton';$live=WaitStatus 'You have the latest version' 60;Shot 'after-live-check'
 Check 'new version treats the live feed as current' @{status=$live} ($live -ceq 'You have the latest version')
 Save 'app-log.json' @{log=(Read-ShippedLog $script:appLogCursor)}
 $status='pass'
}finally{
 $cleanup=[Collections.Generic.List[string]]::new()
 try{Stop-Recording}catch{$cleanup.Add($_.Exception.Message)}
 try{StopApp}catch{$cleanup.Add($_.Exception.Message)}
 foreach($process in @($script:setupReceipts)){try{Stop-HarnessProcess $process}catch{$cleanup.Add($_.Exception.Message)}}
 if($installAttempted -and (Test-HarnessPath $uninstallKey)){
  try{Setup (Join-Path $install 'unins000.exe') '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' 'uninstall'|Out-Null}catch{$cleanup.Add($_.Exception.Message)}
 }
 try{
  if(Test-HarnessPath $uninstallKey){throw 'Test installation remains; keep archives and restore only after it is removed.'}
  Stop-RehearsalWriters $stateEntry
  Save-RehearsalOutputs $stateEntry
  Restore-RehearsalState $stateEntry
  $stateEntry=Get-HarnessEntryById $stateEntry.id
  Save 'restore-verification.json' @{restored=$true;stateId=$stateEntry.id;paths=@($paths|ForEach-Object {Get-RehearsalPathState $_});markers=(Get-RehearsalMarkers $roots);tasks=@(Get-RehearsalTasks);archives=$stateEntry.metadata.paths.generated}
 }catch{$cleanup.Add($_.Exception.Message)}
 Save 'end-state.json' @{installedKey=(Test-HarnessPath $uninstallKey);installExists=(Test-HarnessPath $install);restored=$stateEntry.metadata.restored;cleanupErrors=@($cleanup)}
 if($cleanup.Count -or -not$stateEntry.metadata.restored){$status='fail'}
 $status=Complete-HarnessInvocation $status -Cleanup
 if($status -ne 'pass'){throw ('Upgrade rehearsal failed; see checks.json and end-state.json. '+($cleanup -join '; '))}
}
