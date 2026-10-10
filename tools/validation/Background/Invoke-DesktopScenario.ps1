param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidateSet('priority','games','services','guides','background-ui','recovery-ui','invalid-recovery-ui')][string]$Scenario,[string]$ServiceRunningId='',[string]$ServiceProbe='')
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooBackgroundUi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
}
'@
[RooBackgroundUi]::SetProcessDPIAware()|Out-Null
$directory=Join-Path $OutRoot $Scenario;[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$app=$null;$receipt=$null;$job=[IntPtr]::Zero;$denied=$null;$dacl=$null;$choicesPath=$null;$choicesBytes=$null;$serviceProfile=$null;$profileRecoveryOwned=$null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function ById([string]$id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function ByName([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function ProcessButton([string]$name){$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent((Button 'Review process changes'));while($panel){$buttons=@($panel.FindAll($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button))));if($buttons.Count -eq 1){return $buttons[0]};$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($panel)};throw ('Missing process-card button: '+$name)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Tree{@(All|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled;offscreen=$_.Current.IsOffscreen}})}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};try{$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();return}catch{};$e.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()}
function InvokeId([string]$id){Activate (WaitFor {$e=ById $id;if($e -and $e.Current.IsEnabled){$e}} 90 $id)}
function SetValue([string]$id,[string]$value){(WaitFor {$e=ById $id;if($e -and $e.Current.IsEnabled){$e}} 90 $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($value)}
function Toggle([string]$id){$e=WaitFor {ById $id} 45 $id;$p=$e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$p.Current.ToggleState -ne 'On'){$p.Toggle()}}
function Nav([string]$name){$e=WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name;Activate $e}
function FreshCombo([string]$id,[string]$name){@(All|Where-Object {$_.Current.ControlType -eq $CT::ComboBox -and $(if($id){$_.Current.AutomationId -eq $id}else{$_.Current.Name -eq $name})})|Select-Object -First 1}
function Click($element){$r=$element.Current.BoundingRectangle;if($r.Width -le 0 -or $r.Height -le 0){throw 'UI element has no clickable bounds'};[RooBackgroundUi]::SetCursorPos([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))|Out-Null;[RooBackgroundUi]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[RooBackgroundUi]::mouse_event(4,0,0,0,[UIntPtr]::Zero)}
function Options($combo){$id=$combo.Current.AutomationId;$name=$combo.Current.Name;Save ('dropdown-'+($id -replace '\W','-')+'.json') @{id=$id;name=$name;enabled=$combo.Current.IsEnabled;patterns=@($combo.GetSupportedPatterns()|ForEach-Object {$_.ProgrammaticName})};try{$combo.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};@(WaitFor {$fresh=FreshCombo $id $name;$fresh.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand();$items=@($fresh.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)));if($items.Count){$items}} 90 ('dropdown choices '+$id+' '+$name))}
function Choose($combo,[string]$pattern){$id=$combo.Current.AutomationId;$name=$combo.Current.Name;$items=@(Options $combo);$item=@($items|Where-Object {$_.Current.Name -like $pattern})|Select-Object -First 1;for($page=0;-not$item -and $page -lt 30;$page++){$fresh=FreshCombo $id $name;$scroll=@($fresh.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {try{$_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable}catch{$false}})|Select-Object -First 1;if($scroll){$scroll.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Scroll([Windows.Automation.ScrollAmount]::NoAmount,[Windows.Automation.ScrollAmount]::LargeIncrement)}else{try{($items|Select-Object -Last 1).GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{break}};Start-Sleep -Milliseconds 100;$items=@($fresh.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)));$item=@($items|Where-Object {$_.Current.Name -like $pattern})|Select-Object -First 1};if(-not$item){Save 'missing-choice-tree.json' (Tree);throw ('Choice missing: '+$pattern)};$names=@($items|ForEach-Object {$_.Current.Name});$errorText=$null;try{$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}catch{$errorText=$_.Exception.Message};Start-Sleep -Milliseconds 500;$combo=FreshCombo $id $name;try{$combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()}catch{};Save ('choice-'+($id -replace '\W','-')+'.json') @{pattern=$pattern;choices=$names;selectionCallError=$errorText}}
function ChooseId([string]$id,[string]$pattern){Choose (WaitFor {ById $id} 90 $id) $pattern}
function Shot([string]$name){Save ($name+'-tree.json') (Tree);Save ($name+'-text.json') (Texts);$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $directory ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}}
function Fixture([string]$name){$path=Join-Path $directory ($name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));Save 'owned-fixtures.json' @($owned|ForEach-Object {$_.Identity});return $p}
function Read($p){$p.Refresh();@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p);path=$p.Path}}
function HostCall([string]$action,[hashtable]$fields){$install='C:\Program Files\Roo Industries\Optimization Suite';$fields.schemaVersion=1;$fields.repoRoot=$install;$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'),$action+' -');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;foreach($key in @($start.EnvironmentVariables.Keys)){if($key -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$start.EnvironmentVariables.Remove($key)}};$p=[Diagnostics.Process]::Start($start);$r=New-OwnedProcess $p;try{$p.StandardInput.WriteLine(($fields|ConvertTo-Json -Depth 30 -Compress));$p.StandardInput.Close();$output=$p.StandardOutput.ReadToEndAsync();$errorOutput=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit(180000)){throw 'Host timed out'};if($p.ExitCode -ne 0){throw ($output.Result+' '+$errorOutput.Result)};($output.Result|ConvertFrom-Json).data}finally{Stop-OwnedProcess $r;$p.Dispose()}}
try {
 Assert-NoUnownedAppProcess
 if($Scenario -eq 'priority'){$target=Fixture 'RooFixturePriority';$job=[RooBackgroundOracle]::PinNormal($target);$denied=Fixture 'RooFixtureDenied'}
 if($Scenario -in 'background-ui','recovery-ui','invalid-recovery-ui'){$backgroundFixture=Fixture 'RooFixtureWebHelperUi';$backgroundFixture.PriorityClass='Normal';[RooBackgroundOracle]::SetMemory($backgroundFixture,5)}
 if($Scenario -eq 'recovery-ui'){$closedFixture=Fixture 'RooFixtureUpdaterClosedUi';$closedFixture.PriorityClass='Normal';[RooBackgroundOracle]::SetMemory($closedFixture,5)}
 if($Scenario -eq 'games'){$launcher=Fixture 'RooFixtureLauncher';$gamePath=Join-Path $directory 'RooFixtureGame.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $gamePath}
 $exe='C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
 $app=Start-Process $exe -PassThru;$receipt=New-OwnedProcess $app;Save 'owned-app.json' $receipt.Identity
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))} 120 'app window'
 [RooBackgroundUi]::SetWindowPos([IntPtr]::new($window.Current.NativeWindowHandle),[IntPtr]::new(-1),0,0,0,0,0x43)|Out-Null
 [RooBackgroundUi]::SetForegroundWindow([IntPtr]::new($window.Current.NativeWindowHandle))|Out-Null
 try{$window.SetFocus()}catch{}
 if(ById 'UpdateLaterButton'){InvokeId 'UpdateLaterButton'}
 WaitFor {@(Texts) -contains 'Start here'} 90 'Home'|Out-Null
 switch($Scenario){
  'priority' {
   Nav 'Games';InvokeId 'ProcessesTab';WaitFor {ById 'ProcessPicker'} 90 'process panel'|Out-Null
   ChooseId 'ProcessPicker' ('*RooFixturePriority*PID '+$target.Id);WaitFor {$c=ById 'cpuPriority';$c -and $c.Current.IsEnabled} 60 'priority rows'|Out-Null
   ChooseId 'cpuPriority' 'High';ChooseId 'ioPriority' 'High*'
   Activate (ById 'ProcessCoresExpander');Toggle 'ProcessHardAffinity';SetValue 'ProcessAffinityMask' '0xFFF'
   $before=Read $target;Save 'before.json' $before;InvokeId 'ProcessPreview';WaitFor {(ById 'ProcessApply').Current.IsEnabled} 60 'review';Shot 'review'
   $previewFile=Get-ChildItem (Join-Path (Get-RooIndustriesLocalDataRoot) 'operations') -Filter preview.json -Recurse|Where-Object {$_.Directory.Name -like 'process-*' -and $_.CreationTimeUtc -gt $app.StartTime.ToUniversalTime()}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
   $preview=Get-Content -Raw $previewFile.FullName|ConvertFrom-Json;Save 'verified-review.json' $preview
   if($preview.identity.processId -ne $target.Id -or $preview.desired.cpuPriority -ne 'High' -or $preview.desired.ioPriority -ne 3 -or $preview.desired.affinity.mask -ne '0xFFF'){throw 'Review does not match the owned PID and exact requested controls'}
   InvokeId 'ProcessApply';WaitFor {(ById 'ProcessRestore').Current.IsEnabled} 60 'applied'|Out-Null;$immediate=(ById 'ProcessDetail').Current.Name;Save 'immediate-result-detail.json' $immediate;Shot 'immediate-result';Start-Sleep 10;Shot 'partial-result';$later=(ById 'ProcessDetail').Current.Name;Save 'later-result-detail.json' $later;Save 'apply-journal.json' (Get-Content -Raw (Join-Path $previewFile.DirectoryName 'journal.json')|ConvertFrom-Json);$after=Read $target;Save 'after.json' $after
   Save 'result-display-check.json' @{immediate=$immediate;afterTenSeconds=$later;immediateNamesControls=($immediate -match 'CPU priority:' -and $immediate -match 'I/O priority:' -and $immediate -match 'CPU affinity:');retained=($immediate -ceq $later)}
   if($immediate -cne $later -or $later -notmatch 'CPU priority:.*not changed' -or $later -notmatch 'I/O priority:.*set to' -or $later -notmatch 'CPU affinity:.*set to'){throw 'Per-control result was hidden or misreported'}
   if($after.priorityClass -ne 'Normal' -or $after.ioPriority -ne 3 -or $after.affinityMask -ne 4095){throw 'Apply once did not retain Normal CPU and change I/O + affinity'}
   $target.ProcessorAffinity=[IntPtr]3;Save 'external-affinity.json' (Read $target)
   InvokeId 'ProcessRestore';WaitFor {(ById 'ProcessStatus').Current.Name -match "weren't restored"} 60 'partial restore'|Out-Null;Shot 'restore-conflict';$restored=Read $target;Save 'restored.json' $restored;Save 'restore-detail.json' (ById 'ProcessDetail').Current.Name
   if($restored.affinityMask -ne 3 -or (ById 'ProcessDetail').Current.Name -notmatch 'CPU affinity:.*not restored'){throw 'External affinity was overwritten or its conflict was hidden'}
   foreach($field in 'priorityClass','ioPriority','memoryPriority'){if([string]$restored.$field -cne [string]$before.$field){throw ('Running process Restore did not return '+$field)}}
   $target.ProcessorAffinity=[IntPtr]4095;InvokeId 'ProcessRestore';WaitFor {(ById 'ProcessStatus').Current.Name -eq 'Original controls restored.' -and (ById 'cpuPriority').Current.IsEnabled} 60 'fixture restoration completed'|Out-Null;Save 'restored-after-conflict-cleared.json' (Read $target)
   if($target.ProcessorAffinity.ToInt64() -ne $before.affinityMask){throw 'Fixture affinity was not restored after the conflict was cleared'}
   $restoreDetail=(ById 'ProcessDetail').Current.Name;ChooseId 'cpuPriority' 'Above normal';WaitFor {(ById 'ProcessDetail').Current.Name -cne $restoreDetail} 15 'result invalidated after edit'|Out-Null;$editedDetail=(ById 'ProcessDetail').Current.Name;Save 'result-invalidation.json' @{beforeEdit=$restoreDetail;afterEdit=$editedDetail;control='CPU priority';value='AboveNormal'}
   $dacl=[RooBackgroundOracle]::DenySetInformation($denied)
   InvokeId 'ProcessRefresh';ChooseId 'ProcessPicker' ('*RooFixtureDenied*PID '+$denied.Id);WaitFor {$c=ById 'cpuPriority';$c -and -not$c.Current.IsEnabled} 60 'blocked rows'|Out-Null;Shot 'blocked'
   $blocked=@('cpuPriority','ioPriority','ProcessHardAffinity')|ForEach-Object {$e=ById $_;@{id=$_;enabled=if($e){$e.Current.IsEnabled}else{$null}}};Save 'blocked-controls.json' $blocked
   if(@($blocked|Where-Object {$_.enabled -eq $true}).Count){throw 'A blocked control is editable'}
   if(-not(@(Texts) -match "can't be changed while this app runs")){throw 'Blocked explanation not shown'}
   $scroller=@(All|Where-Object {try{$_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable}catch{$false}})|Select-Object -First 1
   if($scroller){$scroller.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1,100);Start-Sleep -Milliseconds 250;Shot 'blocked-detail'}
  }
  'games' {
   Nav 'Games';InvokeId 'GamesTab';InvokeId 'GameSessionNew';SetValue 'GameSessionExecutable' $gamePath
   ChooseId 'GameSessionLauncher' ('*RooFixtureLauncher*PID '+$launcher.Id)
   $cpu=WaitFor {@(All|Where-Object {$_.Current.ControlType -eq $CT::ComboBox -and $_.Current.Name -eq 'CPU priority'})|Select-Object -First 1} 90 'launch CPU options'
   $io=WaitFor {@(All|Where-Object {$_.Current.ControlType -eq $CT::ComboBox -and $_.Current.Name -eq 'I/O priority'})|Select-Object -First 1} 90 'launch I/O options'
   $cpuNames=@(Options $cpu|ForEach-Object {$_.Current.Name});$cpu.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
   $ioNames=@(Options $io|ForEach-Object {$_.Current.Name});$io.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
   Save 'choices.json' @{cpu=$cpuNames;io=$ioNames};if($cpuNames -contains 'Realtime' -or @($ioNames|Where-Object {$_ -like 'High*'}).Count){throw 'Unsupported launch priorities are offered'}
   Toggle 'GameSessionScope'
   SetValue 'GameSessionExecutable' $launcher.Path;InvokeId 'GameSessionPreview';WaitFor {(ById 'GameSessionDetail').Current.Name -match 'launcher|Launcher'} 60 'own launcher refusal';Shot 'same-launcher'
   SetValue 'GameSessionExecutable' $gamePath;$game=Start-Process $gamePath -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $game))
   InvokeId 'GameSessionPreview';WaitFor {(ById 'GameSessionDetail').Current.Name -match 'Close|close'} 60 'game running refusal';Shot 'game-running'
  }
  'guides' {
   Nav 'Settings';WaitFor {ById 'SimpleModeToggle'} 45 'simple mode'|Out-Null
   if([string](ById 'SimpleModeToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne 'On'){throw 'Expected simple mode enabled'}
   $guides=Get-Content -Raw (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\Assets\Guides\memory-guides.json')|ConvertFrom-Json
   Nav 'Memory';WaitFor {ByName $guides.title} 90 'memory guides'|Out-Null
   $titles=@($guides.guides|ForEach-Object {$_.title})
   $found=@($titles|Where-Object {ByName $_});Save 'guides.json' @{expected=$titles;found=$found};if($titles.Count -ne 7 -or $found.Count -ne 7){throw 'All seven guides are not exposed'}
   Activate (ByName $titles[0]);Start-Sleep 1;Shot 'guide-expanded'
  }
  {$_ -in 'background-ui','recovery-ui'} {
   $recoveryPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'settings\process-profile-recovery.json'
   if(Test-Path $recoveryPath){throw 'An earlier process restore is pending; preserve it before the fixture'}
   $before=Read $backgroundFixture;Save 'before.json' $before
   Nav 'Games';InvokeId 'BackgroundTab';$combo=WaitFor {ById 'BackgroundPriorityPreset'} 90 'preset chooser';Shot 'lower'
   $names=@(Options $combo|ForEach-Object {$_.Current.Name});Save 'presets.json' $names
   Choose $combo 'Lower background apps'
   Activate (Button 'Review process changes');WaitFor {@(Texts) -contains 'Plan ready'} 90 'lower review'|Out-Null;Shot 'lower-review'
   Activate (Button 'Apply');WaitFor {Test-Path $recoveryPath} 90 'lower recovery saved'|Out-Null;$profileRecoveryOwned=Get-Content -Raw $recoveryPath|ConvertFrom-Json
   WaitFor {-not(Button 'Apply').Current.IsEnabled -and @(Texts) -contains 'Restore the last change first'} 60 'pending Apply disabled'|Out-Null
   Save 'lower-after.json' (Read $backgroundFixture);Shot 'lower-pending'
   if($Scenario -eq 'recovery-ui'){
    $closedBefore=Read $closedFixture;Save 'closed-after-apply.json' $closedBefore
    if($closedBefore.priorityClass -ne 'BelowNormal' -or $closedBefore.memoryPriority -ne 2){throw 'Closed fixture was not affected by Lower Apply'}
    Stop-OwnedProcess ($owned|Where-Object {$_.Identity.pid -eq $closedFixture.Id}|Select-Object -First 1)
    Activate (WaitFor {$button=ProcessButton 'Restore';if($button.Current.IsEnabled){$button}} 45 'Restore enabled')
    WaitFor {-not(Test-Path $recoveryPath) -and (Button 'Apply').Current.IsEnabled} 90 'closed instance releases UI slot'|Out-Null
    $restored=Read $backgroundFixture;Save 'live-restored.json' $restored
    foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$before.$field -cne [string]$restored.$field){throw ('UI live restore differs: '+$field)}}
    $text=@(Texts);if(-not($text -match 'Already closed or restarted:.*RooFixtureUpdaterClosedUi')){throw 'Restore did not name the closed app'}
    Save 'apply-available.json' @{applyEnabled=(Button 'Apply').Current.IsEnabled;pointerExists=(Test-Path $recoveryPath);closedPid=$closedFixture.Id;closedExited=$closedFixture.HasExited;text=$text}
    Shot 'closed-instance-restored';break
   }
   Choose (ById 'BackgroundPriorityPreset') '*E-cores*';WaitFor {-not(Button 'Apply').Current.IsEnabled} 20 'placement Apply remains disabled'|Out-Null;Shot 'placement-pending'
   if($ServiceProbe){
    & (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe') ([IO.Path]::ChangeExtension($ServiceProbe,'.dll')) --review2-restore-pending (Join-Path $directory 'service-probe') (Split-Path $recoveryPath -Parent) *> (Join-Path $directory 'service-probe.log')
    if($LASTEXITCODE){throw 'Review2 service probe failed'}
   }
   [RooBackgroundUi]::SetForegroundWindow([IntPtr]::new($window.Current.NativeWindowHandle))|Out-Null
   $restore=WaitFor {$button=ProcessButton 'Restore';if($button.Current.IsEnabled){$button}} 45 'lower Restore enabled'
   Save 'restore-target.json' @{root=@{id=(Button 'Restore').GetRuntimeId();bounds=[string](Button 'Restore').Current.BoundingRectangle;focusable=(Button 'Restore').Current.IsKeyboardFocusable};card=@{id=$restore.GetRuntimeId();bounds=[string]$restore.Current.BoundingRectangle;focusable=$restore.Current.IsKeyboardFocusable}}
   Activate $restore
   WaitFor {-not(Test-Path $recoveryPath) -and (Button 'Apply').Current.IsEnabled} 90 'lower restored'|Out-Null
   $restored=Read $backgroundFixture;Save 'lower-restored.json' $restored;foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$before.$field -cne [string]$restored.$field){throw ('UI lower restore differs: '+$field)}}
   Activate (Button 'Review process changes');WaitFor {@(Texts) -contains 'Plan ready'} 90 'placement review'|Out-Null;Shot 'placement-review'
   Activate (Button 'Apply');WaitFor {Test-Path $recoveryPath} 90 'placement recovery saved'|Out-Null;$profileRecoveryOwned=Get-Content -Raw $recoveryPath|ConvertFrom-Json
   WaitFor {-not(Button 'Apply').Current.IsEnabled -and @(Texts) -contains 'Restore the last change first'} 60 'placement pending'|Out-Null;Shot 'placement-applied'
   Save 'placement-after.json' (Read $backgroundFixture)
   Activate (WaitFor {$button=ProcessButton 'Restore';if($button.Current.IsEnabled){$button}} 45 'placement Restore enabled')
   WaitFor {-not(Test-Path $recoveryPath) -and (Button 'Apply').Current.IsEnabled} 90 'placement restored'|Out-Null
   $restored=Read $backgroundFixture;Save 'placement-restored.json' $restored;foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$before.$field -cne [string]$restored.$field){throw ('UI placement restore differs: '+$field)}}
   Shot 'restored'
  }
  'invalid-recovery-ui' {
   $recoveryPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'settings\process-profile-recovery.json'
   if(Test-Path $recoveryPath){throw 'An earlier process restore is pending; preserve it before the fixture'}
   [IO.File]::WriteAllText($recoveryPath,'{truncated recovery')
   $before=(Get-FileHash $recoveryPath).Hash
   $prior=@(Get-ChildItem (Split-Path $recoveryPath -Parent) -Filter 'process-profile-recovery.json.invalid-*'|ForEach-Object FullName)
   Nav 'Games';InvokeId 'BackgroundTab'
   WaitFor {-not(Test-Path $recoveryPath) -and (Button 'Apply').Current.IsEnabled} 90 'invalid pointer releases UI Apply'|Out-Null
   $archive=@(Get-ChildItem (Split-Path $recoveryPath -Parent) -Filter 'process-profile-recovery.json.invalid-*'|Where-Object {$prior -notcontains $_.FullName})
   if($archive.Count -ne 1 -or (Get-FileHash $archive[0].FullName).Hash -cne $before){throw 'Invalid pointer archive differs from original bytes'}
   Save 'apply-available.json' @{applyEnabled=(Button 'Apply').Current.IsEnabled;pointerExists=(Test-Path $recoveryPath);archive=$archive[0].FullName;sha256=$before;bytesPreserved=$true}
   Shot 'invalid-pointer-archived'
  }
  'services' {
   if(-not$ServiceRunningId){$ServiceRunningId='windows.4e3841a2d61ce3f9'}
   $choicesPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'settings\windows-choices.json';if(Test-Path $choicesPath){$choicesBytes=[IO.File]::ReadAllBytes($choicesPath)}
   $serviceBefore=@(Get-CimInstance Win32_Service -Filter "Name LIKE 'PrintWorkflowUserSvc%'"|Select-Object Name,State,StartMode,ProcessId);Save 'service-before.json' $serviceBefore
   Nav 'Windows tweaks';WaitFor {(ById 'WindowsTweaksRefresh').Current.IsEnabled} 180 'Windows settings loaded'|Out-Null
   $advanced=ByName 'Show advanced options';$advanced.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
   SetValue 'WindowsTweaksSearch' 'PrintWorkflow';WaitFor {ById ($ServiceRunningId+'.select')} 45 'Print Workflow rows'|Out-Null;Shot 'service-availability'
   if(-not(@(Texts) -match "Windows doesn't let administrators change the startup.*printworkflowusersvc")){throw 'Startup refusal reason is missing'}
   $inspection=HostCall 'tweak-status' @{};Save 'service-status.json' @($inspection.settings|Where-Object {$_.id -in @($ServiceRunningId,'windows.b356c3123766a188')})
   $running=@($inspection.settings|Where-Object id -eq $ServiceRunningId)|Select-Object -First 1;if(-not$running.supported -or $running.error){throw 'Running-state read is unavailable'}
   $serviceProfile='roo20-service-fixture-'+[Guid]::NewGuid().ToString('N');$operation=Join-Path (Join-Path (Get-RooIndustriesLocalDataRoot) 'operations') $serviceProfile;[IO.Directory]::CreateDirectory($operation)|Out-Null;$preview=Join-Path $operation 'preview.json'
   Save 'service-host-preview.json' (HostCall 'tweak-preview' @{profileId=$serviceProfile;selections=@(@{settingId=$ServiceRunningId;optionId='choice-01c43a1bb3484ba2'});outputPath=$preview})
   Save 'service-host-apply.json' (HostCall 'tweak-apply' @{previewPath=$preview;reviewHash=(Get-FileHash $preview).Hash;confirm=$true})
   InvokeId 'WindowsTweaksRefresh';WaitFor {(ById 'WindowsTweaksRefresh').Current.IsEnabled} 180 'temporary service profile loaded'|Out-Null;Activate (ById 'WindowsTweaksProfileTools');ChooseId 'WindowsTweaksProfiles' ('*'+$serviceProfile+'*')
   InvokeId 'WindowsTweaksPreview';WaitFor {(ById 'WindowsTweaksApproval').Current.IsEnabled} 60 'review'|Out-Null;Shot 'service-review'
   Toggle 'WindowsTweaksApproval';InvokeId 'WindowsTweaksApply';WaitFor {@(Texts) -contains 'Profile saved' -or @(Texts) -contains 'Windows settings saved'} 180 'service apply'|Out-Null;Shot 'service-result'
   InvokeId 'WindowsTweaksRestore';WaitFor {(ById 'WindowsTweaksApproval').Current.IsEnabled} 60 'own profile restore review'|Out-Null;Toggle 'WindowsTweaksApproval';InvokeId 'WindowsTweaksApply';WaitFor {(ById 'WindowsTweaksRefresh').Current.IsEnabled} 180 'service restored'|Out-Null
   Save 'service-after.json' @(Get-CimInstance Win32_Service -Filter "Name LIKE 'PrintWorkflowUserSvc%'"|Select-Object Name,State,StartMode,ProcessId)
  }
 }
 Save 'done.json' @{status='passed';scenario=$Scenario;machine=$env:COMPUTERNAME;version=(Get-Item $exe).VersionInfo.ProductVersion}
} catch {
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Shot 'failure'}catch{}}
 throw
} finally {
 if($dacl -and $denied){[RooBackgroundOracle]::RestoreDacl($denied,$dacl)}
 if($app){Stop-OwnedValidationApp $app $receipt}
 if($profileRecoveryOwned -and (Test-Path $recoveryPath)){
  $current=Get-Content -Raw $recoveryPath|ConvertFrom-Json
  if($current.id -eq $profileRecoveryOwned.id){
   $restoration=(& 'C:\Program Files\Roo Industries\Optimization Suite\backend\scripts\Restore-ProcessProfileBackup.ps1' -BackupPath $current.path -ConfirmApply)|ConvertFrom-Json
   Save 'failure-cleanup-restore.json' $restoration
   if(-not$restoration.errors.Count){[IO.File]::Delete($recoveryPath)}
  }
 }

 if($serviceProfile){$recovery=HostCall 'tweak-recovery' @{};if(@($recovery.state.profiles|Where-Object id -eq $serviceProfile).Count){$path=Join-Path (Join-Path (Get-RooIndustriesLocalDataRoot) 'operations') ('service-validation-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($path)|Out-Null;$preview=Join-Path $path 'preview.json';HostCall 'tweak-preview' @{profileId=$serviceProfile;selections=@();outputPath=$preview}|Out-Null;Save 'service-cleanup-restore.json' (HostCall 'tweak-restore' @{previewPath=$preview;reviewHash=(Get-FileHash $preview).Hash;confirm=$true;acceptEarlierVersion=$true})}}
 if($choicesPath){if($choicesBytes){[IO.File]::WriteAllBytes($choicesPath,$choicesBytes)}elseif(Test-Path $choicesPath){Remove-Item -LiteralPath $choicesPath}}
 foreach($r in $owned){Stop-OwnedProcess $r}
 if($Scenario -eq 'priority' -and $previewFile){Save 'cleanup-journal.json' (HostCall 'process-restore' @{journalPath=(Join-Path $previewFile.DirectoryName 'journal.json');confirm=$true})}
 if($job -ne [IntPtr]::Zero){[RooBackgroundOracle]::CloseHandle($job)|Out-Null}
 Save 'cleanup.json' @{appStopped=if($app){$app.HasExited}else{$true};fixtures=@($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})}
}
