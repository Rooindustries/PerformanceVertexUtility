param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
    [Parameter(Mandatory)][ValidateSet('seed','manual-install','feed-down','slow-feed','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','manual-download','ready','scheduled-download','blocked','cancel','install','failure','copy-failure','cleanup')][string]$Scenario,
    [string]$InstallerPath='', [string]$ExpectedVersion='0.11.0-beta', [string]$EvidenceName='', [switch]$ResumeCopyRecovery)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooUpdateUi {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window,int mode);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr window,uint message,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
}
'@
[RooUpdateUi]::SetProcessDPIAware()|Out-Null
$install='C:\Program Files\Roo Industries\Optimization Suite'
$exe=Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe'
$hostExe=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$data=Get-RooIndustriesLocalDataRoot
$updates=Join-Path $data 'updates'
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$utf8=[Text.UTF8Encoding]::new($false)
$directory=Join-Path $OutRoot $(if($EvidenceName){$EvidenceName}else{$Scenario})
[IO.Directory]::CreateDirectory($directory)|Out-Null
$script:window=$null;$script:app=$null;$script:owned=$null
$script:setupReceipts=[Collections.Generic.List[object]]::new()
$events='RooIndustries_OTA_'+[Guid]::NewGuid().ToString('N')
Register-WmiEvent -Class Win32_ProcessStartTrace -SourceIdentifier $events|Out-Null
Start-Sleep -Milliseconds 500
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 40),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$until=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $until){try{$v=& $probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function ById([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function ByName([string]$name){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))}
function ByNameControl([string]$name,$type){@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))|Where-Object {$_.Current.ControlType -eq $type -or $type -eq $CT::Button -and $_.Current.ClassName -eq 'TNewButton'})|Select-Object -First 1}
function Activate($element){
 try{$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{}
 try{$element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();return}catch{}
 if($element.Current.NativeWindowHandle -and ($element.Current.ControlType -in @($CT::Button,$CT::CheckBox) -or $element.Current.ClassName -eq 'TNewButton')){
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
 [RooUpdateUi]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),9)|Out-Null
 [RooUpdateUi]::SetForegroundWindow([IntPtr]::new($script:window.Current.NativeWindowHandle))|Out-Null
 Start-Sleep -Milliseconds 300
 $r=$script:window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $directory ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Core([string]$action,[hashtable]$fields){$request=@{schemaVersion=1;repoRoot=$install;confirm=$true};foreach($name in $fields.Keys){$request[$name]=$fields[$name]};Save ('request-'+$action+'.json') $request;$OutputEncoding=$utf8;$text=@(($request|ConvertTo-Json -Depth 30)|& $hostExe $action '-') -join "`n";$result=$text|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw ($action+': '+$text)};return $result.data}
