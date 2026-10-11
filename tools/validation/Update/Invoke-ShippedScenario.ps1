param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][ValidateSet('p2','p3-alpha','p3','p4','p5')][string]$Part,
 [Parameter(Mandatory)][string]$ReleasePath,[string]$OldInstaller='',[string]$OldVersion='',
 [string]$AlphaInstaller='',[string]$AlphaVersion='',[string]$PayloadHashes='',[string]$FrameId='',
 [string]$PreflightPath='',[switch]$HarnessOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Invoke-UpdateScenario.ps1') -Source $Source -OutRoot $OutRoot -Scenario seed -EvidenceName $Part -HelpersOnly
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
. (Join-Path $Source 'tools\validation\Update\ShippedHarness.Common.ps1')
$release=Get-Content -Raw $ReleasePath|ConvertFrom-Json
$item=$release.payload.installer
$script:checks=[Collections.Generic.List[object]]::new()
$script:fixtures=[Collections.Generic.List[object]]::new()
$script:extraProcesses=[Collections.Generic.List[object]]::new()
$script:starts=[Collections.Generic.List[object]]::new()
$script:loggedEvents=[Collections.Generic.HashSet[int]]::new()
$script:receiptStatus='running'
$script:governorStarted=$false
$ruleRoot=Join-Path $data 'process-rules'
$logPath=Join-Path $data 'logs\app.log'
$script:partLogCursor=Get-ShippedLogCursor $logPath
$script:appLogCursor=$null
$script:launchAfter=[DateTime]::UtcNow
$script:ownedPids=@{}
$script:ownedHandles=@{}
$script:ownedHandles[$PID]=New-OwnedProcess (Get-Process -Id $PID)
$script:ownedPids[$PID]=[long]$script:ownedHandles[$PID].Identity.creationTimeFileTimeUtc
$script:installPressed=$null
$script:firewallCreated=$false
$script:firewallNonce='RooShipped-'+[Guid]::NewGuid().ToString('N')
$script:hostsMarker='# RooShipped-'+[Guid]::NewGuid().ToString('N')
$script:hostsCreated=$false
$script:completedInstallerDownloads=0
$script:cleanupErrors=[Collections.Generic.List[string]]::new()
$firewallName='RooTest-ShippedOffline-'+$FrameId
$seedPath=Join-Path $OutRoot 'tester-preservation.json'
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
 $ownedProcess=New-OwnedProcess $Process
 if($ownedProcess){$script:ownedPids[[int]$Process.Id]=[long]$ownedProcess.Identity.creationTimeFileTimeUtc;$script:ownedHandles[[int]$Process.Id]=$ownedProcess}
 return $ownedProcess
}
function Bind-OwnedChain([int]$ProcessId){
 $chain=@();$seen=@{};$childTime=$null
 for($hop=0;$hop -lt 32;$hop++){
  if($seen.ContainsKey($ProcessId)){return $false};$seen[$ProcessId]=$true
  $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if(-not$process){return $false}
  $ownedProcess=New-OwnedProcess $process
  if(-not$ownedProcess){return $false}
  $created=[long]$ownedProcess.Identity.creationTimeFileTimeUtc
  if($childTime -and $created -gt $childTime){return $false}
  if($script:ownedHandles.ContainsKey($ProcessId)){
   $held=$script:ownedHandles[$ProcessId]
   if($held.Identity.creationTimeFileTimeUtc -cne $ownedProcess.Identity.creationTimeFileTimeUtc -or -not(Test-OwnedProcess $held)){return $false}
   foreach($entry in $chain){$script:ownedPids[[int]$entry.Identity.pid]=[long]$entry.Identity.creationTimeFileTimeUtc;$script:ownedHandles[[int]$entry.Identity.pid]=$entry;$script:extraProcesses.Add($entry)}
   return $true
  }
  $chain+=@($ownedProcess);$childTime=$created
  $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ProcessId) -ErrorAction SilentlyContinue
  if(-not$cim){return $false};$ProcessId=[int]$cim.ParentProcessId
 }
 return $false
}
function CollectStarts{
 $pending=@(Get-Event -SourceIdentifier $events -ErrorAction SilentlyContinue|Sort-Object EventIdentifier)
 foreach($event in $pending){
  if(-not$script:loggedEvents.Add([int]$event.EventIdentifier)){continue}
  $p=$event.SourceEventArgs.NewEvent
  $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessID) -ErrorAction SilentlyContinue
  $parent=[int]$p.ParentProcessID;$stamp=[long]$p.TIME_CREATED
  $ours=$false
  if($script:ownedHandles.ContainsKey($parent)){
   $held=$script:ownedHandles[$parent]
   $ours=$stamp -ge [long]$held.Identity.creationTimeFileTimeUtc -and (-not$held.process.HasExited -or $stamp -le $held.process.ExitTime.ToUniversalTime().ToFileTimeUtc())
  }
  if($p.ProcessName -notmatch '(?i)RooIndustries|Optimizer\.|setup|unins|notepad|smartscreen|RooTester' -and -not$ours){continue}
  $row=@{pid=[int]$p.ProcessID;parentPid=$parent;image=[string]$p.ProcessName;time=[string]$p.TIME_CREATED;path=$cim.ExecutablePath;arguments=$cim.CommandLine;ownedChain=$ours}
  $script:starts.Add($row)
  if(-not$ours -and $cim){$ours=Bind-OwnedChain ([int]$p.ProcessID);$row.ownedChain=$ours}
  if($ours -and $cim){
   $process=Get-Process -Id $p.ProcessID -ErrorAction SilentlyContinue
   if($process -and $process.StartTime.ToUniversalTime().ToFileTimeUtc() -le $stamp){$ownedProcess=Remember-Owned $process;if($ownedProcess){$script:extraProcesses.Add($ownedProcess)}}
  }
 }
 Save 'process-starts-detailed.json' @($script:starts)
}
function Attach{
 $script:app=WaitFor {
  CollectStarts
  $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $exe})
  if($matches.Count -gt 1){throw 'Several app instances; retained.'}
  if($matches.Count -eq 1){
   $match=$matches[0]
   if(-not$script:ownedHandles.ContainsKey([int]$match.ProcessId) -or -not(Test-OwnedProcess $script:ownedHandles[[int]$match.ProcessId]) -or $match.CreationDate.ToUniversalTime() -lt $script:launchAfter){return $null}
   if($script:installPressed -and $match.CreationDate.ToUniversalTime() -lt $script:installPressed){return $null}
   Get-Process -Id $match.ProcessId
  }
 } 150 'owned installed app'
 Assert-ShippedFreshApp $script:app $script:launchAfter
 $script:owned=Remember-Owned $script:app
 $script:window=WaitFor {@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id))|Where-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings'))})|Select-Object -First 1} 120 'owned app navigation window'
 Save 'owned-app.json' $script:owned.Identity
}
function Launch{
 Assert-ShippedNoApp $exe
 $script:launchAfter=[DateTime]::UtcNow;$script:installPressed=$null
 $script:appLogCursor=Get-ShippedLogCursor $logPath
 $p=Start-Process $exe -PassThru
 $script:owned=Remember-Owned $p
 Attach
}
function Tree{
 @($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;class=$_.Current.ClassName;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled}})
}
function Zone([string]$path){
 $raw=Get-Content -Raw -LiteralPath $path -Stream Zone.Identifier
 return [string]::new($raw.ToCharArray())
}
function SmartScreen($candidate){
 if(-not$candidate){return $false}
 try{$info=$candidate.Current}catch{return $false}
 if(-not$info -or -not$info.ProcessId){return $false}
 if($info.Name -eq 'Windows protected your PC' -or $info.Name -like '*Microsoft Defender SmartScreen*'){return $true}
 $process=Get-Process -Id $info.ProcessId -ErrorAction SilentlyContinue
 return $process -and $process.ProcessName -ieq 'smartscreen'
}
function Wizard([string]$path,[string]$label,[string]$version){
 $foreign=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '(?i)setup.*\.(exe|tmp)$' -and -not$script:ownedPids.ContainsKey([int]$_.ProcessId)})
 if($foreign.Count){throw 'Another non-owned setup is running; retain it.'}
 $existingWindows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.NativeWindowHandle})
 $wizardStarted=[DateTime]::UtcNow
 $setupLog=Join-Path $directory ($label+'-setup.log')
 $launchResult=Join-Path $directory ($label+'-shell-result.json')
 $launcherPath=Join-Path $directory ($label+'-shell.ps1')
 $launcher=@'
