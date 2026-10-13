param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][ValidateSet('p2','p2b','release-reset','p3-alpha','p3','p4','p5')][string]$Part,
 [Parameter(Mandatory)][string]$ReleasePath,[string]$OldInstaller='',[string]$OldVersion='',
 [string]$AlphaInstaller='',[string]$AlphaVersion='',[string]$PayloadHashes='',[string]$FrameId='',
 [string]$PreflightPath='',[string]$CandidateInstaller='',[string]$HandoffProbe='',[switch]$HarnessOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1'))
$bootstrapRoot=if($Part -eq 'p5'){Get-RooIndustriesLocalDataRoot -LocalData (Get-RooIndustriesLocalAppData)}else{''}
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Invoke-UpdateScenario.ps1')) -Source (Get-HarnessToolPath $Source) -OutRoot (Get-HarnessToolPath $OutRoot) -Scenario seed -EvidenceName $Part -HelpersOnly -InitialDataRoot $bootstrapRoot
Add-Type -Path (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Background\Oracle.cs'))
$nonce=Initialize-HarnessInvocation $Part $OutRoot
$release=Read-HarnessInputText $ReleasePath|ConvertFrom-Json
$item=$release.payload.installer
$seedPart=if($Part -eq 'p2b'){'p2b'}else{'p2'}
$script:checks=[Collections.Generic.List[object]]::new()
$script:fixtures=[Collections.Generic.List[object]]::new()
$script:extraProcesses=[Collections.Generic.List[object]]::new()
$script:starts=[Collections.Generic.List[object]]::new()
$script:loggedEvents=[Collections.Generic.HashSet[string]]::new()
$script:receiptStatus='running'
$script:freshP5Installed=$false
$script:setupLogs=@{}
$script:governorStarted=$false
$ruleRoot=Join-Path $data 'process-rules'
$logPath=Join-Path $data 'logs\app.log'
$script:partLogCursor=Get-ShippedLogCursor $logPath
$script:appLogCursor=$null
$script:launchAfter=[DateTime]::UtcNow
$script:ownedHandles=$script:Harness.Handles
$script:installPressed=$null
$script:firewallCreated=$false
$script:firewallNonce='RooShipped-'+[Guid]::NewGuid().ToString('N')
$script:hostsMarker='# RooShipped-'+[Guid]::NewGuid().ToString('N')
$script:hostsCreated=$false
$script:completedInstallerDownloads=0
$script:cleanupErrors=[Collections.Generic.List[string]]::new()
$firewallName='RooTest-ShippedOffline-'+$FrameId
$seedPath=$null
function Receipt{
 Save 'receipt.json' @{part=$Part;status=$script:receiptStatus;machine=$env:COMPUTERNAME;frameId=$FrameId;utc=[DateTime]::UtcNow.ToString('o');checks=@($script:checks);release=$release;processStarts=@($script:starts);completedInstallerDownloads=$script:completedInstallerDownloads;cleanupErrors=@($script:cleanupErrors)}
}
function Test-OwnedProcess($ownedProcess){
 if(-not$ownedProcess -or -not$ownedProcess.process -or $ownedProcess.process.HasExited){return $false}
 if(-not$ownedProcess.handle){throw ('Incomplete process ownership receipt: '+$ownedProcess.GetType().FullName+'; fields '+($ownedProcess.PSObject.Properties.Name -join ',')+'; '+$MyInvocation.PositionMessage)}
 return [RooValidationOwnership.Native]::Created($ownedProcess.handle).ToString() -eq $ownedProcess.Identity.creationTimeFileTimeUtc
}
function Check([string]$name,$observed,[bool]$passed,[string]$evidence='receipt.json'){
 $script:checks.Add(@{check=$name;observed=$observed;status=if($passed){'pass'}else{'fail'};evidence=$evidence})
 Receipt
 if(-not$passed){throw ('PRODUCT CHECK FAILED: '+$name)}
}
function Remember-Owned($Process){
 $ownedProcess=Get-HarnessProcess $Process.Id
 if(-not$ownedProcess){$ownedProcess=Test-OwnedDescendant $Process.Id -PassThru}
 if(-not$ownedProcess){throw 'Process is not a verified descendant of this run; retained.'}
 return $ownedProcess
}
function CollectStarts{
 Receive-ProcessTrace
 foreach($entry in @(Get-HarnessEntries|Where-Object {$_.kind -eq 'trace' -and $_.nonce -ceq $nonce})){
  if(-not$script:loggedEvents.Add($entry.identity.eventNonce)){continue}
  $p=$entry.identity
  $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.processId) -ErrorAction SilentlyContinue
  $ours=if($cim){Test-OwnedDescendant ([int]$p.processId)}else{$false}
  if($p.processName -match '(?i)RooIndustries|Optimizer\.|setup|unins|notepad|smartscreen|RooTester' -or $ours){$script:starts.Add(@{pid=$p.processId;parentPid=$p.parentProcessId;image=$p.processName;time=$p.timeCreatedFileTimeUtc;eventNonce=$p.eventNonce;path=$cim.ExecutablePath;arguments=$cim.CommandLine;ownedChain=[bool]$ours})}
 }
 Save 'process-starts-detailed.json' @($script:starts)
}
function Bind-UpdateSetup($ParentOwned,[string]$Installer){
 WaitFor {
  $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $Installer -and $_.CreationDate.ToUniversalTime() -ge $script:installPressed})
  if($matches.Count -gt 1){throw 'Several update setups match; retained.'}
  if($matches.Count -eq 1){$owned=Test-OwnedDescendant ([int]$matches[0].ProcessId) -PassThru;if(-not$owned){throw 'Update setup is not in the owned updater chain; retained.'};Save 'update-setup-parent.json' @{parent=$ParentOwned.Identity;child=$owned.Identity;ownershipProof=$owned.OwnershipProof;installPressed=$script:installPressed.ToString('o')};return $owned}
 } 30 'owned update setup'|Out-Null
}
function Attach{
 $script:app=WaitFor {
  CollectStarts
  $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $exe})
  if($matches.Count -gt 1){throw 'Several app instances; retained.'}
  if($matches.Count -eq 1){
   $match=$matches[0]
   if(-not(Test-OwnedDescendant ([int]$match.ProcessId))){throw 'An app instance is already running that this run did not start; retained.'};if($match.CreationDate.ToUniversalTime() -lt $script:launchAfter){throw 'App predates this launch; retained.'}
   if($script:installPressed -and $match.CreationDate.ToUniversalTime() -lt $script:installPressed){return $null}
   Get-Process -Id $match.ProcessId
  }
 } 150 'owned installed app'
 Assert-ShippedFreshApp $script:app $script:launchAfter
 $script:owned=if($script:installPressed){Test-TracedDescendant $script:app.Id -PassThru}else{Remember-Owned $script:app}
 if(-not$script:owned){throw 'App has no verified ownership proof; retained.'}
 $script:window=WaitFor {
  $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id)))
  if($Part -eq 'p5'){
   foreach($dialog in $windows|Where-Object {$_.Current.ClassName -eq '#32770'}){
    $message=$dialog.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'The earlier data folder was gone, so Roo Industries started fresh. Its saved rules and undo history are no longer available.'))
    if($message){$script:window=$dialog;Save 'as-found-missing-data-notice.json' @{pid=$script:app.Id;message=$message.Current.Name};Shot 'as-found-missing-data-notice';Activate (ByNameControl 'OK' $CT::Button)}
   }
  }
  @($windows|Where-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings'))})|Select-Object -First 1
 } 120 'owned app navigation window'
 Register-HarnessWindow $script:window|Out-Null
 Save 'owned-app.json' @{identity=$script:owned.Identity;ownershipProof=$script:owned.OwnershipProof}
}
function Launch{
 Assert-HarnessHostLease
 Assert-ShippedNoApp $exe
 $script:launchAfter=[DateTime]::UtcNow;$script:installPressed=$null
 $script:appLogCursor=Get-ShippedLogCursor $logPath
 if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $exe}).Count){throw 'An app already runs; stop it before a fresh launch.'}
 Assert-HarnessHostLease
 $script:owned=Start-OwnedProcess -FilePath $exe -WindowStyle Normal -Purpose app
 Attach
}
function Tree{
 @($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;class=$_.Current.ClassName;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled}})
}
function Zone([string]$path){
 $raw=[IO.File]::ReadAllText((Get-HarnessLongPath ($path+':Zone.Identifier')))
 return [string]::new($raw.ToCharArray())
}
function ReleaseCacheEmpty{
 $unexpected=@(UpdateFiles|Where-Object {[IO.Path]::GetDirectoryName($_.path) -ine $updates -or [IO.Path]::GetFileName($_.path) -notlike 'install-*.log'})
 $folders=@(if(Test-HarnessPath $updates){Get-HarnessChildren $updates -Directory})
 return $unexpected.Count -eq 0 -and $folders.Count -eq 0
}
function Wizard([string]$path,[string]$label,[string]$version){
 Assert-HarnessInstallStart $exe
 Start-ProcessTrace|Out-Null
 $foreign=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '(?i)setup.*\.(exe|tmp)$' -and -not(Get-HarnessProcess ([int]$_.ProcessId))})
 if($foreign.Count){throw 'Another non-owned setup is running; retain it.'}
 $existingWindows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.NativeWindowHandle})
 $setupLog=Get-HarnessOutputPath $directory ($label+'-setup.log');$script:setupLogs=@{}+$script:setupLogs;$script:setupLogs[$label]=$setupLog
 $launchResult=Join-Path $directory ($label+'-shell-result-'+$nonce+'.json')
 $launcherPath=Get-HarnessOutputPath $directory ($label+'-shell.ps1')
 if(Test-HarnessPath $launchResult){throw 'Shell result already exists; retained.'}
 $launcher=@'
