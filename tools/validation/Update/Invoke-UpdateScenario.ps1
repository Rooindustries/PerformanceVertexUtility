param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
    [Parameter(Mandatory)][ValidateSet('seed','manual-install','feed-down','slow-feed','close-during-check','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','manual-download','ready','scheduled-download','blocked','cancel','install','failure','copy-failure','cleanup','transport-error','manual-timeout','settings-readonly','timer-read-failure')][string]$Scenario,
    [string]$InstallerPath='', [string]$ExpectedVersion='', [string]$EvidenceName='', [string]$FixtureExe='',[switch]$ManualRetry,[switch]$HelpersOnly,[string]$NextVersion='',[string]$InitialDataRoot='',[switch]$CurrentData)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation $(if($HelpersOnly -and $EvidenceName){$EvidenceName}else{$Scenario}) $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
if(-not('RooUpdateUi' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooUpdateUi {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window,int mode);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr window,int index);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr window);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr window);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out int processId);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr window,uint message,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
}
'@}
[RooUpdateUi]::SetProcessDPIAware()|Out-Null
$install='C:\Program Files\Roo Industries\Optimization Suite'
$exe=if($FixtureExe){$FixtureExe}else{Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe'}
$hostExe=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$data=if($InitialDataRoot){$InitialDataRoot}else{Get-RooIndustriesLocalDataRoot}
$updates=Join-Path $data 'updates'
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$utf8=[Text.UTF8Encoding]::new($false)
$directory=New-HarnessEvidenceDirectory $OutRoot $(if($EvidenceName){$EvidenceName}else{$Scenario})
$script:window=$null;$script:app=$null;$script:owned=$null;$settingsAttributes=$null;$settingsOriginal=$null;$settingsPath=Join-Path $data 'settings.json'
$script:setupReceipts=[Collections.Generic.List[object]]::new()
Start-ProcessTrace|Out-Null
Start-Sleep -Milliseconds 500
function Save([string]$name,$value){Write-HarnessResult $directory $name $value|Out-Null}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$until=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $until){if($script:smartScreenBefore){Assert-HarnessNewSmartScreen $script:smartScreenBefore $directory};try{$v=& $probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function ById([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function ByName([string]$name){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))}
function ByNameControl([string]$name,$type){@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))|Where-Object {$_.Current.ControlType -eq $type -or ($type -eq $CT::Button -and $_.Current.ClassName -in @('TNewButton','Button'))})|Select-Object -First 1}
function Activate($element){
 if(-not(Test-OwnedDescendant ([int]$element.Current.ProcessId))){throw 'Control belongs to a foreign window; retained.'}
 try{$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{}
 try{$element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();return}catch{}
 $expander=$element
 for($i=0;$expander -and $i -lt 3;$i++){
  try{$expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand();return}catch{}
  $expander=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($expander)
 }
 if($element.Current.ClassName -eq 'Button' -and $element.Current.ControlType -eq $CT::Pane){
  $handle=[IntPtr]::new($element.Current.NativeWindowHandle);$parent=[RooUpdateUi]::GetParent($handle)
  [int]$owner=0;[RooUpdateUi]::GetWindowThreadProcessId($parent,[ref]$owner)|Out-Null
  if($owner -ne $element.Current.ProcessId){throw 'Button parent belongs to another process.'}
  [IntPtr]$result=[IntPtr]::Zero
  if(-not[RooUpdateUi]::SendMessageTimeout($parent,0x111,[IntPtr]::new([RooUpdateUi]::GetDlgCtrlID($handle)),$handle,3,2000,[ref]$result)){throw 'Native dialog button refused input.'}
  return
 }
 if($element.Current.NativeWindowHandle -and ($element.Current.ControlType -in @($CT::Button,$CT::CheckBox) -or $element.Current.ClassName -in @('TNewButton','Button'))){
  if([RooUpdateUi]::PostMessage([IntPtr]::new($element.Current.NativeWindowHandle),0xF5,[IntPtr]::Zero,[IntPtr]::Zero)){return}
  throw ('Native button refused input, Win32 '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())
 }
 throw ('Control cannot be activated: '+$element.Current.Name+' '+$element.Current.ControlType.ProgrammaticName)
}
function Click([string]$id){$e=WaitFor {$x=ById $id;if($x -and $x.Current.IsEnabled){$x}} 90 $id;Activate $e}
function Texts{@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {[string]$_.Current.Name}|Where-Object {$_})}
function Settings{Activate (WaitFor {ByName 'Settings'} 40 'Settings navigation');WaitFor {ById 'UpdateStatusText'} 40 'update settings'|Out-Null}
function StatusText{[string](ById 'UpdateStatusText').Current.Name}
function WaitStatus([string]$expected,[int]$seconds=100){WaitFor {$text=StatusText;if($text -like $expected){$text}} $seconds $expected}
function Shot([string]$name){
 Register-HarnessWindow $script:window|Out-Null
 $handle=[IntPtr]::new($script:window.Current.NativeWindowHandle)
 $wasTopmost=([RooUpdateUi]::GetWindowLongPtr($handle,-20).ToInt64() -band 8) -ne 0
 $bitmap=$null;$graphics=$null
 try{
  [RooUpdateUi]::ShowWindow($handle,9)|Out-Null
  if(-not[RooUpdateUi]::SetWindowPos($handle,[IntPtr]::new(-1),0,0,0,0,0x53)){throw 'Screenshot window could not be raised.'}
  Start-Sleep -Milliseconds 300
  $r=$script:window.Current.BoundingRectangle
  $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size)
  $path=Get-HarnessOutputPath $directory ($name+'.png');$stream=[IO.FileStream]::new((Get-HarnessLongPath $path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)}finally{$stream.Dispose()};Register-HarnessFile $path 'screenshot'|Out-Null
 }finally{
  if($graphics){$graphics.Dispose()};if($bitmap){$bitmap.Dispose()}
  [RooUpdateUi]::SetWindowPos($handle,[IntPtr]::new($(if($wasTopmost){-1}else{-2})),0,0,0,0,0x13)|Out-Null
 }
}
function Core([string]$action,[hashtable]$fields){Assert-HarnessHostLease;$request=@{schemaVersion=1;repoRoot=$install;confirm=$true};foreach($name in $fields.Keys){$request[$name]=$fields[$name]};Save ('request-'+$action+'.json') $request;$result=Invoke-HarnessHost $hostExe $action $request;if($result.status -ne 'completed'){throw ($action+': '+($result|ConvertTo-Json -Depth 40))};return $result.data}
function CollectOwnedStarts{
 foreach($cim in @(Get-CimInstance Win32_Process)){
  if($cim.Name -match '(?i)setup|unins|RooIndustries|Optimizer\.|notepad') {Test-OwnedDescendant ([int]$cim.ProcessId)|Out-Null}
 }
}
function Attach{
 $script:app=WaitFor {
  CollectOwnedStarts
  $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $exe})
  if($matches.Count -gt 1){throw 'Several app instances; retained.'}
  if($matches.Count -eq 1){
   $owned=if($script:installPressed){Test-TracedDescendant ([int]$matches[0].ProcessId) -PassThru}else{Get-HarnessProcess ([int]$matches[0].ProcessId)}
   if(-not$owned){throw 'An app instance is already running that this run did not start; retained.'}
   if($script:installPressed -and $owned.process.StartTime.ToUniversalTime() -lt $script:installPressed){throw 'Post-update app predates Install; retained.'}
   $script:owned=$owned;return $owned.process
  }
 } 150 'owned installed app'
 $script:window=WaitFor {@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id))|Where-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings'))})|Select-Object -First 1} 120 'app navigation window'
 Register-HarnessWindow $script:window|Out-Null
 Save 'owned-app.json' @{identity=$script:owned.Identity;ownershipProof=$script:owned.OwnershipProof}
}
function Launch{
 Assert-HarnessHostLease
 Assert-NoForeignInstance $exe
 if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $exe}).Count){throw 'This invocation already has an app; stop it before launching another.'}
 $script:launchAfter=[DateTime]::UtcNow;$script:installPressed=$null;$script:appLogCursor=Get-ShippedLogCursor (Join-Path $data 'logs\app.log')
 Assert-HarnessHostLease
 $script:owned=Start-OwnedProcess -FilePath $exe -WindowStyle Normal -Purpose app
 $script:app=$script:owned.process;Attach
}
function StopApp{if($script:owned){if(-not$script:app.HasExited){$script:app.CloseMainWindow()|Out-Null;$script:app.WaitForExit(20000)|Out-Null};Stop-HarnessProcess $script:owned;$script:owned=$null;$script:app=$null;$script:window=$null}}
function Version{(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1').DisplayVersion}
function UpdateFiles{@(if(Test-HarnessPath $updates){Get-HarnessTree $updates -FilesOnly|Where-Object {Test-HarnessVisiblePath $_ $updates}|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-HarnessFileSha256 $_.LongPath)}}})}
function ProcessStarts{Receive-ProcessTrace;@(Get-HarnessEntries|Where-Object {$_.kind -eq 'trace' -and $_.nonce -ceq $nonce -and $_.identity.processName -match '(?i)RooIndustries|Optimizer\.|ProcessGovernor|powershell|setup'}|ForEach-Object {@{pid=$_.identity.processId;parentPid=$_.identity.parentProcessId;image=$_.identity.processName;time=$_.identity.timeCreatedFileTimeUtc;eventNonce=$_.identity.eventNonce}})}
function Readback{
 $settings=if(Test-HarnessPath (Join-Path $data 'settings.json')){[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $data 'settings.json')))|ConvertFrom-Json}else{$null}
 @{installedVersion=Version;runningPid=if($script:app){$script:app.Id}else{$null};runningImage=if($script:app){$script:app.Path}else{$null};runningProductVersion=if($script:app){(Get-HarnessItem $script:app.Path).VersionInfo.ProductVersion}else{$null};installedProductVersion=(Get-HarnessItem $exe).VersionInfo.ProductVersion;settings=$settings;status=if($script:window -and (ById 'UpdateStatusText')){StatusText}else{$null};texts=if($script:window){@(Texts)}else{@()};files=@(UpdateFiles);processStarts=@(ProcessStarts);helpers=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like ($install+'\*') -or $script:app -and $_.ParentProcessId -eq $script:app.Id}|Select-Object ProcessId,ParentProcessId,ExecutablePath);governor=(Core 'policy-status' @{policyRoot=(Join-Path $data 'process-rules')});governorTasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,TaskPath,State,@{n='enabled';e={$_.Settings.Enabled}},@{n='userId';e={$_.Principal.UserId}});utc=[DateTime]::UtcNow.ToString('o')}
}
function CapturePreservation{
 $files=@()
 foreach($root in @((Join-Path $data 'process-rules\rules'),(Join-Path $data 'operations'))){
  if(Test-HarnessPath $root){$files+=@(Get-HarnessTree $root -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ $root) -and [IO.Path]::GetFileName($_.FullName) -notlike '*.lock'}|ForEach-Object {@{path=$_.FullName;sha256=(Get-HarnessFileSha256 $_.LongPath)}})}
 }
 $settings=if(Test-HarnessPath $settingsPath){[IO.File]::ReadAllText((Get-HarnessLongPath $settingsPath))|ConvertFrom-Json}else{$null}
 $governor=Core 'policy-status' @{policyRoot=(Join-Path $data 'process-rules')}
 if($governor.error){throw ('Could not capture governor state: '+$governor.error)}
 return @{files=$files;themeId=$settings.themeId;hostRunning=$governor.hostRunning}
}
function Preserved($Snapshot=$null){
 $seed=if($Snapshot){$Snapshot}else{Read-HarnessLatestResult 'preservation.json' 'seed'}
 $changed=@($seed.files|Where-Object {-not[IO.File]::Exists((Get-HarnessLongPath $_.path)) -or (Get-HarnessFileSha256 $_.path) -cne $_.sha256})
 if($changed.Count){throw ('Preserved files changed: '+($changed.path -join ', '))}
 $settings=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $data 'settings.json')))|ConvertFrom-Json
 if($settings.themeId -ne $seed.themeId){throw 'Theme did not survive the upgrade'}
 $before=if($Snapshot){@{governor=@{hostRunning=$Snapshot.hostRunning}}}else{Read-HarnessLatestResult 'before.json' 'seed'}
 $governor=Core 'policy-status' @{policyRoot=(Join-Path $data 'process-rules')}
 if($governor.hostRunning -ne $before.governor.hostRunning -or $governor.error){throw 'Governor running state changed across the upgrade'}
 Save 'preservation.json' @{allFilesMatch=$true;files=$seed.files;themeId=$settings.themeId}
}
if($HelpersOnly){return}
$script:scenarioStatus='running'
if(-not$ExpectedVersion){
 $project=[xml][IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj')))
 $ExpectedVersion=$project.SelectSingleNode('//Version').InnerText.Trim()
}
if(-not$NextVersion){
 $match=[regex]::Match($ExpectedVersion,'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
 if(-not$match.Success){throw 'ExpectedVersion must be a SemVer release version.'}
 $NextVersion='{0}.{1}.{2}{3}' -f $match.Groups[1].Value,$match.Groups[2].Value,([int64]$match.Groups[3].Value+1),$match.Groups[4].Value
}
Initialize-HarnessCache $updates @($ExpectedVersion,$NextVersion)
try{
 switch($Scenario){
  'seed' {
   Launch;WaitFor {@(Texts) -contains 'Start here'} 120 '0.10 Home'|Out-Null;StopApp
   $fixture=Join-Path $data ('ota-fixture-'+$nonce);New-HarnessDirectory $fixture 'saved-rule-fixture'|Out-Null
   $target=Join-Path $fixture 'ota-rule-target.exe';Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $target|Out-Null
   $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
   $rule=@{schemaVersion=1;ruleId=([Guid]::NewGuid().ToString('N'));owner=@{machine=$env:COMPUTERNAME;userSid=$sid};name='OTA preserved rule';enabled=$false;matchMode='path';executablePath=$target;executableHash=$null;controls=@{cpuPriority='Normal'};cpuSelection=$null}
   Save 'saved-rule.json' (Core 'rule-save' @{policyRoot=(Join-Path $data 'process-rules');rule=$rule})
   $settingsPath=Join-Path $data 'settings.json';$settings=[IO.File]::ReadAllText((Get-HarnessLongPath $settingsPath))|ConvertFrom-Json
   Save 'as-found-settings.json' $settings
   $settings|Add-Member themeId 'roo-industries-blue' -Force;$settings|Add-Member simpleMode '1' -Force
   [IO.File]::WriteAllText((Get-HarnessLongPath $settingsPath),($settings|ConvertTo-Json -Compress),$utf8)
   $files=@(Get-HarnessTree (Join-Path $data 'process-rules\rules') -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ (Join-Path $data 'process-rules\rules')) -and [IO.Path]::GetDirectoryName($_.FullName) -ieq (Join-Path $data 'process-rules\rules')}|ForEach-Object {@{path=$_.FullName;sha256=(Get-HarnessFileSha256 $_.LongPath)}})
   if(Test-HarnessPath (Join-Path $data 'operations')){$files+=@(Get-HarnessTree (Join-Path $data 'operations') -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ (Join-Path $data 'operations')) -and [IO.Path]::GetFileName($_.FullName) -notlike '*.lock'}|ForEach-Object {@{path=$_.FullName;sha256=(Get-HarnessFileSha256 $_.LongPath)}})}
   Save 'preservation.json' @{files=$files;themeId='roo-industries-blue';ruleId=$rule.ruleId}
   Save 'before.json' (Readback)
  }
  'manual-install' {
   Assert-HarnessInstallStart $exe
   if(-not$InstallerPath){throw 'InstallerPath required'}
   $installSnapshot=if($CurrentData){CapturePreservation}else{$null}
   if($installSnapshot){Save 'install-preservation-before.json' $installSnapshot}
   $script:smartScreenBefore=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.NativeWindowHandle})
   Assert-HarnessInstallStart $exe
   $setupOwned=Start-OwnedProcess -FilePath $InstallerPath -ArgumentList ('/SUPPRESSMSGBOXES /NORESTART /LOG="'+(Join-Path $directory ('setup-'+$nonce+'.log'))+'"') -WindowStyle Normal -Purpose setup
   $setup=$setupOwned.process
   $script:setupReceipts.Add($setupOwned);Save 'owned-setup.json' @($script:setupReceipts.Identity)
   $until=[DateTime]::UtcNow.AddMinutes(6)
   $guideCleared=$false
   while(-not$setup.HasExited -and [DateTime]::UtcNow -lt $until){
    Assert-HarnessNewSmartScreen $script:smartScreenBefore $directory
    foreach($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$setup.Id))){if($child.ProcessId -notin @($script:setupReceipts.Identity.pid)){$receipt=Test-OwnedDescendant ([int]$child.ProcessId) -PassThru;if($receipt){$script:setupReceipts.Add($receipt);Save 'owned-setup.json' @($script:setupReceipts.Identity)}}}
    $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Window))|Where-Object {$_.Current.ProcessId -in @($script:setupReceipts.Identity.pid)})
    foreach($win in $windows){$script:window=Register-HarnessWindow $win
     foreach($name in @('Read the beta tester guide')){ $box=ByName $name;if($box){try{$toggle=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}}catch{}} }
     if(-not$guideCleared -and (ByNameControl 'Finish' $CT::Button)){
      $list=$win.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'TNewCheckListBox'))
      if($list){[IntPtr]$result=[IntPtr]::Zero;$handle=[IntPtr]::new($list.Current.NativeWindowHandle)
       [RooUpdateUi]::SendMessageTimeout($handle,0x186,[IntPtr]::Zero,[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null
       [RooUpdateUi]::SendMessageTimeout($handle,0x100,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null
       [RooUpdateUi]::SendMessageTimeout($handle,0x101,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null
       $guideCleared=$true
      }
     }
     foreach($name in 'Finish','Install','Next >','Next'){ $button=ByNameControl $name $CT::Button;if($button -and $button.Current.IsEnabled){Activate $button;Start-Sleep -Milliseconds 500;break} }
    }
    Start-Sleep -Milliseconds 300
   }
   if(-not$setup.HasExited){Save 'setup-stalled-texts.json' @(Texts);throw 'Normal installer did not finish in six minutes'}
   Save 'setup-result.json' @{exitCode=$setup.ExitCode;version=Version};if($setup.ExitCode -ne 0 -or (Version) -ne $ExpectedVersion){throw 'Manual install did not reach expected version'}
   $script:window=$null;Launch;Settings;Shot 'settings';Preserved $installSnapshot
  }
  'cleanup' {Launch;Settings;Save 'final.json' (Readback);StopApp}
  default {
   if($Scenario -eq 'timer-read-failure'){$timerLogPath=Join-Path $data 'logs\app.log';$timerCursor=Get-ShippedLogCursor $timerLogPath}
   Launch;Settings
   if($Scenario -in 'ready','scheduled-download','transport-error'){
    $toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if([string]$toggle.Current.ToggleState -eq 'Off'){$toggle.Toggle()}
   }
   if($Scenario -eq 'ready'){
    Click 'UpdateCheckButton';WaitStatus "Version $NextVersion is ready to install" 180|Out-Null;Preserved
    $cache=Register-HarnessCache $NextVersion;if(-not$cache){throw 'Ready priming did not create a verified cache.'}
    Save 'ready-cache-prime.json' @{app=$script:owned.Identity;cache=$cache.identity;status=StatusText}
    StopApp;Launch;Settings;WaitStatus "Version $NextVersion is ready to install" 180|Out-Null
   }
   if($Scenario -eq 'manual-timeout'){$toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}}
   if($ManualRetry){$toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}}
   if($Scenario -eq 'settings-readonly'){
    $settingsOriginal=[IO.File]::ReadAllBytes((Get-HarnessLongPath $settingsPath));$settingsAttributes=[IO.File]::GetAttributes((Get-HarnessLongPath $settingsPath))
    [IO.File]::SetAttributes((Get-HarnessLongPath $settingsPath),($settingsAttributes -bor [IO.FileAttributes]::ReadOnly))
    $toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);$previous=[string]$toggle.Current.ToggleState;$toggle.Toggle()
    WaitStatus "Couldn't save this setting: *" 15|Out-Null
    WaitFor {[string](ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq $previous} 15 'toggle previous value'|Out-Null
    if($script:app.HasExited -or [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-HarnessLongPath $settingsPath))) -cne [Convert]::ToBase64String($settingsOriginal)){throw 'Read-only setting crashed the app or changed its bytes'}
    Save 'readonly.json' @{previousToggle=$previous;currentToggle=[string](ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState;pid=$script:app.Id;alive=(-not$script:app.HasExited);bytesUnchanged=$true};Shot 'readonly-error'
    Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 40 'Home after settings error'|Out-Null;Settings
   }
   if($Scenario -eq 'manual-download'){
    $toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}
    $theme=ById 'ThemePicker';$theme.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Activate (WaitFor {ByName 'Blackout Gold'} 15 'gold theme');Start-Sleep 1;Attach;Settings
    if(([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $data 'settings.json')))|ConvertFrom-Json).downloadUpdatesAutomatically -ne '0'){throw 'Theme change overwrote automatic download preference'}
    $theme=ById 'ThemePicker';$theme.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Activate (WaitFor {ByName 'Roo Industries Blue'} 15 'blue theme');Start-Sleep 1;Attach;Settings
   }
   if($Scenario -in @('feed-down','slow-feed','close-during-check','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','manual-download','ready','transport-error','manual-timeout')){Click 'UpdateCheckButton'}
   if($ManualRetry -and $Scenario -in 'transport-error','tampered','tampered-size'){WaitStatus "Version $NextVersion is available" 60|Out-Null;Click 'UpdateDownloadButton'}
   $retryText=if($ManualRetry -or $Scenario -eq 'manual-timeout'){'Press Download to try again.'}else{'The app will try again later.'}
   switch($Scenario){
    'feed-down' {WaitStatus "Couldn't check for updates.*" 40|Out-Null;Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 40 'Home remains usable'|Out-Null;Settings}
    'slow-feed' {Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 5 'Home while feed waits'|Out-Null;Settings;WaitStatus "Couldn't check for updates. The request timed out." 30|Out-Null}
    'close-during-check' {WaitStatus 'Checking for updates...' 10|Out-Null;Shot 'checking-before-close';$script:app.CloseMainWindow()|Out-Null;if(-not$script:app.WaitForExit(15000)){throw 'App did not exit cleanly during a check'};Save 'closed-during-check.json' @{exitCode=$script:app.ExitCode;cleanExit=($script:app.ExitCode -eq 0);log=(Read-ShippedLog $script:appLogCursor)};if($script:app.ExitCode -ne 0){throw 'App exit failed'};$script:window=$null}
    'malformed-feed' {WaitStatus "Couldn't verify the update.*"|Out-Null;Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 5 'Home after malformed feed'|Out-Null;Settings}
    'bad-signature' {WaitStatus "Couldn't verify the update.*signature*"|Out-Null}
    'wrong-product' {WaitStatus "Couldn't verify the update. This release is for another product."|Out-Null}
    'wrong-channel' {WaitStatus "Couldn't verify the update. This release is for another update channel."|Out-Null}
    'same-version' {WaitStatus 'You have the latest version'|Out-Null}
    'older-version' {WaitStatus 'You have the latest version'|Out-Null}
    {$_ -in 'tampered','tampered-size'} {WaitStatus ("The download didn't match the signed release, so it was deleted. "+$retryText) 180|Out-Null;if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Rejected installer remains'}}
    'manual-download' {WaitStatus "Version $NextVersion is available"|Out-Null;if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Automatic-off downloaded an installer'};Shot 'available';Click 'UpdateDownloadButton';WaitStatus "Version $NextVersion is ready to install" 180|Out-Null;Preserved}
    'transport-error' {WaitStatus ("Couldn't download the update: *. "+$retryText) 180|Out-Null;if((StatusText) -match "didn't match the signed release"){throw 'Transport error was called a signed-byte mismatch'};if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Transport failure left an installer/partial'};Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 40 'Home after download error'|Out-Null;Settings}
    'manual-timeout' {WaitStatus "Version $NextVersion is available" 60|Out-Null;Click 'UpdateDownloadButton';WaitStatus "Downloading version $NextVersion..." 30|Out-Null;Shot 'downloading';Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 10 'Home during stalled download'|Out-Null;Settings;$started=[DateTime]::UtcNow;WaitStatus "Couldn't download the update: The download timed out. Press Download to try again." 1250|Out-Null;Save 'deadline.json' @{secondsAfterHome=([DateTime]::UtcNow-$started).TotalSeconds;realTimeoutMinutes=20;pid=$script:app.Id;alive=(-not$script:app.HasExited)};if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Timed-out download left bytes'}}
    'timer-read-failure' {Click 'UpdateInstallButton';WaitFor {ByName "Install version $NextVersion now?"} 45 'confirmation despite timer read failure'|Out-Null;Shot 'timer-error-confirmation';Save 'confirmation-tree.json' @($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;type=$_.Current.ControlType.ProgrammaticName;class=$_.Current.ClassName}});Activate (WaitFor {ByName 'Not now'} 15 'cancel timer confirmation');WaitFor {(ById 'UpdateInstallButton').Current.IsEnabled} 20 'confirmation canceled';$newTimerLog=Read-ShippedLog $timerCursor;$timerWarning=@($newTimerLog -split "`n"|Where-Object {$_ -like '*[[]update] Couldn*read the timer setting; treating it as stopped: Fixture timer interval cannot be read.*'});if(-not$timerWarning.Count){throw 'The timer-read failure was not observed in the app log'};Save 'timer-read-failure.json' @{hook='Temporary Core fixture: TimerControl.Read throws unconditionally';fixtureExe=$exe;appAlive=(-not$script:app.HasExited);warning=$timerWarning};if(@(ProcessStarts|Where-Object {$_.image -like '*setup*'}).Count){throw 'Canceled timer-read fixture started an installer'}}
    'ready' {WaitStatus "Version $NextVersion is ready to install" 180|Out-Null;Preserved}
    'scheduled-download' {$started=[DateTime]::UtcNow;WaitStatus "Version $NextVersion is ready to install" 180|Out-Null;Save 'scheduled.json' @{checkButtonPressed=$false;secondsFromSettings=([DateTime]::UtcNow-$started).TotalSeconds};Preserved}
    'blocked' {Click 'UpdateInstallButton';WaitStatus "Stop your game session and turn off the timer setting first. The update can't install while they run."|Out-Null}
    'cancel' {Click 'UpdateInstallButton';WaitFor {ByName 'Not now'} 60 'confirmation'|Out-Null;Shot 'confirmation';Activate (ByName 'Not now');WaitFor {(ById 'UpdateInstallButton').Current.IsEnabled} 20 'canceled'}
    {$_ -in 'install','failure','copy-failure'} {
     if($Scenario -eq 'install'){
      Save 'logs-before.json' @(Get-HarnessChildren $updates -Filter 'install-*.log'|Select-Object Name,Length,LastWriteTimeUtc)
      foreach($i in 0..4){$path=Join-Path $updates ('install-retention-'+$nonce+'-'+$i+'.log');New-HarnessText $path 'owned log retention fixture' 'retention-fixture'|Out-Null;[IO.File]::SetLastWriteTimeUtc((Get-HarnessLongPath $path),[DateTime]::UtcNow.AddMinutes(-10+$i))}
     }
     $prior=0
     $prior=$script:app.Id;Click 'UpdateInstallButton';WaitFor {ByName 'Install'} 60 'confirmation'|Out-Null;Shot 'confirmation';Start-ProcessTrace -Anchor $script:owned|Out-Null;$script:smartScreenBefore=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.NativeWindowHandle});$script:installPressed=[DateTime]::UtcNow;Assert-HarnessInstallStart $exe;Activate (ByName 'Install')
      WaitFor {CollectOwnedStarts;if($script:app.HasExited){return $true};if((StatusText) -like "Couldn't install the update.*"){throw (StatusText)}} 90 'old app exits'|Out-Null
     if($Scenario -eq 'copy-failure'){
      $script:window=WaitFor {$A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.Name -like '*Setup*Roo Industries*' -and $_.Current.ClassName -eq 'TWizardForm'}|ForEach-Object {Register-HarnessWindow $_}|Select-Object -First 1} 180 'interactive recovery setup'
      $setup=Get-Process -Id $script:window.Current.ProcessId;$script:setupReceipts.Add((Test-OwnedDescendant $setup.Id -PassThru))
      Save 'missing-executable.json' @{exists=(Test-HarnessPath $exe -PathType Leaf);destinationIsDirectory=(Test-HarnessPath $exe -PathType Container);installedVersion=Version;setupPid=$script:window.Current.ProcessId;processStarts=@(ProcessStarts)}
      if(Test-HarnessPath $exe -PathType Leaf){throw 'Copy-failure fixture did not remove the old executable'}
      Shot 'interactive-recovery'
      $until=[DateTime]::UtcNow.AddMinutes(6);$guideCleared=$false
      while(-not$setup.HasExited -and [DateTime]::UtcNow -lt $until){
       if(-not$guideCleared -and (ByNameControl 'Finish' $CT::Button)){
        $list=$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'TNewCheckListBox'))
        if(-not$list){throw 'Recovery Finish checkboxes are unavailable'}
        $handle=[IntPtr]::new($list.Current.NativeWindowHandle);[IntPtr]$result=[IntPtr]::Zero
        foreach($index in 0,1){[RooUpdateUi]::SendMessageTimeout($handle,0x186,[IntPtr]::new($index),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null;[RooUpdateUi]::SendMessageTimeout($handle,0x100,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null;[RooUpdateUi]::SendMessageTimeout($handle,0x101,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null}
        Save 'recovery-finish-choices.json' @{readGuide=$false;openApp=$true;source='Inno [Run] defaults: checked guide at index 0, unchecked app at index 1'};Shot 'recovery-finish-open-app';$guideCleared=$true
       }
       foreach($name in 'Finish','Install','Next >','Next'){$button=ByNameControl $name $CT::Button;if($button -and $button.Current.IsEnabled){Activate $button;Start-Sleep -Milliseconds 500;break}}
       Start-Sleep -Milliseconds 200
      }
      if(-not$setup.HasExited -or -not(Test-HarnessPath $exe -PathType Leaf)){throw 'Interactive recovery did not restore the executable'}
      Save 'interactive-recovery-result.json' @{exitCode=$setup.ExitCode;installedVersion=Version;exists=(Test-HarnessPath $exe -PathType Leaf)}
     }
     $script:owned=$null;$script:app=$null;$script:window=$null;Attach;Settings;Save 'relaunch-ownership.json' @{identity=$script:owned.Identity;proof=$script:owned.OwnershipProof};if($script:owned.OwnershipProof.kind -ne 'trace'){throw 'Update relaunch did not use trace proof'}
     if($Scenario -in 'install','copy-failure'){WaitStatus "Updated to version $NextVersion" 90|Out-Null;if((Version) -ne $NextVersion){throw 'Installed version did not advance'};if($Scenario -eq 'install'){if(Test-HarnessPath (Join-Path $updates $NextVersion)){throw 'Installed version cache was retained'};$logs=@(Get-HarnessChildren $updates -Filter 'install-*.log'|Sort-Object LastWriteTimeUtc -Descending);Save 'cleanup-logs.json' @($logs|Select-Object Name,Length,LastWriteTimeUtc);if($logs.Count -ne 3){throw 'Install log retention is not three'};if(Test-HarnessPath (Join-Path $updates 'pending-install.json')){throw 'Successful pending record remains'}}}else{WaitStatus "The update to $NextVersion didn't finish. Setup log: *" 90|Out-Null;if((Version) -ne $ExpectedVersion){throw 'Failure changed installed version'};if((ById 'UpdateInstallButton').Current.Name -ne 'Try again'){throw 'Settings did not offer Try again'};Click 'UpdateCheckButton';WaitStatus "The update to $NextVersion didn't finish. Setup log: *" 90|Out-Null}
     if($script:app.Id -eq $prior){throw 'App did not relaunch'};Preserved
    }
   }
   if($script:window){Shot 'settings-banner'}
   if($Scenario -in @('feed-down','slow-feed','close-during-check','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','blocked','cancel','manual-download','ready','transport-error','manual-timeout','settings-readonly','timer-read-failure')){
    if((Version) -ne $ExpectedVersion){throw 'Refusal/download changed installed version'}
    if(@(ProcessStarts|Where-Object {$_.image -like '*-setup*'}).Count){throw 'Unexpected setup process'}
   }
  }
 }
 Save 'result.json' (Readback)
 $script:scenarioStatus='pass'
 'Scenario '+$Scenario+' completed'
}catch{$script:scenarioStatus='fail';Save 'failure.json' @{error=$_.Exception.ToString();texts=if($script:window){@(Texts)}else{@()};processStarts=@(ProcessStarts)};throw}
finally{
 $cleanupErrors=[Collections.Generic.List[string]]::new()
 if($settingsAttributes -ne $null){try{[IO.File]::SetAttributes((Get-HarnessLongPath $settingsPath),($settingsAttributes -band (-bnot [IO.FileAttributes]::ReadOnly)));[IO.File]::WriteAllBytes((Get-HarnessLongPath $settingsPath),$settingsOriginal);[IO.File]::SetAttributes((Get-HarnessLongPath $settingsPath),$settingsAttributes)}catch{$cleanupErrors.Add($_.Exception.Message)}}
 try{Register-HarnessCache $NextVersion|Out-Null}catch{$cleanupErrors.Add($_.Exception.Message)}
 Save 'process-starts.json' @(ProcessStarts)
 try{StopApp}catch{$cleanupErrors.Add($_.Exception.Message)}
 if($cleanupErrors.Count){$script:scenarioStatus='fail'}
 $status=Complete-HarnessInvocation $script:scenarioStatus -Cleanup
 Save 'invocation.json' @{status=$status;nonce=$nonce;cleanupErrors=@($cleanupErrors)}
 if($cleanupErrors.Count){throw ('Cleanup failed: '+($cleanupErrors -join '; '))}
}