function Attach{
 $script:app=WaitFor {@(Get-Process -ErrorAction SilentlyContinue|Where-Object {try{$_.Path -ieq $exe}catch{$false}})|Select-Object -First 1} 150 'installed app'
 $script:owned=New-OwnedProcess $script:app
 $script:window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id))} 120 'app window'
 Save 'owned-app.json' $script:owned.Identity
}
function Launch{if(-not @(Get-Process -ErrorAction SilentlyContinue|Where-Object {try{$_.Path -ieq $exe}catch{$false}}).Count){Start-Process $exe|Out-Null};Attach}
function StopApp{if($script:owned){Stop-OwnedValidationApp $script:app $script:owned;$script:owned=$null;$script:app=$null;$script:window=$null}}
function Version{(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1').DisplayVersion}
function UpdateFiles{@(if(Test-Path $updates){Get-ChildItem $updates -File -Recurse|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash $_.FullName).Hash}}})}
function ProcessStarts{@(Get-Event -SourceIdentifier $events -ErrorAction SilentlyContinue|ForEach-Object {$p=$_.SourceEventArgs.NewEvent;if($p.ProcessName -match '(?i)RooIndustries|Optimizer\.(?:Host|SessionHost)|ProcessGovernor|powershell'){@{pid=[int]$p.ProcessID;parentPid=[int]$p.ParentProcessID;image=[string]$p.ProcessName;time=[string]$p.TIME_CREATED}}})}
function Readback{
 $settings=if(Test-Path (Join-Path $data 'settings.json')){Get-Content -Raw (Join-Path $data 'settings.json')|ConvertFrom-Json}else{$null}
 @{installedVersion=Version;runningPid=if($script:app){$script:app.Id}else{$null};runningImage=if($script:app){$script:app.Path}else{$null};runningProductVersion=if($script:app){(Get-Item $script:app.Path).VersionInfo.ProductVersion}else{$null};installedProductVersion=(Get-Item $exe).VersionInfo.ProductVersion;settings=$settings;status=if($script:window -and (ById 'UpdateStatusText')){StatusText}else{$null};texts=if($script:window){@(Texts)}else{@()};files=@(UpdateFiles);processStarts=@(ProcessStarts);helpers=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like ($install+'\*') -or $script:app -and $_.ParentProcessId -eq $script:app.Id}|Select-Object ProcessId,ParentProcessId,ExecutablePath);governor=(Core 'policy-status' @{policyRoot=(Join-Path $data 'process-rules')});governorTasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.'}|Select-Object TaskName,TaskPath,State,@{n='enabled';e={$_.Settings.Enabled}},@{n='userId';e={$_.Principal.UserId}});utc=[DateTime]::UtcNow.ToString('o')}
}
function Preserved{
 $seed=Get-Content -Raw (Join-Path $OutRoot 'seed\preservation.json')|ConvertFrom-Json
 $changed=@($seed.files|Where-Object {-not(Test-Path -LiteralPath $_.path) -or (Get-FileHash -LiteralPath $_.path).Hash -cne $_.sha256})
 if($changed.Count){throw ('Preserved files changed: '+($changed.path -join ', '))}
 $settings=Get-Content -Raw (Join-Path $data 'settings.json')|ConvertFrom-Json
 if($settings.themeId -ne $seed.themeId){throw 'Theme did not survive the upgrade'}
 $before=Get-Content -Raw (Join-Path $OutRoot 'seed\before.json')|ConvertFrom-Json
 $governor=Core 'policy-status' @{policyRoot=(Join-Path $data 'process-rules')}
 if($governor.hostRunning -ne $before.governor.hostRunning -or $governor.error){throw 'Governor running state changed across the upgrade'}
 Save 'preservation.json' @{allFilesMatch=$true;files=$seed.files;themeId=$settings.themeId}
}
try{
 switch($Scenario){
  'seed' {
   Launch;WaitFor {@(Texts) -contains 'Start here'} 120 '0.10 Home'|Out-Null;StopApp
   $fixture=Join-Path $data 'ota-fixture';[IO.Directory]::CreateDirectory($fixture)|Out-Null
   $target=Join-Path $fixture 'ota-rule-target.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $target
   $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
   $rule=@{schemaVersion=1;ruleId=([Guid]::NewGuid().ToString('N'));owner=@{machine=$env:COMPUTERNAME;userSid=$sid};name='OTA preserved rule';enabled=$false;matchMode='path';executablePath=$target;executableHash=$null;controls=@{cpuPriority='Normal'};cpuSelection=$null}
   Save 'saved-rule.json' (Core 'rule-save' @{policyRoot=(Join-Path $data 'process-rules');rule=$rule})
   $settingsPath=Join-Path $data 'settings.json';$settings=Get-Content -Raw $settingsPath|ConvertFrom-Json
   Save 'as-found-settings.json' $settings
   $settings|Add-Member themeId 'roo-industries-blue' -Force;$settings|Add-Member simpleMode '1' -Force
   [IO.File]::WriteAllText($settingsPath,($settings|ConvertTo-Json -Compress),$utf8)
   $files=@(Get-ChildItem (Join-Path $data 'process-rules\rules') -File|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
   if(Test-Path (Join-Path $data 'operations')){$files+=@(Get-ChildItem (Join-Path $data 'operations') -File -Recurse|Where-Object {$_.Name -notlike '*.lock'}|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})}
   Save 'preservation.json' @{files=$files;themeId='roo-industries-blue';ruleId=$rule.ruleId}
   Save 'before.json' (Readback)
  }
  'manual-install' {
   if(-not$InstallerPath){throw 'InstallerPath required'}
   $setup=Start-Process $InstallerPath -ArgumentList ('/SUPPRESSMSGBOXES /NORESTART /LOG="'+(Join-Path $directory 'setup.log')+'"') -PassThru
   $setupOwned=New-OwnedProcess $setup
   $script:setupReceipts.Add($setupOwned);Save 'owned-setup.json' @($script:setupReceipts.Identity)
   $until=[DateTime]::UtcNow.AddMinutes(6)
   $guideCleared=$false
   while(-not$setup.HasExited -and [DateTime]::UtcNow -lt $until){
    foreach($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$setup.Id))){if($child.ProcessId -notin @($script:setupReceipts.Identity.pid)){$receipt=New-OwnedProcess (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue);if($receipt){$script:setupReceipts.Add($receipt);Save 'owned-setup.json' @($script:setupReceipts.Identity)}}}
    $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Window))|Where-Object {$_.Current.ProcessId -in @($script:setupReceipts.Identity.pid)})
    foreach($win in $windows){$script:window=$win
     foreach($name in 'Read the beta tester guide','Open Roo Industries Optimization Suite'){ $box=ByName $name;if($box){try{$toggle=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}}catch{}} }
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
   $script:window=$null;Launch;Settings;Shot 'settings';Preserved
  }
  'cleanup' {Launch;Settings;Save 'final.json' (Readback);StopApp}
  default {
   if(-not$ResumeCopyRecovery){Launch;Settings}
   if($Scenario -in 'ready','scheduled-download'){
    $toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if([string]$toggle.Current.ToggleState -eq 'Off'){$toggle.Toggle()}
   }
   if($Scenario -eq 'manual-download'){
    $toggle=(ById 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}
    $theme=ById 'ThemePicker';$theme.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Activate (WaitFor {ByName 'Blackout Gold'} 15 'gold theme');Start-Sleep 1;Attach;Settings
    if((Get-Content -Raw (Join-Path $data 'settings.json')|ConvertFrom-Json).downloadUpdatesAutomatically -ne '0'){throw 'Theme change overwrote automatic download preference'}
    $theme=ById 'ThemePicker';$theme.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Activate (WaitFor {ByName 'Roo Industries Blue'} 15 'blue theme');Start-Sleep 1;Attach;Settings
   }
   if($Scenario -in @('feed-down','slow-feed','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','manual-download','ready')){Click 'UpdateCheckButton'}
   switch($Scenario){
    'feed-down' {WaitStatus "Couldn't check for updates.*" 40|Out-Null;Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 40 'Home remains usable'|Out-Null;Settings}
    'slow-feed' {Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 5 'Home while feed waits'|Out-Null;Settings;WaitStatus "Couldn't check for updates. The request timed out." 30|Out-Null}
    'malformed-feed' {WaitStatus "Couldn't verify the update.*"|Out-Null;Activate (ByName 'Home');WaitFor {@(Texts) -contains 'Start here'} 5 'Home after malformed feed'|Out-Null;Settings}
    'bad-signature' {WaitStatus "Couldn't verify the update.*signature*"|Out-Null}
    'wrong-product' {WaitStatus "Couldn't verify the update. This release is for another product."|Out-Null}
    'wrong-channel' {WaitStatus "Couldn't verify the update. This release is for another update channel."|Out-Null}
    'same-version' {WaitStatus 'You have the latest version'|Out-Null}
    'older-version' {WaitStatus 'You have the latest version'|Out-Null}
    {$_ -in 'tampered','tampered-size'} {WaitStatus "The download didn't match the signed release, so it was deleted. The app will try again later." 180|Out-Null;if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Rejected installer remains'}}
    'manual-download' {WaitStatus 'Version 0.11.1-beta is available'|Out-Null;if(@(UpdateFiles|Where-Object {$_.path -match '\.exe(?:\.partial)?$'}).Count){throw 'Automatic-off downloaded an installer'};Shot 'available';Click 'UpdateDownloadButton';WaitStatus 'Version 0.11.1-beta is ready to install' 180|Out-Null;Preserved}
    'ready' {WaitStatus 'Version 0.11.1-beta is ready to install' 180|Out-Null;Preserved}
    'scheduled-download' {$started=[DateTime]::UtcNow;WaitStatus 'Version 0.11.1-beta is ready to install' 180|Out-Null;Save 'scheduled.json' @{checkButtonPressed=$false;secondsFromSettings=([DateTime]::UtcNow-$started).TotalSeconds};Preserved}
    'blocked' {Click 'UpdateInstallButton';WaitStatus "Stop your game session and turn off the timer setting first. The update can't install while they run."|Out-Null}
    'cancel' {Click 'UpdateInstallButton';WaitFor {ByName 'Not now'} 60 'confirmation'|Out-Null;Shot 'confirmation';Activate (ByName 'Not now');WaitFor {(ById 'UpdateInstallButton').Current.IsEnabled} 20 'canceled'}
    {$_ -in 'install','failure','copy-failure'} {
     $prior=0
     if(-not$ResumeCopyRecovery){$prior=$script:app.Id;Click 'UpdateInstallButton';WaitFor {ByName 'Install'} 60 'confirmation'|Out-Null;Shot 'confirmation';Activate (ByName 'Install')
      WaitFor {if($script:app.HasExited){return $true};if((StatusText) -like "Couldn't install the update.*"){throw (StatusText)}} 90 'old app exits'|Out-Null}
     if($Scenario -eq 'copy-failure'){
      $script:window=WaitFor {$A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.Name -like '*Setup*Roo Industries*' -and $_.Current.ClassName -eq 'TWizardForm'}|Select-Object -First 1} 180 'interactive recovery setup'
      $setup=Get-Process -Id $script:window.Current.ProcessId;$script:setupReceipts.Add((New-OwnedProcess $setup))
      Save 'missing-executable.json' @{exists=(Test-Path $exe -PathType Leaf);destinationIsDirectory=(Test-Path $exe -PathType Container);installedVersion=Version;setupPid=$script:window.Current.ProcessId;processStarts=@(ProcessStarts)}
      if(Test-Path $exe -PathType Leaf){throw 'Copy-failure fixture did not remove the old executable'}
      Shot 'interactive-recovery'
      $until=[DateTime]::UtcNow.AddMinutes(6);$guideCleared=$false
      while(-not$setup.HasExited -and [DateTime]::UtcNow -lt $until){
       foreach($name in 'Read the beta tester guide','Open Roo Industries Optimization Suite'){$box=ByName $name;if($box){try{$toggle=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$toggle.Current.ToggleState -eq 'On'){$toggle.Toggle()}}catch{}}}
       if(-not$guideCleared -and (ByNameControl 'Finish' $CT::Button)){$list=$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'TNewCheckListBox'));if($list){[IntPtr]$result=[IntPtr]::Zero;$handle=[IntPtr]::new($list.Current.NativeWindowHandle);[RooUpdateUi]::SendMessageTimeout($handle,0x186,[IntPtr]::Zero,[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null;[RooUpdateUi]::SendMessageTimeout($handle,0x100,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null;[RooUpdateUi]::SendMessageTimeout($handle,0x101,[IntPtr]::new(32),[IntPtr]::Zero,3,3000,[ref]$result)|Out-Null;$guideCleared=$true}}
       foreach($name in 'Finish','Install','Next >','Next'){$button=ByNameControl $name $CT::Button;if($button -and $button.Current.IsEnabled){Activate $button;Start-Sleep -Milliseconds 500;break}}
       Start-Sleep -Milliseconds 200
      }
      if(-not$setup.HasExited -or -not(Test-Path $exe -PathType Leaf)){throw 'Interactive recovery did not restore the executable'}
      Save 'interactive-recovery-result.json' @{exitCode=$setup.ExitCode;installedVersion=Version;exists=(Test-Path $exe -PathType Leaf)}
     }
     $script:owned=$null;$script:app=$null;$script:window=$null;if($Scenario -eq 'copy-failure'){Launch}else{Attach};Settings
     if($Scenario -in 'install','copy-failure'){WaitStatus 'Updated to version 0.11.1-beta' 90|Out-Null;if((Version) -ne '0.11.1-beta'){throw 'Installed version did not advance'}}else{WaitStatus "The update to 0.11.1-beta didn't finish. Setup log: *" 90|Out-Null;if((Version) -ne '0.11.0-beta'){throw 'Failure changed installed version'};if((ById 'UpdateInstallButton').Current.Name -ne 'Try again'){throw 'Settings did not offer Try again'};Click 'UpdateCheckButton';WaitStatus "The update to 0.11.1-beta didn't finish. Setup log: *" 90|Out-Null}
     if($script:app.Id -eq $prior){throw 'App did not relaunch'};Preserved
    }
   }
   Shot 'settings-banner'
   if($Scenario -in @('feed-down','slow-feed','malformed-feed','bad-signature','wrong-product','wrong-channel','same-version','older-version','tampered','tampered-size','blocked','cancel','manual-download','ready')){
    if((Version) -ne '0.11.0-beta'){throw 'Refusal/download changed installed version'}
    if(@(ProcessStarts|Where-Object {$_.image -like '*-setup*'}).Count){throw 'Unexpected setup process'}
   }
  }
 }
 Save 'result.json' (Readback)
 'Scenario '+$Scenario+' completed'
}catch{Save 'failure.json' @{error=$_.Exception.ToString();texts=if($script:window){@(Texts)}else{@()};processStarts=@(ProcessStarts)};throw}
finally{Save 'process-starts.json' @(ProcessStarts);Unregister-Event -SourceIdentifier $events -ErrorAction SilentlyContinue;Get-Event -SourceIdentifier $events -ErrorAction SilentlyContinue|Remove-Event;foreach($receipt in @($script:setupReceipts|Select-Object -Last 10)) {Stop-OwnedProcess $receipt};StopApp}