param([Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Log,[Parameter(Mandatory)][string]$Result,
 [Parameter(Mandatory)][string]$Nonce,[Parameter(Mandatory)][string]$FrameRoot,[Parameter(Mandatory)][string]$FrameId,
 [Parameter(Mandatory)][string]$Manifest,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
Open-HarnessRun $FrameRoot $FrameId $Manifest $Nonce
if(Test-HarnessPath $Result){throw 'Shell result already exists; retained.'}
try{
 $Installer=Get-HarnessToolPath $Installer; $Log=Get-HarnessToolPath $Log; $start=[Diagnostics.ProcessStartInfo]::new($Installer);$start.UseShellExecute=$true;$start.WorkingDirectory=Get-HarnessToolPath ([IO.Path]::GetDirectoryName($Installer));$start.Arguments='/LOG="'+$Log+'"'
 Assert-HarnessInstallStart (Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe')
 $process=[Diagnostics.Process]::Start($start)
 $owned=Register-HarnessStartedProcess $process 'shell-setup'
 $process.WaitForExit()
 $outcome=@{pid=$process.Id;identity=$owned.Identity;status='exited';exitCode=$process.ExitCode}
}catch{$outcome=@{status='failed';error=$_.Exception.ToString()}}
New-HarnessText $Result (@{nonce=$Nonce;data=$outcome}|ConvertTo-Json -Depth 20) 'result' 'run'|Out-Null
if($outcome.status -eq 'failed'){exit 1}
'@
 New-HarnessText $launcherPath $launcher 'shell-launcher'|Out-Null
 $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$launcherPath+'" -Installer "'+$path+'" -Log "'+$setupLog+'" -Result "'+$launchResult+'" -Nonce "'+$nonce+'" -FrameRoot "'+$script:Harness.Root+'" -FrameId "'+$script:Harness.FrameId+'" -Manifest "'+$script:Harness.Manifest+'" -Source "'+$Source+'"'
 Assert-HarnessInstallStart $exe
 $shellOwned=Start-OwnedProcess -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Normal -Purpose shell-launcher
 $shell=$shellOwned.process;$script:extraProcesses.Add($shellOwned)
 Save ($label+'-launch.json') @{path=$path;arguments=('/LOG="'+$setupLog+'"');useShellExecute=$true;launcher=$shellOwned.Identity;result=$launchResult;nonce=$nonce;zone=try{Zone $path}catch{$null}}
 $until=[DateTime]::UtcNow.AddMinutes(10);$seen=[Collections.Generic.HashSet[string]]::new();$number=0;$result=$null
 while([DateTime]::UtcNow -lt $until){
  CollectStarts
  foreach($win in @($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition))){
   if($win.Current.NativeWindowHandle -notin $existingWindows){Assert-HarnessSmartScreen $win $directory}
   if($win.Current.ClassName -eq 'TWizardForm' -and $win.Current.Name -like '*Roo Industries*'){
    $setupOwned=Test-OwnedDescendant ([int]$win.Current.ProcessId) -Ancestor $shellOwned -PassThru
    if(-not$setupOwned){throw 'Wizard belongs to a non-owned setup; retained.'}
    if($win.Current.ProcessId -notin @($script:setupReceipts.Identity.pid)){$script:setupReceipts.Add($setupOwned)}
    $script:window=Register-HarnessWindow $win
    $tree=@(Tree);$button=$null
    foreach($name in 'Finish','Install','Next >','Next'){$candidate=ByNameControl $name $CT::Button;if($candidate -and $candidate.Current.IsEnabled){$button=$candidate;break}}
    $key=if($button){$tree.name -join '|'}else{'install-progress'}
    if($seen.Add($key)){$number++;$shotName=$label+'-page-'+('{0:D2}'-f$number);Save ($shotName+'.json') @{title=$win.Current.Name;controls=$tree;defaultChoicesKept=$true};Shot $shotName;if($button){Activate $button;Start-Sleep -Milliseconds 400}}
   }elseif($win.Current.ClassName -eq '#32770' -and $win.Current.ProcessId -eq $shell.Id){
    if(-not(Test-OwnedDescendant ([int]$win.Current.ProcessId) -Ancestor $shellOwned)){throw 'Shell security warning owner changed; retained.'}
    $script:window=Register-HarnessWindow $win;$number++;Save ($label+'-security-warning-'+$number+'.json') @(Tree);Shot ($label+'-security-warning-'+$number)
    $button=ByNameControl 'Run' $CT::Button
    if($button){Activate $button}else{throw 'Shell security warning did not expose Run.'}
   }elseif($win.Current.ClassName -eq '#32770' -and (Test-OwnedDescendant ([int]$win.Current.ProcessId) -Ancestor $shellOwned)){
    $script:window=Register-HarnessWindow $win;$tree=@(Tree);$key=$tree.name -join '|'
    if($seen.Add($key)){$number++;Save ($label+'-dialog-'+$number+'.json') $tree;Shot ($label+'-dialog-'+$number)}
    $button=ByNameControl 'OK' $CT::Button
    if($button){Activate $button}else{throw ('Installer dialog requires an unplanned choice: '+$key)}
   }
  }
  $recorded=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.purpose -eq 'result' -and $_.identity.path -ieq $launchResult -and $_.nonce -ceq $nonce -and $_.state -eq 'active'})
  if($recorded.Count){$result=Read-HarnessResult $launchResult $nonce}
  if($result.status -eq 'failed'){throw ('ShellExecute failed: '+$result.error)}
  if($result.status -eq 'exited'){break}
  if($shell.HasExited){throw 'Owned shell launcher exited without its nonce-bound result.'}
  Start-Sleep -Milliseconds 100
 }
 CollectStarts
 Check ($label+' wizard completed') @{shell=$result;pages=$number;smartScreen=$false;version=try{Version}catch{$null};defaultCheckboxes=$true} ($result.status -eq 'exited' -and $result.exitCode -eq 0 -and (Version) -eq $version) $setupLog
 $script:window=$null;$script:app=$null;$script:owned=$null
}
function Uninstall{
 Assert-HarnessInstallStart $exe
 $unins=Join-Path $install 'unins000.exe'
 if(-not(Test-HarnessPath $unins)){
  $key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
  if(Test-HarnessPath $key){throw 'Installed uninstaller is missing.'}
  Check 'no current installation to uninstall' @{uninstallerExists=$false;uninstallKeyExists=$false} $true;return
 }
 Assert-HarnessInstallStart $exe
 $ownedProcess=Start-OwnedProcess -FilePath $unins -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+(Get-HarnessOutputPath $directory 'uninstall.log')+'"') -Purpose uninstaller
 $p=$ownedProcess.process
 try{if(-not$p.WaitForExit(360000)){throw 'Uninstall timed out.'};Check 'uninstall completed' $p.ExitCode ($p.ExitCode -eq 0) 'uninstall.log'}finally{Stop-HarnessProcess $ownedProcess}
}
function DownloadPublished{
 $downloadFolder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('Downloads\RooTest-Shipped-'+$nonce)
 if(Test-HarnessPath $downloadFolder){throw 'Owned browser-download folder already exists; retain it.'}
 New-HarnessDirectory $downloadFolder 'browser-download' 'invocation'|Out-Null
 $path=Join-Path $downloadFolder $(if($CandidateInstaller){[IO.Path]::GetFileName($CandidateInstaller)}else{[IO.Path]::GetFileName(([uri]$item.url).AbsolutePath)})
 if(Test-HarnessPath $path){throw 'Published installer download already exists; do not silently repeat the GET.'}
 $clock=[Diagnostics.Stopwatch]::StartNew()
 if($CandidateInstaller){
  if(-not$release.candidateBootstrap){throw 'Local candidate requires explicit candidate-bootstrap metadata.'}
  Copy-HarnessFile $CandidateInstaller $path 'candidate-bootstrap' 'invocation'|Out-Null
 }else{
  Invoke-WebRequest -UseBasicParsing -Uri $item.url -OutFile (Get-HarnessToolPath $path)
  Register-HarnessFile $path 'download' 'invocation'|Out-Null
  $script:completedInstallerDownloads++
 }
 $clock.Stop();[IO.File]::WriteAllText((Get-HarnessLongPath ($path+':Zone.Identifier')), "[ZoneTransfer]`r`nZoneId=3",[Text.Encoding]::ASCII)
 $actual=@{path=$path;url=$item.url;bytes=(Get-HarnessItem $path).Length;sha256=(Get-HarnessFileSha256 $path);seconds=$clock.Elapsed.TotalSeconds;completedInstallerDownloads=$script:completedInstallerDownloads;zone=Zone $path}
 Save 'published-download.json' $actual
 Check $(if($CandidateInstaller){'unpublished candidate staged locally with MOTW; no installer GET'}else{'published installer downloaded on PC'}) $actual ($actual.bytes -eq $item.size -and $actual.sha256 -ieq $item.sha256 -and $actual.zone -match 'ZoneId=3') 'published-download.json'
 return $path
}
function Governor([string]$action){Assert-HarnessHostLease;
 $raw=@(& (Get-HarnessToolPath (Join-Path $install 'backend\scripts\Invoke-ProcessPolicyWorker.ps1')) -Action $action -PolicyRoot (Get-HarnessToolPath $ruleRoot) -ConfirmApply) -join "`n"
 $result=$raw|ConvertFrom-Json
 Save ('governor-'+$action+'.json') $result
 if($result.status -ne 'completed'){throw ('Governor '+$action+': '+$raw)}
 return $result
}
function GovernorRead{
 $status=Core 'policy-status' @{policyRoot=$ruleRoot}
 $process=if($status.hostRunning){Get-CimInstance Win32_Process -Filter ('ProcessId='+$status.state.host.processId)}else{$null}
 @{status=$status;path=$process.ExecutablePath;arguments=$process.CommandLine;productVersion=if($process){(Get-HarnessItem $process.ExecutablePath).VersionInfo.ProductVersion.Trim()}else{$null};sha256=if($process){(Get-HarnessFileSha256 $process.ExecutablePath)}else{$null};pid=$process.ProcessId;creationTimeUtc=if($process){$process.CreationDate.ToUniversalTime().ToString('o')}else{$null};tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,State,@{n='enabled';e={$_.Settings.Enabled}})}
}
function SeedTester{
 Launch;WaitFor {@(Texts) -contains 'Start here'} 90 'baseline Home'|Out-Null
 Check 'baseline app running before seed' @{version=Version;pid=$script:app.Id} ((Version) -eq $OldVersion)
 StopApp
 $fixture=Join-Path $data ('shipped-fixture\'+$nonce);New-HarnessDirectory $fixture 'tester-data' 'retained'|Out-Null
 $target=Join-Path $fixture 'RooTesterGame.exe';Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $target 'tester-data' 'retained'|Out-Null
 $ownedProcess=Start-OwnedProcess -FilePath $target -ArgumentList '-t 127.0.0.1' -Purpose fixture;$p=$ownedProcess.process
 try{$snapshot=Core 'process-status' @{processId=$p.Id};Save 'seed-process-status.json' $snapshot}finally{Stop-HarnessProcess $ownedProcess}
 $text=(@($snapshot.topology|Sort-Object group,index|ForEach-Object {'{0}:{1}:{2}:{3}:{4}:{5}' -f $_.group,$_.index,$_.core,$_.cache,$_.numa,$_.efficiency}) -join ';')
 $sha=[Security.Cryptography.SHA256]::Create();try{$fingerprint=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
 $rule=@{schemaVersion=1;ruleId=([Guid]::NewGuid().ToString('N'));owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value};name='Shipped tester game rule';enabled=$true;matchMode='path';executablePath=$target;executableHash=$null;controls=@{cpuPriority='High';memoryPriority=2;affinity=@{group=0;mask='0x3'}};cpuSelection=$null;affinityTopologyHash=$fingerprint}
 $savedRule=Core 'rule-save' @{policyRoot=$ruleRoot;rule=$rule};Save 'saved-rule.json' $savedRule
 $settings=[IO.File]::ReadAllText((Get-HarnessLongPath $settingsPath))|ConvertFrom-Json;Save 'as-found-settings.json' $settings
 $settings|Add-Member themeId 'roo-industries-blue' -Force;$settings|Add-Member simpleMode '1' -Force;$settings|Add-Member downloadUpdatesAutomatically '1' -Force
 [IO.File]::WriteAllText((Get-HarnessLongPath $settingsPath),($settings|ConvertTo-Json -Compress),$utf8)
 $registry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
 $before=Get-ItemProperty -LiteralPath $registry -Name EnableTransparency -ErrorAction SilentlyContinue
 $option=if($before.EnableTransparency -eq 0){'choice-6b253977ea5987f3'}else{'choice-95a6ed84299d0109'}
 $preview=Join-Path $data ('operations\shipped-tester-tweak-'+[Guid]::NewGuid().ToString('N')+'\preview.json')
 [IO.Directory]::CreateDirectory((Get-HarnessLongPath (Split-Path $preview -Parent)))|Out-Null
 Save 'tester-tweak-before.json' @{settingId='windows.0689e69eedc05770';optionId=$option;original=$before.EnableTransparency}
 $plan=Core 'tweak-preview' @{profileId='shipped-tester';selections=@(@{settingId='windows.0689e69eedc05770';optionId=$option});outputPath=$preview}
 Save 'tester-tweak-preview.json' $plan
 $applied=Core 'tweak-apply' @{previewPath=$preview;reviewHash=(Get-HarnessFileSha256 $preview);confirm=$true};Save 'tester-tweak-apply.json' $applied
 $tweakAfter=(Get-ItemProperty -LiteralPath $registry -Name EnableTransparency).EnableTransparency
 $expected=if($before.EnableTransparency -eq 0){1}else{0}
 Check 'tester tweak applied with independent registry readback' @{before=$before.EnableTransparency;expected=$expected;after=$tweakAfter;changed=$applied.changed} ($applied.changed -and $tweakAfter -eq $expected) 'tester-tweak-apply.json'
 $script:governorStarted=$true;Governor 'Resume'|Out-Null
 WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 60 '0.10 governor starts'|Out-Null
 $files=@([pscustomobject]@{FullName=$settingsPath;LongPath=(Get-HarnessLongPath $settingsPath);Length=[IO.FileInfo]::new((Get-HarnessLongPath $settingsPath)).Length};Get-HarnessTree (Join-Path $ruleRoot 'rules') -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ (Join-Path $ruleRoot 'rules')) -and [IO.Path]::GetDirectoryName($_.FullName) -ieq (Join-Path $ruleRoot 'rules')};Get-HarnessTree (Join-Path $data 'operations') -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ (Join-Path $data 'operations')) -and [IO.Path]::GetFileName($_.FullName) -notlike '*.lock'})
 $baseline=@{files=@($files|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-HarnessFileSha256 $_.LongPath)}});themeId='roo-industries-blue';simpleMode='1';automaticDownloads='1';ruleId=$savedRule.ruleId;fixturePath=$target;controls=$rule.controls;governor=(GovernorRead)}
 Save 'tester-preservation.json' $baseline
 Launch;WaitFor {@(Texts) -contains 'Start here'} 90 'seeded 0.10 Home'|Out-Null;Shot 'seeded-0.10-home'
 Save 'tester-before-upgrade.json' @{appPid=$script:app.Id;governor=(GovernorRead);preservation=$baseline}
 Check 'tester undo data exists' @{operationFiles=@($baseline.files|Where-Object {$_.path -like '*\operations\*'}).Count;tweakResult=$applied.status} (@($baseline.files|Where-Object {$_.path -like '*\operations\*'}).Count -gt 0)
 Check 'old app and governor running at upgrade' @{appPid=$script:app.Id;governor=$baseline.governor} ($baseline.governor.status.hostRunning -eq $true -and -not$script:app.HasExited)
}
function Preservation{
 $baseline=Read-HarnessLatestResult 'tester-preservation.json' $seedPart
 $rows=@($baseline.files|ForEach-Object {$exists=[IO.File]::Exists((Get-HarnessLongPath $_.path));@{path=$_.path;expected=$_.sha256;observed=if($exists){(Get-HarnessFileSha256 $_.path)}else{$null};match=($exists -and (Get-HarnessFileSha256 $_.path) -ieq $_.sha256)}})
 Save 'preservation-readback.json' $rows
 Check 'tester preservation hashes' @{files=$rows.Count;mismatches=@($rows|Where-Object {-not$_.match})} (@($rows|Where-Object {-not$_.match}).Count -eq 0) 'preservation-readback.json'
 $settings=[IO.File]::ReadAllText((Get-HarnessLongPath $settingsPath))|ConvertFrom-Json
 Check 'theme and settings kept' $settings ($settings.themeId -eq $baseline.themeId -and $settings.simpleMode -eq $baseline.simpleMode -and $settings.downloadUpdatesAutomatically -eq $baseline.automaticDownloads)
}
function Payload{
 $oracle=Read-HarnessInputText $PayloadHashes|ConvertFrom-Json
 if($oracle.installerSha256 -ine $item.sha256 -or $oracle.installerSize -ne $item.size){throw 'Payload oracle installer identity differs.'}
 $hashes=@($oracle.files)
 $rows=@($hashes|ForEach-Object {$p=Join-Path $install $_.path;$exists=[IO.File]::Exists((Get-HarnessLongPath $p));@{path=$_.path;expected=$_.sha256;observed=if($exists){(Get-HarnessFileSha256 $p)}else{$null};match=($exists -and (Get-HarnessFileSha256 $p) -ieq $_.sha256)}})
 Save 'payload-readback.json' $rows
 Check 'installed files match published payload' @{files=$rows.Count;mismatches=@($rows|Where-Object {-not$_.match})} ($rows.Count -gt 0 -and @($rows|Where-Object {-not$_.match}).Count -eq 0) 'payload-readback.json'
}
function Current([bool]$pressCheck){
 Assert-ShippedFreshApp $script:app $script:launchAfter
 $cursor=if($pressCheck){Get-ShippedLogCursor $logPath}else{$script:appLogCursor}
 if(-not$cursor){throw 'No app-log cursor for this owned process launch.'}
 Settings
 if($pressCheck){Click 'UpdateCheckButton'}
 $status=WaitStatus 'You have the latest version' 50
 $newLines=Read-ShippedLog $cursor
 $feedVersion=if($release.liveRelease){$release.liveRelease.version}else{$release.payload.version}
 $feedResult='[update] Feed '+([uri]$release.feedUrl).IdnHost+': Current, key '+$release.keyId+', release '+$feedVersion+'. You have the latest version; installed '+(Version)+'.'
 $currentLines=@($newLines -split "`n"|Where-Object {$_ -like '*[[]update] You have the latest version*' -or $_.Contains($feedResult)})
 Save 'current-process-log.json' @{pid=$script:app.Id;creationTimeUtc=$script:app.StartTime.ToUniversalTime().ToString('o');launchAfter=$script:launchAfter.ToString('o');lines=$currentLines;segment=$newLines}
 Check 'Current is a new log result from this owned launch' $currentLines ($currentLines.Count -gt 0 -and $newLines -notmatch '[[]update] Downloading') 'current-process-log.json'
 Shot 'live-feed-current'
 Check 'live feed up to date' @{text=$status;feed=$release.feedUrl;checkButtonPressed=$pressCheck;productVersion=(Get-HarnessItem $exe).VersionInfo.ProductVersion.Trim()} ($status -ceq 'You have the latest version') 'live-feed-current.png'
}
function Versions{
 $actual=@{displayVersion=Version;productVersion=(Get-HarnessItem $exe).VersionInfo.ProductVersion.Trim();runningPid=$script:app.Id;runningPath=$script:app.Path}
 Check 'published version installed and running' $actual ($actual.displayVersion -eq $release.payload.version -and $actual.productVersion -eq $release.payload.version -and -not$script:app.HasExited)
}
function GovernorVerified{
 $governor=GovernorRead;Save 'governor-readback.json' $governor
 $oracle=[IO.File]::ReadAllText((Get-HarnessLongPath $PayloadHashes))|ConvertFrom-Json
 if($oracle.installerSha256 -ine $item.sha256 -or $oracle.installerSize -ne $item.size){throw 'Payload oracle installer identity differs.'}
 $hashes=@($oracle.files)
 $hostHash=($hashes|Where-Object {$_.path -eq 'backend/bin/optimizer/Optimizer.Host.exe'}|Select-Object -First 1).sha256
 Check 'governor enabled and running from new install' @{before=$script:governorBeforeUpgrade;after=$governor} ((Test-ShippedGovernorReplacement $script:governorBeforeUpgrade $governor) -and $governor.status.hostRunning -eq $true -and $governor.path -ieq $hostExe -and $governor.sha256 -ieq $hostHash -and @($governor.tasks|Where-Object enabled).Count -gt 0) 'governor-readback.json'
}
function ShippedFixtureRead($Process){
 $Process.Refresh();@{pid=$Process.Id;name=$Process.ProcessName;path=$Process.Path;startTimeUtc=$Process.StartTime.ToUniversalTime().ToString('o');priorityClass=[string]$Process.PriorityClass;affinityMask=$Process.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($Process);memoryPriority=[RooBackgroundOracle]::Memory($Process)}
}
function ShippedProfileCall([string]$Script,[hashtable]$Arguments){
 $raw=& (Get-HarnessToolPath (Join-Path $install ('backend\scripts\'+$Script+'.ps1'))) @Arguments
 $result=$raw|ConvertFrom-Json
 if($result.errors.Count){throw ($Script+': '+($result.errors|ConvertTo-Json -Depth 10))};return $result
}
function SavedRuleReadback{
 $seed=Read-HarnessLatestResult 'tester-preservation.json' $seedPart
 $governor=GovernorRead
 if(-not$governor.status.hostRunning){throw 'Saved-rule check requires the published governor running.'}
 $attempts=@();$observed=$false;$ownedProcess=$null
 try{
  for($attempt=1;$attempt -le 3;$attempt++){
   $ownedProcess=Start-HarnessExplorerProcess $seed.fixturePath '-t 127.0.0.1' 'saved-rule-fixture';$script:fixtures.Add($ownedProcess)
   $explorerLaunch=$ownedProcess.ExplorerLaunchUtc;$parent=$ownedProcess.ExplorerParent;$p=$ownedProcess.process
   $p.Refresh();$before=@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinity=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}
   $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
   $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$cim.ParentProcessId)
   if([IO.Path]::GetFileName($parent.ExecutablePath) -ine 'explorer.exe'){throw 'Fixture was not launched by desktop Explorer.'}
   $row=@{attempt=$attempt;before=$before;identity=$ownedProcess.Identity;parent=@{pid=$cim.ParentProcessId;image=$parent.ExecutablePath}}
   $distinct=$before.priorityClass -ne 'High' -and $before.affinity -ne 3 -and $before.memoryPriority -ne 2
   if(-not$distinct){$row.outcome='Initial sample already equals at least one target; inconclusive.';$attempts+=@($row);Save 'saved-rule-launch-attempts.json' $attempts;Stop-HarnessProcess $ownedProcess;continue}
   Save 'saved-rule-launch-attempts.json' @($attempts+@($row))
   Check 'fresh game starts with all three controls different from the rule' $row $distinct 'saved-rule-launch-attempts.json'
   $until=[DateTime]::UtcNow.AddSeconds(60)
   do{$p.Refresh();$after=@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinity=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)};if($after.priorityClass -eq 'High' -and $after.affinity -eq 3 -and $after.memoryPriority -eq 2){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until)
   $row.after=$after;$attempts+=@($row);Save 'saved-rule-launch-attempts.json' $attempts
   Save 'saved-rule-independent-readback.json' @{before=$before;after=$after;expected=$seed.controls;parent=$row.parent;attempts=$attempts;governor=$governor}
   Check 'fresh game receives saved controls' $after ($after.priorityClass -eq 'High' -and $after.affinity -eq 3 -and $after.memoryPriority -eq 2) 'saved-rule-independent-readback.json'
   Stop-HarnessProcess $ownedProcess;$observed=$true;break
  }
  if(-not$observed){throw 'Harness could not sample three distinct initial control values in three desktop launches.'}
 }finally{
  if($ownedProcess){Stop-HarnessProcess $ownedProcess}
 }
}
function AppLog{
 $segment=Read-ShippedLog $script:partLogCursor
 New-HarnessText (Get-HarnessOutputPath $directory 'app-log-new.txt') $segment 'app-log-evidence'|Out-Null
 $errors=@($segment -split "`n"|Where-Object {$_ -match 'Exception|Unhandled|\[fatal\]'})
 Check 'app log has no exceptions' $errors ($errors.Count -eq 0) 'app-log-new.txt'
 $logged=@($segment -split "`n"|Where-Object {$_ -like '*[[]update]*'})
 Save 'update-log-lines.json' $logged
 $hasFeedDetail=$segment.Contains('[update] Feed '+([uri]$release.feedUrl).IdnHost+': ') -and $segment.Contains(', key '+$release.keyId)
 $script:checks.Add(@{check='app log fetch/keyId/Current detail';status=if($hasFeedDetail){'pass'}else{'unverified'};observed=@{lines=$logged;source='Older releases log only the reason; newer releases log the feed host and verified key.'};evidence='update-log-lines.json'})
}
function Remove-ShippedHosts{
 if(-not$script:hostsCreated){return}
 $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'hosts' -and $_.identity.marker -ceq $script:hostsMarker -and $_.state -eq 'active'});if($entry.Count -ne 1){throw 'Hosts line is not in this creation ledger; retained.'};Assert-HarnessHostLease;Remove-HarnessEntry $entry[0]
 $script:hostsCreated=$false
}