param([string]$Installer,[string]$Log,[string]$Result)
$ErrorActionPreference='Stop'
try{
 $start=[Diagnostics.ProcessStartInfo]::new($Installer);$start.UseShellExecute=$true;$start.WorkingDirectory=Split-Path $Installer -Parent;$start.Arguments='/LOG="'+$Log+'"'
 $process=[Diagnostics.Process]::Start($start)
 @{pid=$process.Id;status='started'}|ConvertTo-Json|Set-Content -LiteralPath $Result
 $process.WaitForExit()
 @{pid=$process.Id;status='exited';exitCode=$process.ExitCode}|ConvertTo-Json|Set-Content -LiteralPath $Result
}catch{@{status='failed';error=$_.Exception.ToString()}|ConvertTo-Json|Set-Content -LiteralPath $Result;exit 1}
'@
 [IO.File]::WriteAllText($launcherPath,$launcher,$utf8)
 $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$launcherPath+'" -Installer "'+$path+'" -Log "'+$setupLog+'" -Result "'+$launchResult+'"'
 $shell=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Normal -PassThru
 $script:extraProcesses.Add((Remember-Owned $shell))
 Save ($label+'-launch.json') @{path=$path;arguments=('/LOG="'+$setupLog+'"');useShellExecute=$true;launcherPid=$shell.Id;zone=try{Zone $path}catch{$null}}
 $until=[DateTime]::UtcNow.AddMinutes(10);$seen=[Collections.Generic.HashSet[string]]::new();$number=0;$smartScreen=$false
 $result=$null
 while([DateTime]::UtcNow -lt $until){
  if(Test-Path $launchResult){
   try{$launchIdentity=Get-Content -Raw $launchResult|ConvertFrom-Json}catch{$launchIdentity=$null}
   if($launchIdentity.pid -and -not$script:ownedPids.ContainsKey([int]$launchIdentity.pid)){
    $process=Get-Process -Id $launchIdentity.pid -ErrorAction SilentlyContinue
    if($process -and $process.Path -ieq $path -and $process.StartTime.ToUniversalTime() -ge $wizardStarted){$ownedProcess=Remember-Owned $process;$script:setupReceipts.Add($ownedProcess)}
   }
  }
  CollectStarts
  $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition))
  foreach($win in $windows){
   if($win.Current.ClassName -eq 'TWizardForm' -and $win.Current.Name -like '*Roo Industries*'){
    if(-not(Bind-OwnedChain ([int]$win.Current.ProcessId))){throw 'Wizard belongs to a non-owned setup; retained.'}
    $script:window=$win
    if($win.Current.ProcessId -notin @($script:setupReceipts.Identity.pid)){$script:setupReceipts.Add((Remember-Owned (Get-Process -Id $win.Current.ProcessId)))}
    $tree=@(Tree);$button=$null
    foreach($name in 'Finish','Install','Next >','Next'){$candidate=ByNameControl $name $CT::Button;if($candidate -and $candidate.Current.IsEnabled){$button=$candidate;break}}
    $key=if($button){$tree.name -join '|'}else{'install-progress'}
    if($seen.Add($key)){
     $number++;$shotName=$label+'-page-'+('{0:D2}'-f$number)
     Save ($shotName+'.json') @{title=$win.Current.Name;controls=$tree;defaultChoicesKept=$true}
     Shot $shotName;if($button){Activate $button;Start-Sleep -Milliseconds 400}
    }
   }elseif($win.Current.ClassName -eq '#32770' -and $win.Current.ProcessId -eq $shell.Id){
    $script:window=$win;$number++;Save ($label+'-security-warning-'+$number+'.json') @(Tree);Shot ($label+'-security-warning-'+$number)
    $button=ByNameControl 'Run' $CT::Button
    if($button){Activate $button}else{throw 'Shell security warning did not expose Run.'}
   }elseif($win.Current.ClassName -eq '#32770' -and $win.Current.ProcessId -in @($script:setupReceipts.Identity.pid)){
    $script:window=$win;$tree=@(Tree);$key=($tree.name -join '|')
    if($seen.Add($key)){$number++;Save ($label+'-dialog-'+$number+'.json') $tree;Shot ($label+'-dialog-'+$number)}
    $button=ByNameControl 'OK' $CT::Button
    if($button){Activate $button}else{throw ('Installer dialog requires an unplanned choice: '+$key)}
   }elseif(SmartScreen $win){
    $foreign=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '(?i)setup.*\.(exe|tmp)$' -and -not$script:ownedPids.ContainsKey([int]$_.ProcessId)})
    if($win.Current.NativeWindowHandle -in $existingWindows -or $foreign.Count){throw 'SmartScreen cannot be bound to this launch; retained.'}
    if([DateTime]::UtcNow -lt $wizardStarted){throw 'SmartScreen predates owned launch.'}
    $script:window=$win;$smartScreen=$true;$number++;Save ($label+'-smartscreen-'+$number+'.json') @(Tree);Shot ($label+'-smartscreen-'+$number)
    $button=ByName 'More info';if($button){Activate $button;Start-Sleep -Milliseconds 500;Shot ($label+'-smartscreen-more-info')}
    $button=ByName 'Run anyway';if($button){Activate $button}else{throw 'SmartScreen did not expose Run anyway.'}
   }
  }
  if(Test-Path $launchResult){try{$result=Get-Content -Raw $launchResult|ConvertFrom-Json}catch{}}
  if($result.status -eq 'failed'){throw ('ShellExecute failed: '+$result.error)}
  if($result.status -eq 'exited'){break}
  Start-Sleep -Milliseconds 150
 }
 CollectStarts
 Check ($label+' wizard completed') @{shell=$result;pages=$number;smartScreen=$smartScreen;version=try{Version}catch{$null};defaultCheckboxes=$true} ($result.status -eq 'exited' -and $result.exitCode -eq 0 -and (Version) -eq $version) ($label+'-setup.log')
 $script:window=$null;$script:app=$null;$script:owned=$null
}
function Uninstall{
 $unins=Join-Path $install 'unins000.exe'
 if(-not(Test-Path $unins)){
  $key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
  if(Test-Path $key){throw 'Installed uninstaller is missing.'}
  Check 'no current installation to uninstall' @{uninstallerExists=$false;uninstallKeyExists=$false} $true;return
 }
 $p=Start-Process $unins -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+(Join-Path $directory 'uninstall.log')+'"') -PassThru
 $ownedProcess=Remember-Owned $p
 try{if(-not$p.WaitForExit(360000)){throw 'Uninstall timed out.'};Check 'uninstall completed' $p.ExitCode ($p.ExitCode -eq 0) 'uninstall.log'}finally{Stop-OwnedProcess $ownedProcess}
}
function DownloadPublished{
 $downloadFolder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('Downloads\RooTest-Shipped-'+$FrameId)
 if(Test-Path $downloadFolder){throw 'Owned browser-download folder already exists; retain it.'}
 [IO.Directory]::CreateDirectory($downloadFolder)|Out-Null
 $path=Join-Path $downloadFolder ([IO.Path]::GetFileName(([uri]$item.url).AbsolutePath))
 if(Test-Path $path){throw 'Published installer download already exists; do not silently repeat the GET.'}
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Invoke-WebRequest -UseBasicParsing -Uri $item.url -OutFile $path
 $script:completedInstallerDownloads++
 $clock.Stop();Set-Content -LiteralPath $path -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
 $actual=@{path=$path;url=$item.url;bytes=(Get-Item $path).Length;sha256=(Get-FileHash $path).Hash;seconds=$clock.Elapsed.TotalSeconds;completedInstallerDownloads=$script:completedInstallerDownloads;zone=Zone $path}
 Save 'published-download.json' $actual
 Check 'published installer downloaded on PC' $actual ($actual.bytes -eq $item.size -and $actual.sha256 -ieq $item.sha256 -and $actual.zone -match 'ZoneId=3') 'published-download.json'
 return $path
}
function Governor([string]$action){
 $raw=@(& (Join-Path $install 'backend\scripts\Invoke-ProcessPolicyWorker.ps1') -Action $action -PolicyRoot $ruleRoot -ConfirmApply) -join "`n"
 $result=$raw|ConvertFrom-Json
 Save ('governor-'+$action+'.json') $result
 if($result.status -ne 'completed'){throw ('Governor '+$action+': '+$raw)}
 return $result
}
function GovernorRead{
 $status=Core 'policy-status' @{policyRoot=$ruleRoot}
 $process=if($status.hostRunning){Get-CimInstance Win32_Process -Filter ('ProcessId='+$status.state.host.processId)}else{$null}
 @{status=$status;path=$process.ExecutablePath;arguments=$process.CommandLine;productVersion=if($process){(Get-Item $process.ExecutablePath).VersionInfo.ProductVersion.Trim()}else{$null};sha256=if($process){(Get-FileHash $process.ExecutablePath).Hash}else{$null};pid=$process.ProcessId;creationTimeUtc=if($process){$process.CreationDate.ToUniversalTime().ToString('o')}else{$null};tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,State,@{n='enabled';e={$_.Settings.Enabled}})}
}
function SeedTester{
 Launch;WaitFor {@(Texts) -contains 'Start here'} 90 'baseline Home'|Out-Null
 Check 'baseline app running before seed' @{version=Version;pid=$script:app.Id} ((Version) -eq $OldVersion)
 StopApp
 $fixture=Join-Path $data ('shipped-fixture\'+$FrameId);[IO.Directory]::CreateDirectory($fixture)|Out-Null
 $target=Join-Path $fixture 'RooTesterGame.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $target
 $p=Start-Process $target -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$ownedProcess=New-OwnedProcess $p
 try{$snapshot=Core 'process-status' @{processId=$p.Id};Save 'seed-process-status.json' $snapshot}finally{Stop-OwnedProcess $ownedProcess}
 $text=(@($snapshot.topology|Sort-Object group,index|ForEach-Object {'{0}:{1}:{2}:{3}:{4}:{5}' -f $_.group,$_.index,$_.core,$_.cache,$_.numa,$_.efficiency}) -join ';')
 $sha=[Security.Cryptography.SHA256]::Create();try{$fingerprint=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
 $rule=@{schemaVersion=1;ruleId=([Guid]::NewGuid().ToString('N'));owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value};name='Shipped tester game rule';enabled=$true;matchMode='path';executablePath=$target;executableHash=$null;controls=@{cpuPriority='High';memoryPriority=2;affinity=@{group=0;mask='0x3'}};cpuSelection=$null;affinityTopologyHash=$fingerprint}
 $savedRule=Core 'rule-save' @{policyRoot=$ruleRoot;rule=$rule};Save 'saved-rule.json' $savedRule
 $settings=Get-Content -Raw $settingsPath|ConvertFrom-Json;Save 'as-found-settings.json' $settings
 $settings|Add-Member themeId 'roo-industries-blue' -Force;$settings|Add-Member simpleMode '1' -Force;$settings|Add-Member downloadUpdatesAutomatically '1' -Force
 [IO.File]::WriteAllText($settingsPath,($settings|ConvertTo-Json -Compress),$utf8)
 $registry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
 $before=Get-ItemProperty -LiteralPath $registry -Name EnableTransparency -ErrorAction SilentlyContinue
 $option=if($before.EnableTransparency -eq 0){'choice-6b253977ea5987f3'}else{'choice-95a6ed84299d0109'}
 $preview=Join-Path $data ('operations\shipped-tester-tweak-'+[Guid]::NewGuid().ToString('N')+'\preview.json')
 [IO.Directory]::CreateDirectory((Split-Path $preview -Parent))|Out-Null
 Save 'tester-tweak-before.json' @{settingId='windows.0689e69eedc05770';optionId=$option;original=$before.EnableTransparency}
 $plan=Core 'tweak-preview' @{profileId='shipped-tester';selections=@(@{settingId='windows.0689e69eedc05770';optionId=$option});outputPath=$preview}
 Save 'tester-tweak-preview.json' $plan
 $applied=Core 'tweak-apply' @{previewPath=$preview;reviewHash=(Get-FileHash $preview).Hash;confirm=$true};Save 'tester-tweak-apply.json' $applied
 $tweakAfter=(Get-ItemProperty -LiteralPath $registry -Name EnableTransparency).EnableTransparency
 $expected=if($before.EnableTransparency -eq 0){1}else{0}
 Check 'tester tweak applied with independent registry readback' @{before=$before.EnableTransparency;expected=$expected;after=$tweakAfter;changed=$applied.changed} ($applied.changed -and $tweakAfter -eq $expected) 'tester-tweak-apply.json'
 $script:governorStarted=$true;Governor 'Resume'|Out-Null
 WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 60 '0.10 governor starts'|Out-Null
 $files=@(Get-Item $settingsPath;Get-ChildItem (Join-Path $ruleRoot 'rules') -File;Get-ChildItem (Join-Path $data 'operations') -File -Recurse|Where-Object {$_.Name -notlike '*.lock'})
 $baseline=@{files=@($files|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash $_.FullName).Hash}});themeId='roo-industries-blue';simpleMode='1';automaticDownloads='1';ruleId=$savedRule.ruleId;fixturePath=$target;controls=$rule.controls;governor=(GovernorRead)}
 [IO.File]::WriteAllText($seedPath,($baseline|ConvertTo-Json -Depth 40),$utf8)
 Launch;WaitFor {@(Texts) -contains 'Start here'} 90 'seeded 0.10 Home'|Out-Null;Shot 'seeded-0.10-home'
 Save 'tester-before-upgrade.json' @{appPid=$script:app.Id;governor=(GovernorRead);preservation=$baseline}
 Check 'tester undo data exists' @{operationFiles=@($baseline.files|Where-Object {$_.path -like '*\operations\*'}).Count;tweakResult=$applied.status} (@($baseline.files|Where-Object {$_.path -like '*\operations\*'}).Count -gt 0)
 Check 'old app and governor running at upgrade' @{appPid=$script:app.Id;governor=$baseline.governor} ($baseline.governor.status.hostRunning -eq $true -and -not$script:app.HasExited)
}
function Preservation{
 $baseline=Get-Content -Raw $seedPath|ConvertFrom-Json
 $rows=@($baseline.files|ForEach-Object {$exists=Test-Path $_.path;@{path=$_.path;expected=$_.sha256;observed=if($exists){(Get-FileHash $_.path).Hash}else{$null};match=($exists -and (Get-FileHash $_.path).Hash -ieq $_.sha256)}})
 Save 'preservation-readback.json' $rows
 Check 'tester preservation hashes' @{files=$rows.Count;mismatches=@($rows|Where-Object {-not$_.match})} (@($rows|Where-Object {-not$_.match}).Count -eq 0) 'preservation-readback.json'
 $settings=Get-Content -Raw $settingsPath|ConvertFrom-Json
 Check 'theme and settings kept' $settings ($settings.themeId -eq $baseline.themeId -and $settings.simpleMode -eq $baseline.simpleMode -and $settings.downloadUpdatesAutomatically -eq $baseline.automaticDownloads)
}
function Payload{
 $oracle=Get-Content -Raw $PayloadHashes|ConvertFrom-Json
 if($oracle.installerSha256 -ine $item.sha256 -or $oracle.installerSize -ne $item.size){throw 'Payload oracle installer identity differs.'}
 $hashes=@($oracle.files)
 $rows=@($hashes|ForEach-Object {$p=Join-Path $install $_.path;$exists=Test-Path $p -PathType Leaf;@{path=$_.path;expected=$_.sha256;observed=if($exists){(Get-FileHash $p).Hash}else{$null};match=($exists -and (Get-FileHash $p).Hash -ieq $_.sha256)}})
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
 $currentLines=@($newLines -split "`n"|Where-Object {$_ -like '*[[]update] You have the latest version*'})
 Save 'current-process-log.json' @{pid=$script:app.Id;creationTimeUtc=$script:app.StartTime.ToUniversalTime().ToString('o');launchAfter=$script:launchAfter.ToString('o');lines=$currentLines;segment=$newLines}
 Check 'Current is a new log result from this owned launch' $currentLines ($currentLines.Count -gt 0 -and $newLines -notmatch '[[]update] Downloading') 'current-process-log.json'
 Shot 'live-feed-current'
 Check 'live feed up to date' @{text=$status;feed=$release.feedUrl;checkButtonPressed=$pressCheck;productVersion=(Get-Item $exe).VersionInfo.ProductVersion.Trim()} ($status -ceq 'You have the latest version') 'live-feed-current.png'
}
function Versions{
 $actual=@{displayVersion=Version;productVersion=(Get-Item $exe).VersionInfo.ProductVersion.Trim();runningPid=$script:app.Id;runningPath=$script:app.Path}
 Check 'published version installed and running' $actual ($actual.displayVersion -eq $release.payload.version -and $actual.productVersion -eq $release.payload.version -and -not$script:app.HasExited)
}
function GovernorVerified{
 $governor=GovernorRead;Save 'governor-readback.json' $governor
 $oracle=Get-Content -Raw $PayloadHashes|ConvertFrom-Json
 if($oracle.installerSha256 -ine $item.sha256 -or $oracle.installerSize -ne $item.size){throw 'Payload oracle installer identity differs.'}
 $hashes=@($oracle.files)
 $hostHash=($hashes|Where-Object {$_.path -eq 'backend/bin/optimizer/Optimizer.Host.exe'}|Select-Object -First 1).sha256
 Check 'governor enabled and running from new install' @{before=$script:governorBeforeUpgrade;after=$governor} ((Test-ShippedGovernorReplacement $script:governorBeforeUpgrade $governor) -and $governor.status.hostRunning -eq $true -and $governor.path -ieq $hostExe -and $governor.sha256 -ieq $hostHash -and @($governor.tasks|Where-Object enabled).Count -gt 0) 'governor-readback.json'
}
function SavedRuleReadback{
 $seed=Get-Content -Raw $seedPath|ConvertFrom-Json
 $governor=GovernorRead
 if(-not$governor.status.hostRunning){throw 'Saved-rule check requires the published governor running.'}
 $shell=$null;$folderWindow=$null;$attempts=@();$observed=$false
 try{
  $folder=Split-Path $seed.fixturePath -Parent
  $shell=New-Object -ComObject Shell.Application
  $windowIds=@($shell.Windows()|ForEach-Object {$_.HWND})
  Start-Process explorer.exe -ArgumentList ('"'+$folder+'"')|Out-Null
  $folderWindow=WaitFor {@($shell.Windows()|Where-Object {try{$_.HWND -notin $windowIds -and $_.Document.Folder.Self.Path -ieq $folder}catch{$false}})|Select-Object -First 1} 30 'owned Explorer fixture folder'
  $desktopShell=$folderWindow.Document.Application
  for($attempt=1;$attempt -le 3;$attempt++){
   if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $seed.fixturePath}).Count){throw 'A fixture instance already exists; retained.'}
   $explorerLaunch=[DateTime]::UtcNow
   $desktopShell.ShellExecute($seed.fixturePath,'-t 127.0.0.1',$folder,'open',0)
   WaitFor {@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $seed.fixturePath}).Count -gt 0} 30 'desktop fixture'|Out-Null
   $match=Get-ShippedFixture $seed.fixturePath $explorerLaunch
   $p=Get-Process -Id $match.ProcessId
   $ownedProcess=New-OwnedProcess $p;$script:fixtures.Add($ownedProcess)
   $p.Refresh();$before=@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinity=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}
   $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
   $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$cim.ParentProcessId)
   if([IO.Path]::GetFileName($parent.ExecutablePath) -ine 'explorer.exe'){throw 'Fixture was not launched by desktop Explorer.'}
   $row=@{attempt=$attempt;before=$before;identity=$ownedProcess.Identity;parent=@{pid=$cim.ParentProcessId;image=$parent.ExecutablePath}}
   $distinct=$before.priorityClass -ne 'High' -and $before.affinity -ne 3 -and $before.memoryPriority -ne 2
   if(-not$distinct){$row.outcome='Initial sample already equals at least one target; inconclusive.';$attempts+=@($row);Save 'saved-rule-launch-attempts.json' $attempts;Stop-OwnedProcess $ownedProcess;continue}
   Save 'saved-rule-launch-attempts.json' @($attempts+@($row))
   Check 'fresh game starts with all three controls different from the rule' $row $distinct 'saved-rule-launch-attempts.json'
   $until=[DateTime]::UtcNow.AddSeconds(60)
   do{$p.Refresh();$after=@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinity=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)};if($after.priorityClass -eq 'High' -and $after.affinity -eq 3 -and $after.memoryPriority -eq 2){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until)
   $row.after=$after;$attempts+=@($row);Save 'saved-rule-launch-attempts.json' $attempts
   Save 'saved-rule-independent-readback.json' @{before=$before;after=$after;expected=$seed.controls;parent=$row.parent;attempts=$attempts;governor=$governor}
   Check 'fresh game receives saved controls' $after ($after.priorityClass -eq 'High' -and $after.affinity -eq 3 -and $after.memoryPriority -eq 2) 'saved-rule-independent-readback.json'
   Stop-OwnedProcess $ownedProcess;$observed=$true;break
  }
  if(-not$observed){throw 'Harness could not sample three distinct initial control values in three desktop launches.'}
 }finally{
  if($folderWindow){$folderWindow.Quit()}
  if($shell){[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)|Out-Null}
 }
}
function AppLog{
 $segment=Read-ShippedLog $script:partLogCursor
 [IO.File]::WriteAllText((Join-Path $directory 'app-log-new.txt'),$segment,$utf8)
 $errors=@($segment -split "`n"|Where-Object {$_ -match 'Exception|Unhandled|\[fatal\]'})
 Check 'app log has no exceptions' $errors ($errors.Count -eq 0) 'app-log-new.txt'
 $logged=@($segment -split "`n"|Where-Object {$_ -like '*[[]update]*'})
 Save 'update-log-lines.json' $logged
 $script:checks.Add(@{check='app log fetch/keyId/Current detail';status=if($segment -match [regex]::Escape($release.keyId) -and $segment -match [regex]::Escape($release.feedUrl)){'pass'}else{'unverified'};observed=@{lines=$logged;source='UpdateService.CheckAsync logs Current reason only; no request URL or keyId logging in shipped code'};evidence='update-log-lines.json'})
}
function Remove-ShippedHosts{
 if(-not$script:hostsCreated){return}
 $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
 $lines=[IO.File]::ReadAllLines($path)
 $owned=@($lines|Where-Object {$_.EndsWith($script:hostsMarker,[StringComparison]::Ordinal)})
 if($owned.Count -ne 1){throw 'Owned hosts marker was changed or removed; retain evidence.'}
 [IO.File]::WriteAllLines($path,@($lines|Where-Object {-not$_.EndsWith($script:hostsMarker,[StringComparison]::Ordinal)}),[Text.UTF8Encoding]::new($false))
 if([IO.File]::ReadAllText($path).Contains($script:hostsMarker)){throw 'Owned hosts line remains.'}
 $script:hostsCreated=$false
 & ipconfig.exe /flushdns|Out-Null
 if($LASTEXITCODE){throw 'DNS flush failed.'}
}
function HangingNetwork{
 $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$hostName=([uri]$release.feedUrl).DnsSafeHost
 $begin=[DateTime]::UtcNow
 $line='192.0.2.1 '+$hostName+' '+$script:hostsMarker
 try{
  [IO.File]::AppendAllText($path,"`r`n"+$line+"`r`n",[Text.UTF8Encoding]::new($false));$script:hostsCreated=$true
  if(-not[IO.File]::ReadAllText($path).Contains($line)){throw 'Owned hosts entry was reverted.'}
  & ipconfig.exe /flushdns|Out-Null;if($LASTEXITCODE){throw 'DNS flush failed.'}
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
 $status=WaitStatus "Couldn't check for updates.*" ([Math]::Max(1,30-[int]$clock.Elapsed.TotalSeconds))
 $clock.Stop();Shot 'hanging-timeout'
 Check 'navigation renders during a hanging network check' $pages ($pages.Count -eq 3) 'hanging-settings.png'
 Check 'hanging check reports timeout within 30 seconds' @{text=$status;seconds=$clock.Elapsed.TotalSeconds;alive=(-not$script:app.HasExited)} ($clock.Elapsed.TotalSeconds -le 30 -and $status -like "Couldn't check for updates.*") 'hanging-timeout.png'
 if(-not[IO.File]::ReadAllText($path).Contains($line)){throw 'Owned hosts entry was reverted during the test.'}
 Remove-ShippedHosts
 Check 'owned hosts entry removed' @{marker=$script:hostsMarker;exists=[IO.File]::ReadAllText($path).Contains($script:hostsMarker)} (-not[IO.File]::ReadAllText($path).Contains($script:hostsMarker))
 Current $true
}
if($HarnessOnly){return}
try{
 Receipt
 switch($Part){
  'p2'{
   if(-not$PayloadHashes -or -not$OldInstaller -or -not$OldVersion){throw 'p2 requires PayloadHashes, OldInstaller and OldVersion.'}
   if(Test-Path $updates){
    Save 'earlier-test-updates.json' @(UpdateFiles)
    $archive=Join-Path $OutRoot 'earlier-test-updates'
    if(Test-Path $archive){throw 'Earlier test-update archive already exists; retain both folders.'}
    [IO.Directory]::Move($updates,$archive)
   }
   Uninstall
   Wizard $OldInstaller 'baseline' $OldVersion
   SeedTester
   $oldApp=$script:owned
   $published=DownloadPublished
   $script:governorBeforeUpgrade=GovernorRead;Save 'governor-immediately-before-upgrade.json' $script:governorBeforeUpgrade
   Wizard $published 'published' $release.payload.version
   Check 'installer closed old app automatically' $oldApp.Identity (-not(Test-OwnedProcess $oldApp))
   $script:governorStarted=$true
   WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 70 'enabled governor resumes'|Out-Null
   Launch;Versions;Payload;Preservation;GovernorVerified;SavedRuleReadback;Current $false
   $files=@(UpdateFiles);$segment=Read-ShippedLog $script:appLogCursor;Check 'up-to-date check starts no download and leaves update folder empty' @{files=$files;log=$segment} ($files.Count -eq 0 -and $segment -like '*[[]update] You have the latest version*' -and $segment -notmatch '[[]update] Downloading')
   $setupLog=[IO.File]::ReadAllText((Join-Path $directory 'published-setup.log'))
   $candidates=@($setupLog -split "`n"|Where-Object {$_ -match '(?i)\berror\b|\bexception\b'})
   $errors=@($candidates|Where-Object {$_ -notmatch '^\d{4}-\d{2}-\d{2} .*?\s+(Dest filename|Source filename): '})
   Save 'setup-error-audit.json' @{errors=$errors;filenameLines=@($candidates|Where-Object {$_ -notin $errors})}
   Check 'published setup log has no errors' $errors ($errors.Count -eq 0) 'setup-error-audit.json'
   AppLog
  }
  'p3-alpha'{
   if(-not$AlphaInstaller -or -not$AlphaVersion){throw 'p3-alpha requires AlphaInstaller and AlphaVersion.'}
   $script:governorStarted=$true
   Wizard $AlphaInstaller 'alpha' $AlphaVersion
   Preservation
   Check 'alpha installed over newer beta' @{version=Version;log=(Join-Path $directory 'alpha-setup.log')} ((Version) -eq $AlphaVersion) 'alpha-setup.log'
  }
  'p3'{
   $script:governorStarted=$true
   Check 'startup update folder is empty' @(UpdateFiles) (@(UpdateFiles).Count -eq 0)
   Governor 'Resume'|Out-Null
   WaitFor {(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 60 'governor running before OTA'|Out-Null
   Launch
   $launched=[DateTime]::UtcNow
   WaitFor {@(Texts) -contains 'Start here'} 90 'alpha Home'|Out-Null
   $until=[DateTime]::UtcNow.AddSeconds(80);$download=$null
   while([DateTime]::UtcNow -lt $until){
    CollectStarts
    $files=@(Get-ChildItem (Join-Path $updates $release.payload.version) -File -ErrorAction SilentlyContinue)
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
   $download=$downloads[0];$created=(Get-Item $download.path).CreationTimeUtc
   Check 'installer was created after this app launch' @{created=$created;appStarted=$script:app.StartTime.ToUniversalTime()} ($created -ge $script:app.StartTime.ToUniversalTime())
   Save 'live-download.json' @{file=$download;secondsFromLaunch=([DateTime]::UtcNow-$launched).TotalSeconds;automaticDownloads=$toggle;checkButtonPressed=$false;status=$ready;texts=@(Texts)}
   Check 'startup live download exactly signed published bytes' $download ($download.bytes -eq $item.size -and $download.sha256 -ieq $item.sha256) 'live-download.json'
   $script:governorBeforeUpgrade=GovernorRead;Save 'governor-immediately-before-upgrade.json' $script:governorBeforeUpgrade
   $prior=$script:app.Id;Click 'UpdateInstallButton'
   WaitFor {ByName 'Install'} 30 'Install confirmation'|Out-Null;Shot 'install-confirmation';$script:installPressed=[DateTime]::UtcNow;Activate (ByName 'Install')
   $until=[DateTime]::UtcNow.AddMinutes(5)
   while([DateTime]::UtcNow -lt $until){CollectStarts;$pending=Join-Path $updates 'pending-install.json';if(Test-Path $pending){try{Save 'pending-install-observed.json' (Get-Content -Raw $pending|ConvertFrom-Json)}catch{}};if($script:app.HasExited -and (Version) -eq $release.payload.version){break};Start-Sleep -Milliseconds 100}
   Check 'alpha exits for silent setup' @{pid=$prior;exited=$script:app.HasExited} $script:app.HasExited
   $script:app=$null;$script:owned=$null;$script:window=$null;$script:launchAfter=$script:installPressed;$script:appLogCursor=Get-ShippedLogCursor $logPath;Attach;Settings
   $updated=WaitStatus ('Updated to version '+$release.payload.version) 100;Shot 'updated-banner'
   Check 'update relaunch and banner' @{priorPid=$prior;newPid=$script:app.Id;status=$updated;texts=@(Texts)} ($script:app.Id -ne $prior -and $updated -ceq ('Updated to version '+$release.payload.version)) 'updated-banner.png'
   CollectStarts
   $setup=@($script:starts|Where-Object {$_.arguments -like '*/ROOWAITPID=*' -and $_.arguments -like '*/ROORELAUNCH=1*'})
   Check 'silent installer wait/relaunch arguments' $setup ($setup.Count -gt 0) 'process-starts-detailed.json'
   Check 'successful pending record consumed' @{pendingExists=(Test-Path (Join-Path $updates 'pending-install.json'));status=$updated} (-not(Test-Path (Join-Path $updates 'pending-install.json')))
   Versions;Payload;Preservation;GovernorVerified;Current $true;AppLog
   Save 'updates-final.json' @(UpdateFiles)
  }
  'p4'{
   $script:governorStarted=$true
   New-ShippedFirewall $firewallName $script:firewallNonce $exe
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
   if(-not$PreflightPath){throw 'p5 requires PreflightPath.'}
   $before=Get-Content -Raw $PreflightPath|ConvertFrom-Json
   $published=DownloadPublished;Wizard $published 'published' $release.payload.version
   Payload
   Launch;Versions;Current $false
   Activate (ByName 'Memory')
   $guides=Get-Content -Raw (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\Assets\Guides\memory-guides.json')|ConvertFrom-Json
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
   & (Join-Path $Source 'tools\validation\Background\Invoke-BackgroundScenario.ps1') -Source $Source -BackendSource $install -OutRoot $directory -Scenario presets
   if(-not$?){throw 'Published CCD preset/restore failed.'}
   $placement=Get-Content -Raw (Join-Path $directory 'presets\placement-after.json')|ConvertFrom-Json
   $topology=@(& (Join-Path $install 'backend\scripts\Get-BackgroundPlacement.ps1')) -join "`n"|ConvertFrom-Json
   . (Join-Path $install 'backend\scripts\BackgroundPlacement.Common.ps1')
   $target=[RooIndustries.Optimization.CpuSets.Target]::new($PID,$false)
   try{$cpus=@($target.Topology())}finally{$target.Dispose()}
   $originals=Get-Content -Raw (Join-Path $directory 'presets\placement-before.json')|ConvertFrom-Json
   $restored=Get-Content -Raw (Join-Path $directory 'presets\placement-restored.json')|ConvertFrom-Json
   $cpu0=@($cpus|Where-Object {$_.group -eq 0 -and $_.logicalProcessorIndex -eq 0})|Select-Object -First 1
   [uint64]$ccdMask=0;[uint64]$fullMask=0
   foreach($cpu in @($cpus|Where-Object group -eq 0)){
    $bit=[uint64]1 -shl $cpu.logicalProcessorIndex;$fullMask=$fullMask -bor $bit
    if($cpu.lastLevelCacheIndex -ne $cpu0.lastLevelCacheIndex){$ccdMask=$ccdMask -bor $bit}
   }
   $background=@($placement|Where-Object name -in 'RooFixtureUpdater','RooFixtureWebHelper')
   $untouched=@($placement|Where-Object name -in 'RooFixtureGame','MsMpEng')
   $restoreMismatches=@()
   foreach($original in $originals){
    $actual=@($restored|Where-Object pid -eq $original.pid)
    foreach($field in 'name','path','startTimeUtc','priorityClass','affinityMask','ioPriority','memoryPriority'){
     if($actual.Count -ne 1 -or $actual[0].$field -ne $original.$field){$restoreMismatches+=@(@{pid=$original.pid;field=$field;expected=$original.$field;observed=if($actual.Count -eq 1){$actual[0].$field}else{$null}})}
    }
   }
   $passed=$topology.available -and $topology.kind -eq 'ccd' -and $cpu0 -and $ccdMask -ne 0 -and [uint64]$topology.mask -eq $ccdMask -and $background.Count -eq 2 -and $untouched.Count -eq 2 -and @($background|Where-Object {[uint64]$_.affinityMask -ne $ccdMask}).Count -eq 0 -and @($untouched|Where-Object {[uint64]$_.affinityMask -ne $fullMask}).Count -eq 0 -and $originals.Count -eq 4 -and $restored.Count -eq $originals.Count -and $restoreMismatches.Count -eq 0
   Check 'published CCD placement apply/restore' @{topology=$topology;logicalProcessorCount=$cpus.Count;cpus=$cpus;expectedCcdMask=$ccdMask;fullMask=$fullMask;readback=$placement;originals=$originals;restored=$restored;restoreMismatches=$restoreMismatches} $passed 'presets/placement-after.json'
   if(-not$before.installedVersion){
    CollectStarts
    foreach($process in $script:extraProcesses){Stop-OwnedProcess $process}
    Uninstall
    $active=Get-RooIndustriesLocalDataRoot
    Check 'uninstaller leftovers before harness cleanup' @{activeRoot=$active;dataExists=(Test-Path $active);installExists=(Test-Path $install);dataFiles=@(if(Test-Path $active){Get-ChildItem $active -File -Recurse|Select-Object FullName,Length})} $true
    if(Test-Path $active){Move-ShippedFreshData $active $before (Join-Path $directory 'removed-test-data')}
    $tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,State)
    $services=@(Get-Service|Where-Object {$_.Name -match 'RooIndustries|RooOptimizationSuite'}|Select-Object Name,Status)
    Check 'fresh-install uninstall leaves no Suite tasks services files or data' @{tasks=$tasks;services=$services;installExists=(Test-Path $install);dataExists=(Test-Path $data);dataArchived=(Join-Path $directory 'removed-test-data')} ($tasks.Count -eq 0 -and $services.Count -eq 0 -and -not(Test-Path $install) -and -not(Test-Path $data))
   }
   $cs2=@(Get-ScheduledTask|Where-Object {$_.TaskName -like '*CS2*'}|Select-Object TaskName,State,@{n='enabled';e={$_.Settings.Enabled}})
   Check 'as-found CS2 tasks remain Ready and Enabled' $cs2 (@($cs2|Where-Object {$_.State -ne 'Ready' -or -not$_.enabled}).Count -eq 0 -and $cs2.Count -eq @($before.tasks|Where-Object {$_.name -like '*CS2*'}).Count)
  }
 }
 CollectStarts;$script:receiptStatus='pass'
}catch{
 CollectStarts;$script:receiptStatus='fail';Save 'failure.json' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage;texts=if($script:window){try{@(Texts)}catch{@()}}else{@()};checks=@($script:checks)};Receipt;throw
}finally{
 try{Remove-ShippedFirewall $firewallName $script:firewallNonce $script:firewallCreated}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 try{Remove-ShippedHosts}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 foreach($fixture in $script:fixtures){try{Stop-OwnedProcess $fixture}catch{$script:cleanupErrors.Add($_.Exception.Message)}}
 try{StopApp}catch{$script:cleanupErrors.Add($_.Exception.Message)}
 if($script:governorStarted -and (Test-Path $hostExe)){
  try{Governor 'Pause'|Out-Null;WaitFor {-not(Core 'policy-status' @{policyRoot=$ruleRoot}).hostRunning} 40 'owned governor stops'|Out-Null}catch{$script:cleanupErrors.Add($_.Exception.Message);Save 'governor-cleanup-error.json' @{error=$_.Exception.Message}}
 }
 foreach($process in @($script:setupReceipts)+@($script:extraProcesses)){try{Stop-OwnedProcess $process}catch{$script:cleanupErrors.Add($_.Exception.Message)}}
 $browserFolder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('Downloads\RooTest-Shipped-'+$FrameId)
 if(Test-Path $browserFolder){
  $files=@(Get-ChildItem $browserFolder -Force)
  if($files.Count -eq 1 -and -not($files[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -and $files[0].Length -eq $item.size -and (Get-FileHash $files[0].FullName).Hash -ieq $item.sha256){[IO.Directory]::Move($browserFolder,(Join-Path $directory 'browser-download'))}
 }
 Save 'process-starts.json' @(ProcessStarts)
 Unregister-Event -SourceIdentifier $events -ErrorAction SilentlyContinue
 Get-Event -SourceIdentifier $events -ErrorAction SilentlyContinue|Remove-Event
 $script:receiptStatus=Get-ShippedFinalStatus $script:receiptStatus @($script:cleanupErrors)
 Receipt
 if($script:cleanupErrors.Count){throw ('Cleanup failed: '+($script:cleanupErrors -join '; '))}
}