function HangingNetwork{
 $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$hostName=([uri]$release.feedUrl).DnsSafeHost
 $begin=[DateTime]::UtcNow
 $line='192.0.2.1 '+$hostName+' '+$script:hostsMarker;$script:hostsLine=$line
 try{
  Assert-HarnessHostLease;Add-HarnessHostsLine $path $line $script:hostsMarker;$script:hostsCreated=$true
  if(-not[IO.File]::ReadAllText((Get-HarnessLongPath $path)).Contains($line)){throw 'Owned hosts entry was reverted.'}
  Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\ipconfig.exe') '/flushdns' 'flush-dns'|Out-Null
 }catch{
  Save 'hosts-edit-failure.json' @{error=$_.Exception.Message;events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';StartTime=$begin.ToLocalTime()} -ErrorAction SilentlyContinue|Select-Object TimeCreated,Id,Message)}
  throw
 }
 Save 'hanging-hosts-entry.json' @{entry=$line;createdAtUtc=$begin.ToString('o')}
 Launch;Settings
 $clock=[Diagnostics.Stopwatch]::StartNew();Click 'UpdateCheckButton';WaitStatus 'Checking for updates...' 5|Out-Null
 $pages=@()
 foreach($page in 'Home','Games','Settings'){
  if($page -eq 'Home' -and (StatusText) -ne 'Checking for updates...'){throw 'Hanging check ended before the navigation control.'}
  $started=$clock.Elapsed.TotalSeconds;Activate (ByName $page)
  if($page -eq 'Home'){WaitFor {@(Texts) -contains 'Start here'} 5 'hanging Home'|Out-Null}
  elseif($page -eq 'Games'){WaitFor {ById 'GamesTab'} 5 'hanging Games'|Out-Null}
  else{WaitFor {ById 'UpdateStatusText'} 5 'hanging Settings'|Out-Null}
  $pages+=@{page=$page;startedSeconds=$started;renderedSeconds=$clock.Elapsed.TotalSeconds;pid=$script:app.Id}
  if($page -eq 'Settings' -and (StatusText) -ne 'Checking for updates...'){throw 'Hanging check ended before Settings rendered.'}
  Shot ('hanging-'+$page.ToLowerInvariant())
 }
 $status=WaitStatus "Couldn't check for updates. The request timed out." ([Math]::Max(1,30-[int]$clock.Elapsed.TotalSeconds))
 $clock.Stop();Shot 'hanging-timeout'
 Check 'navigation renders during a hanging network check' $pages ($pages.Count -eq 3) 'hanging-settings.png'
 Check 'hanging check reports timeout within 30 seconds' @{text=$status;seconds=$clock.Elapsed.TotalSeconds;alive=(-not$script:app.HasExited)} (Test-ShippedRequestTimeout $status $clock.Elapsed.TotalSeconds) 'hanging-timeout.png'
 if(-not[IO.File]::ReadAllText((Get-HarnessLongPath $path)).Contains($line)){throw 'Owned hosts entry was reverted during the test.'}
 Remove-ShippedHosts
 Check 'owned hosts entry removed' @{marker=$script:hostsMarker;exists=[IO.File]::ReadAllText((Get-HarnessLongPath $path)).Contains($script:hostsMarker)} (-not[IO.File]::ReadAllText((Get-HarnessLongPath $path)).Contains($script:hostsMarker))
 Current $true
}
function RestoreFreshP5Installation{
 if(-not$script:freshP5Installed){return}
 $now=Get-HarnessMachineSnapshot;Save 'p5-before-uninstall.json' $now
 if($now.installedVersion -cne $release.payload.version){throw 'The fresh installation changed before cleanup; retained.'}
 Assert-NoForeignInstance $exe
 Payload
 CollectStarts
 foreach($process in $script:extraProcesses){Stop-HarnessProcess $process}
 Uninstall
 WaitFor {-not(Test-HarnessPath $install)} 20 'uninstaller final directory removal'|Out-Null
 $active=Get-RooIndustriesLocalDataRoot
 Check 'uninstaller leftovers before harness cleanup' @{activeRoot=$active;dataExists=(Test-HarnessPath $active);installExists=(Test-HarnessPath $install);dataFiles=@(if(Test-HarnessPath $active){Get-HarnessTree $active -FilesOnly|Where-Object {Test-HarnessVisiblePath $_ $active}|Select-Object FullName,Length})} $true
 if(Test-HarnessPath $active){Move-ShippedFreshData $active $before (Join-Path $directory 'removed-test-data')}
 $tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,State)
 $services=@(Get-Service|Where-Object {$_.Name -match 'RooIndustries|RooOptimizationSuite'}|Select-Object Name,Status)
 Check 'fresh-install uninstall leaves no Suite tasks services files or data' @{tasks=$tasks;services=$services;installExists=(Test-HarnessPath $install);dataExists=(Test-HarnessPath $data);dataArchived=(Join-Path $directory 'removed-test-data')} ($tasks.Count -eq 0 -and $services.Count -eq 0 -and -not(Test-HarnessPath $install) -and -not(Test-HarnessPath $data))
 $script:freshP5Installed=$false
}
if($HarnessOnly){return}
try{
 Receipt
 switch($Part){
  'p2'{
   if(-not$PayloadHashes -or -not$OldInstaller -or -not$OldVersion){throw 'p2 requires PayloadHashes, OldInstaller and OldVersion.'}
   Save 'as-found-updates.json' @(UpdateFiles)
   Initialize-HarnessCache $updates @($release.payload.version,($release.payload.version.Split('-')[0]+'-alpha'))
   Uninstall
   Wizard $OldInstaller 'baseline' $OldVersion
   SeedTester
   $oldApp=$script:owned
   $published=DownloadPublished
   $script:governorBeforeUpgrade=GovernorRead;Save 'governor-immediately-before-upgrade.json' $script:governorBeforeUpgrade
   try{Wizard $published 'published' $release.payload.version}catch{
    if(-not$CandidateInstaller -or $_.Exception.Message -notlike 'SmartScreen shown;*'){throw}
    Save 'candidate-smartscreen-release-fact.json' @{shown=$true;action='owned launcher canceled; SmartScreen was never clicked';candidate=$published}
    foreach($ownedLauncher in @($script:extraProcesses|Where-Object {$_.Purpose -eq 'shell-launcher' -or $_.Identity.imagePath -like '*powershell.exe'})){Stop-HarnessProcess $ownedLauncher}
    if((Version) -cne $OldVersion){throw 'SmartScreen cancellation changed the installed baseline; retained.'}
    [IO.File]::Delete((Get-HarnessLongPath ($published+':Zone.Identifier')))
    Save 'candidate-without-motw.json' @{candidate=$published;sha256=Get-HarnessFileSha256 $published;label='P2 completed without MOTW after SmartScreen refusal'}
    Wizard $published 'published-without-motw' $release.payload.version
    $script:setupLogs['published']=$script:setupLogs['published-without-motw']
   }
   Check 'installer closed old app automatically' $oldApp.Identity (-not(Test-OwnedProcess $oldApp))
   $script:governorStarted=$true
   WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 70 'enabled governor resumes'|Out-Null
   Launch;Versions;Payload;Preservation;GovernorVerified;SavedRuleReadback;Current $false
   $files=@(UpdateFiles);$segment=Read-ShippedLog $script:appLogCursor;Check 'up-to-date check starts no download and leaves no release cache' @{files=$files;log=$segment} ((ReleaseCacheEmpty) -and ($segment -like '*[[]update] You have the latest version*' -or $segment -like '*: Current, key *You have the latest version; installed *') -and $segment -notmatch '[[]update] Downloading')
   $setupLog=[IO.File]::ReadAllText((Get-HarnessLongPath $script:setupLogs['published']))
   $candidates=@($setupLog -split "`n"|Where-Object {$_ -match '(?i)\berror\b|\bexception\b'})
   $errors=@($candidates|Where-Object {$_ -notmatch '^\d{4}-\d{2}-\d{2} .*?\s+(Dest filename|Source filename): '})
   Save 'setup-error-audit.json' @{errors=$errors;filenameLines=@($candidates|Where-Object {$_ -notin $errors})}
   Check 'published setup log has no errors' $errors ($errors.Count -eq 0) 'setup-error-audit.json'
   AppLog
  }
  'p2b'{
   if(-not$CandidateInstaller -or -not$PayloadHashes -or -not$OldInstaller -or -not$OldVersion -or -not$HandoffProbe){throw 'p2b requires candidate, baseline, payload and handoff probe inputs.'}
   Initialize-HarnessCache $updates @($release.payload.version)
   Uninstall
   if($release.liveRelease.version -cne $OldVersion){throw 'P2b baseline differs from the independently verified live release.'}
   $candidateInput=$CandidateInstaller;$candidateMetadata=$item
   try{
    $CandidateInstaller='';$item=$release.liveRelease.installer;$publishedBaseline=DownloadPublished
    if((Get-HarnessFileSha256 $publishedBaseline) -cne (Get-HarnessFileSha256 $OldInstaller)){throw 'Live baseline bytes differ from the supplied verified baseline.'}
   }finally{$CandidateInstaller=$candidateInput;$item=$candidateMetadata}
   Wizard $publishedBaseline 'published-baseline' $OldVersion;SeedTester
   $folder=Join-Path $updates $release.payload.version
   New-HarnessDirectory $folder 'candidate-ota-cache' 'invocation'|Out-Null
   $candidate=Join-Path $folder ([IO.Path]::GetFileName($CandidateInstaller));Copy-HarnessFile $CandidateInstaller $candidate 'candidate-ota-cache' 'invocation'|Out-Null
   $oldApp=$script:owned;$script:governorBeforeUpgrade=GovernorRead;Save 'governor-immediately-before-upgrade.json' $script:governorBeforeUpgrade
   $script:appLogCursor=Get-ShippedLogCursor $logPath;$script:installPressed=[DateTime]::UtcNow;Start-ProcessTrace -Anchor $oldApp|Out-Null
   $result=Get-HarnessOutputPath $directory 'handoff.json'
   $env:ROO_HARNESS_NONCE=$nonce
   $arguments='--installer-handoff "'+$exe+'" '+$script:app.Id+' "'+$candidate+'" '+$release.payload.version+' '+$item.size+' '+$item.sha256+' "'+$updates+'" "'+$result+'"'
   Assert-HarnessInstallStart $exe
   $probe=Start-OwnedProcess -FilePath $HandoffProbe -ArgumentList $arguments -Purpose candidate-handoff
   $script:extraProcesses.Add($probe)
   WaitFor {if(Test-HarnessPath $result){Get-HarnessFileSha256 $result}} 30 'nonce-bound handoff receipt'|Out-Null
   Register-HarnessFile $result 'result' 'run'|Out-Null;$handoff=Read-HarnessResult $result $nonce
   $setup=Test-OwnedDescendant ([int]$handoff.setupPid) -Ancestor $probe -PassThru
   if(-not$setup -or $setup.Identity.creationTimeFileTimeUtc -cne $handoff.setupCreationTimeFileTimeUtc){throw 'Candidate setup does not belong to the owned handoff probe'}
   $script:setupReceipts.Add($setup);Save 'handoff-observed.json' $handoff
   $pendingPath=Join-Path $updates 'pending-install.json';Register-HarnessFile $pendingPath 'candidate-pending-install' 'invocation'|Out-Null
   $pending=[IO.File]::ReadAllText((Get-HarnessLongPath $pendingPath))|ConvertFrom-Json;Save 'pending-install-observed.json' $pending
   $fields=@($pending.PSObject.Properties.Name|Sort-Object)
   Check 'pending record has exact shipped fields and values' $pending (($fields -join ',') -ceq 'fromVersion,logPath,startedAtUtc,toVersion' -and $pending.fromVersion -ceq $OldVersion -and $pending.toVersion -ceq $release.payload.version -and $pending.logPath -ceq $handoff.pending.LogPath)
   Check 'stand-in uses exact pending schema and installer launch' $handoff ($handoff.pending.FromVersion -eq $OldVersion -and $handoff.pending.ToVersion -eq $release.payload.version -and $handoff.Arguments -ceq ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG="'+$handoff.pending.LogPath+'" /ROORELAUNCH=1 /ROOWAITPID='+$oldApp.Identity.pid) -and -not$handoff.UseShellExecute)
   if(-not$script:app.CloseMainWindow()){throw 'Owned app refused a clean window close'}
   if(-not$script:app.WaitForExit(20000)){throw 'Owned app did not close cleanly'}
   Check 'stand-in closes the owned app cleanly' $oldApp.Identity $script:app.HasExited
   $script:owned=$null;$script:app=$null;$script:window=$null;$script:launchAfter=$script:installPressed
   Attach;Settings;$updated=WaitStatus ('Updated to version '+$release.payload.version) 90;Shot 'candidate-ota-updated'
   Check 'candidate relaunch and updated banner' @{status=$updated;identity=$script:owned.Identity;proof=$script:owned.OwnershipProof} ($updated -ceq ('Updated to version '+$release.payload.version))
   Check 'candidate pending record consumed' @{exists=Test-HarnessPath (Join-Path $updates 'pending-install.json')} (-not(Test-HarnessPath (Join-Path $updates 'pending-install.json')))
   $gone=CacheAbsentWithin $release.payload.version;Save 'candidate-installed-cache-cleanup.json' $gone;Check 'candidate installed cache removed within 35 seconds' $gone $gone.absent
   Versions;Payload;Preservation;GovernorVerified;Current $true;SavedRuleReadback;AppLog
  }
  'release-reset'{
   Wizard $OldInstaller 'end-state-published' $OldVersion
   Check 'published end-state version installed' @{version=Version;expected=$OldVersion} ((Version) -ceq $OldVersion)
  }
  'p3-alpha'{
   if(-not$AlphaInstaller -or -not$AlphaVersion){throw 'p3-alpha requires AlphaInstaller and AlphaVersion.'}
   $script:governorStarted=$true
   Wizard $AlphaInstaller 'alpha' $AlphaVersion
   Preservation
   Check 'alpha installed over newer beta' @{version=Version;log=$script:setupLogs['alpha']} ((Version) -eq $AlphaVersion) 'alpha-setup.log'
  }
  'p3'{
   $script:governorStarted=$true
   Check 'startup release cache is empty' @(UpdateFiles) ((ReleaseCacheEmpty))
   Governor 'Resume'|Out-Null
   WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 60 'governor running before OTA'|Out-Null
   Launch
   $launched=[DateTime]::UtcNow
   WaitFor {@(Texts) -contains 'Start here'} 90 'alpha Home'|Out-Null
   $until=[DateTime]::UtcNow.AddSeconds(80);$download=$null
   while([DateTime]::UtcNow -lt $until){
    CollectStarts
    $files=@(Get-HarnessChildren (Join-Path $updates $release.payload.version) -File -ErrorAction SilentlyContinue)
    if(@($files|Where-Object {$_.Name -match '\.exe(?:\.partial)?$'}).Count){break}
    Start-Sleep -Milliseconds 500
   }
   Settings
   $toggle=[string](ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
   $firstStatus=StatusText
   Save 'first-startup-status.json' @{text=$firstStatus;automaticDownloads=$toggle;seconds=([DateTime]::UtcNow-$launched).TotalSeconds;checkButtonPressed=$false}
   $script:checks.Add(@{check='startup available text';status=if($firstStatus -eq ('Version '+$release.payload.version+' is available')){'pass'}else{'unverified'};observed=@{text=$firstStatus;reason='With automatic downloads on, CheckAsync changes the available state to Downloading before the Settings page is opened; shipped code does not log the available state.'};evidence='first-startup-status.json'})
   if($toggle -eq 'Off'){$available=WaitStatus ('Version '+$release.payload.version+' is available') 60;Save 'available.json' @{text=$available;automaticDownloads=$toggle};Shot 'available-manual';Click 'UpdateDownloadButton'}
   $ready=WaitStatus ('Version '+$release.payload.version+' is ready to install') 300
   Shot 'live-installer-ready'
   $downloads=@(UpdateFiles|Where-Object {$_.path -match '\.exe$'})
   if($downloads.Count -ne 1){throw 'Expected one newly downloaded installer.'}
   $download=$downloads[0];Register-HarnessCache $release.payload.version|Out-Null;$created=(Get-HarnessItem $download.path).CreationTimeUtc
   Check 'installer was created after this app launch' @{created=$created;appStarted=$script:app.StartTime.ToUniversalTime()} ($created -ge $script:app.StartTime.ToUniversalTime())
   Save 'live-download.json' @{file=$download;secondsFromLaunch=([DateTime]::UtcNow-$launched).TotalSeconds;automaticDownloads=$toggle;checkButtonPressed=$false;status=$ready;texts=@(Texts)}
   Check 'startup live download exactly signed published bytes' $download ($download.bytes -eq $item.size -and $download.sha256 -ieq $item.sha256) 'live-download.json'
   $script:governorBeforeUpgrade=GovernorRead;Save 'governor-immediately-before-upgrade.json' $script:governorBeforeUpgrade
   $prior=$script:app.Id;Click 'UpdateInstallButton'
   WaitFor {ByName 'Install'} 30 'Install confirmation'|Out-Null;Shot 'install-confirmation';Start-ProcessTrace -Anchor $script:owned|Out-Null;$script:installPressed=[DateTime]::UtcNow;Assert-HarnessInstallStart $exe;Activate (ByName 'Install');Bind-UpdateSetup $script:owned $download.path
   $until=[DateTime]::UtcNow.AddMinutes(5)
   while([DateTime]::UtcNow -lt $until){CollectStarts;$pending=Join-Path $updates 'pending-install.json';if(Test-HarnessPath $pending){try{Save 'pending-install-observed.json' ([IO.File]::ReadAllText((Get-HarnessLongPath $pending))|ConvertFrom-Json)}catch{}};if($script:app.HasExited -and (Version) -eq $release.payload.version){break};Start-Sleep -Milliseconds 100}
   Check 'alpha exits for silent setup' @{pid=$prior;exited=$script:app.HasExited} $script:app.HasExited
   $script:app=$null;$script:owned=$null;$script:window=$null;$script:launchAfter=$script:installPressed;$script:appLogCursor=Get-ShippedLogCursor $logPath;Attach;Settings
   $updated=WaitStatus ('Updated to version '+$release.payload.version) 100;Shot 'updated-banner'
   Check 'update relaunch and banner' @{priorPid=$prior;newPid=$script:app.Id;status=$updated;texts=@(Texts)} ($script:app.Id -ne $prior -and $updated -ceq ('Updated to version '+$release.payload.version)) 'updated-banner.png'
   CollectStarts
   $setup=@($script:starts|Where-Object {$_.arguments -like '*/ROOWAITPID=*' -and $_.arguments -like '*/ROORELAUNCH=1*'})
   Check 'silent installer wait/relaunch arguments' $setup ($setup.Count -gt 0) 'process-starts-detailed.json'
   Check 'successful pending record consumed' @{pendingExists=(Test-HarnessPath (Join-Path $updates 'pending-install.json'));status=$updated} (-not(Test-HarnessPath (Join-Path $updates 'pending-install.json')))
   Versions;Payload;Preservation;GovernorVerified;Current $true;AppLog
   Save 'updates-final.json' @(UpdateFiles)
  }
  'p4'{
   $script:governorStarted=$true
   Assert-HarnessHostLease;New-ShippedFirewall $firewallName $script:firewallNonce $exe
   $script:firewallCreated=$true
   Save 'firewall-created.json' @(Get-NetFirewallRule -Name $firewallName|Select-Object Name,Enabled,Direction,Action)
   Launch;Settings
   $clock=[Diagnostics.Stopwatch]::StartNew();Click 'UpdateCheckButton';$status=WaitStatus "Couldn't check for updates.*" 60;$clock.Stop();Shot 'offline-settings'
   Check 'offline shipped check ends with visible failure' @{text=$status;seconds=$clock.Elapsed.TotalSeconds;pid=$script:app.Id;alive=(-not$script:app.HasExited)} ($status -like "Couldn't check for updates.*" -and -not$script:app.HasExited)
   Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 30 'offline Home'|Out-Null;Shot 'offline-home'
   Activate (ByName 'Games');WaitFor {ById 'GamesTab'} 40 'offline Games'|Out-Null;Shot 'offline-games'
   Check 'navigation works while offline' @{pages=@('Home','Games');pid=$script:app.Id} (-not$script:app.HasExited)
   Remove-ShippedFirewall $firewallName $script:firewallNonce $script:firewallCreated
   $script:firewallCreated=$false
   Check 'owned firewall rule removed' @{name=$firewallName;exists=[bool](Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue)} (-not[bool](Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue))
   Current $true
   StopApp
   HangingNetwork
  }
  'p5'{
   $before=Get-HarnessMachineSnapshot;Save 'p5-as-found.json' $before
   if(-not$before.installedVersion){if($before.installDirectory.exists -or @($before.tasks|Where-Object {$_.name -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}).Count){throw 'As-found Suite files or tasks exist without an install record; retained.'};Assert-HarnessFreshData $bootstrapRoot $before}
   $published=DownloadPublished;Wizard $published 'published' $release.payload.version
   $script:freshP5Installed=-not$before.installedVersion
   Payload
   Launch
   if(-not$before.installedVersion){Register-HarnessCreatedData (Get-RooIndustriesLocalDataRoot) $before|Out-Null}
   $data=Get-RooIndustriesLocalDataRoot;$updates=Join-Path $data 'updates';$ruleRoot=Join-Path $data 'process-rules';$logPath=Join-Path $data 'logs\app.log';$settingsPath=Join-Path $data 'settings.json'
   Versions;Current $false
   Activate (ByName 'Memory')
   $guides=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\Assets\Guides\memory-guides.json')))|ConvertFrom-Json
   WaitFor {ByName $guides.title} 60 'Memory guides'|Out-Null
   $found=@($guides.guides|Where-Object {ByName $_.title})
   Activate (ByName $guides.guides[0].title);Shot 'memory-guide-expanded'
   Check 'Memory guides render' @{found=$found.Count;titles=@($found.title)} ($found.Count -eq 7) 'memory-guide-expanded.png'
   $processId=$script:app.Id
   [RooUpdateUi]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),6)|Out-Null;Start-Sleep 10
   $samples=(Get-Counter '\Process(*)\ID Process','\Process(*)\Working Set - Private').CounterSamples
   $instances=@($samples|Where-Object {$_.Path -like '*\id process' -and [int]$_.CookedValue -eq $processId}|Select-Object -ExpandProperty InstanceName)
   $private=@($samples|Where-Object {$_.Path -like '*\working set - private' -and $_.InstanceName -in $instances}|Select-Object -ExpandProperty CookedValue)
   $script:app.Refresh();Check 'minimized private working set after 10 seconds' @{pid=$processId;privateWorkingSetBytes=$private;workingSet64=$script:app.WorkingSet64;privateMemorySize64=$script:app.PrivateMemorySize64;seconds=10} ($private.Count -eq 1)
   StopApp
   . (Get-HarnessToolPath (Join-Path $install 'backend\scripts\ProcessProfile.Common.ps1'))
   . (Get-HarnessToolPath (Join-Path $install 'backend\scripts\BackgroundPlacement.Common.ps1'))
   $fixtureProcesses=@(foreach($name in 'RooFixtureUpdater','RooFixtureWebHelper','RooFixtureGame','MsMpEng'){
    $path=Join-Path $directory ($name+'.exe');Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $path|Out-Null
    $fixtureOwned=Start-OwnedProcess -FilePath $path -ArgumentList '-t 127.0.0.1' -Purpose background-fixture;$script:fixtures.Add($fixtureOwned);$fixtureOwned.process
   })
   $profile=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $install 'backend\profiles\game-session.profile.json')))|ConvertFrom-Json
   $profile.profileId='shipped-fixture';$profile.protectedCatalogPath=Join-Path $install 'backend\profiles\protected-processes.json'
   $profile.foregroundGame.processNames=@('RooFixtureGame.exe');$profile.targetGames=@([pscustomobject]@{gameId='fixture';processNames=@('RooFixtureGame.exe')})
   $profile.rules=@([pscustomobject]@{ruleId='fixture-background';enabled=$true;match=@{processNames=@('RooFixtureUpdater.exe','RooFixtureWebHelper.exe','RooFixtureGame.exe','MsMpEng.exe')};action=@{actionType='setPriority';priorityClass='BelowNormal'};risk='low'})
   $profilePath=Join-Path $directory ('profile-'+$nonce+'.json');New-HarnessText $profilePath ($profile|ConvertTo-Json -Depth 40) 'background-profile'|Out-Null
   $state=Join-Path $script:Harness.Root ('pf-'+$nonce);New-HarnessDirectory $state 'background-state'|Out-Null
   foreach($preset in 'lower','placement'){
    foreach($fixture in @($fixtureProcesses|Where-Object ProcessName -in 'RooFixtureUpdater','RooFixtureWebHelper')){$fixture.PriorityClass='AboveNormal';[RooBackgroundOracle]::SetIo($fixture,1);[RooBackgroundOracle]::SetMemory($fixture,3)}
    $originals=@($fixtureProcesses|ForEach-Object {ShippedFixtureRead $_});Save ($preset+'-before.json') $originals
    $preview=ShippedProfileCall 'Preview-ProcessProfile' @{ProfilePath=$profilePath;Preset=$preset};Save ($preset+'-preview.json') $preview
    $apply=ShippedProfileCall 'Apply-ProcessProfile' @{ProfilePath=$profilePath;Preset=$preset;StateRoot=$state;ConfirmApply=$true};Save ($preset+'-apply.json') $apply
    $placement=@($fixtureProcesses|ForEach-Object {ShippedFixtureRead $_});Save ($preset+'-after.json') $placement
    if(-not$apply.backup.location){throw 'Background fixture Apply saved no originals.'}
    $restore=ShippedProfileCall 'Restore-ProcessProfileBackup' @{BackupPath=$apply.backup.location;ConfirmApply=$true};Save ($preset+'-restore.json') $restore
    $restored=@($fixtureProcesses|ForEach-Object {ShippedFixtureRead $_});Save ($preset+'-restored.json') $restored
    $restoreMismatches=@()
    foreach($original in $originals){$actual=@($restored|Where-Object pid -eq $original.pid);foreach($field in 'name','path','startTimeUtc','priorityClass','affinityMask','ioPriority','memoryPriority'){if($actual.Count -ne 1 -or $actual[0].$field -ne $original.$field){$restoreMismatches+=@(@{pid=$original.pid;field=$field;expected=$original.$field;observed=$(if($actual.Count -eq 1){$actual[0].$field})})}}}
    if($restoreMismatches.Count){throw ('Background Restore differs: '+($restoreMismatches|ConvertTo-Json -Compress))}
    if($preset -eq 'lower'){Check 'published Lower fixture restore' @{originals=$originals;after=$placement;restored=$restored} (@($placement|Where-Object {$_.name -in 'RooFixtureUpdater','RooFixtureWebHelper' -and ($_.priorityClass -ne 'BelowNormal' -or $_.memoryPriority -ne 2)}).Count -eq 0);continue}
    $topology=Read-RooIndustriesBackgroundPlacement
    $target=[RooIndustries.Optimization.CpuSets.Target]::new($PID,$false);try{$cpus=@($target.Topology())}finally{$target.Dispose()}
    $cpu0=@($cpus|Where-Object {$_.group -eq 0 -and $_.logicalProcessorIndex -eq 0})|Select-Object -First 1
    [uint64]$ccdMask=0;[uint64]$fullMask=0
    foreach($cpu in @($cpus|Where-Object group -eq 0)){$bit=[uint64]1 -shl $cpu.logicalProcessorIndex;$fullMask=$fullMask -bor $bit;if($cpu.lastLevelCacheIndex -ne $cpu0.lastLevelCacheIndex){$ccdMask=$ccdMask -bor $bit}}
    $background=@($placement|Where-Object name -in 'RooFixtureUpdater','RooFixtureWebHelper');$untouched=@($placement|Where-Object name -in 'RooFixtureGame','MsMpEng')
    $passed=$topology.available -and $topology.kind -eq 'ccd' -and $cpu0 -and $ccdMask -ne 0 -and [uint64]$topology.mask -eq $ccdMask -and $background.Count -eq 2 -and $untouched.Count -eq 2 -and @($background|Where-Object {[uint64]$_.affinityMask -ne $ccdMask -or $_.priorityClass -ne 'Normal' -or $_.ioPriority -ne 2 -or $_.memoryPriority -ne 5}).Count -eq 0 -and @($untouched|Where-Object {[uint64]$_.affinityMask -ne $fullMask}).Count -eq 0 -and $originals.Count -eq 4 -and $restored.Count -eq $originals.Count -and $restoreMismatches.Count -eq 0
    Check 'published CCD placement apply/restore' @{topology=$topology;logicalProcessorCount=$cpus.Count;cpus=$cpus;expectedCcdMask=$ccdMask;fullMask=$fullMask;readback=$placement;originals=$originals;restored=$restored;restoreMismatches=$restoreMismatches} $passed
   }
   foreach($fixtureOwned in $script:fixtures){Stop-HarnessProcess $fixtureOwned}
   if(-not$before.installedVersion){RestoreFreshP5Installation}
   $cs2=@(Get-ScheduledTask|Where-Object {$_.TaskName -like '*CS2*'}|Select-Object TaskName,State,@{n='enabled';e={$_.Settings.Enabled}})
   Check 'as-found CS2 tasks remain Ready and Enabled' $cs2 (@($cs2|Where-Object {$_.State -ne 'Ready' -or -not$_.enabled}).Count -eq 0 -and $cs2.Count -eq @($before.tasks|Where-Object {$_.name -like '*CS2*'}).Count)
  }
 }
 CollectStarts;$script:receiptStatus='pass'
}catch{
 CollectStarts;$script:receiptStatus='fail';Save 'failure.json' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage;texts=if($script:window){try{@(Texts)}catch{@()}}else{@()};checks=@($script:checks)};Receipt;throw
}finally{
 Start-Sleep -Milliseconds 800
 try{CollectStarts}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 try{Remove-ShippedFirewall $firewallName $script:firewallNonce $script:firewallCreated}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 try{Remove-ShippedHosts}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 foreach($fixture in $script:fixtures){try{Stop-HarnessProcess $fixture}catch{$script:cleanupErrors.Add($_.Exception.Message)}}
 try{StopApp}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 if($script:governorStarted -and (Test-HarnessPath $hostExe)){
  try{Governor 'Pause'|Out-Null;WaitFor {-not(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 40 'owned governor stops'|Out-Null}catch{$script:cleanupErrors.Add($_.Exception.Message);Save 'governor-cleanup-error.json' @{error=$_.Exception.Message}}
 }
 foreach($process in @($script:setupReceipts)+@($script:extraProcesses)){try{Stop-HarnessProcess $process}catch{$script:cleanupErrors.Add($_.Exception.Message)}}
 if($Part -eq 'p5' -and $script:freshP5Installed){try{RestoreFreshP5Installation}catch{$script:cleanupErrors.Add($_.Exception.Message)}}
 Save 'process-starts.json' @(ProcessStarts)

 $script:receiptStatus=Get-ShippedFinalStatus $script:receiptStatus @($script:cleanupErrors)
 try{$script:receiptStatus=Complete-HarnessInvocation $script:receiptStatus -Cleanup}catch{$script:cleanupErrors.Add($_.Exception.Message);$script:receiptStatus='fail'}
 Receipt
 if($script:cleanupErrors.Count){throw ('Cleanup failed: '+($script:cleanupErrors -join '; '))}
}
