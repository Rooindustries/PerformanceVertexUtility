param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidateSet('before','after')][string]$Label)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooIndustriesRestoreKeptUi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
}
'@
[RooIndustriesRestoreKeptUi]::SetProcessDPIAware()|Out-Null
$directory=Join-Path $OutRoot $Label
if([IO.Directory]::Exists($directory)){throw 'Evidence directory exists; retained.'}
$frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$app=$null;$receipt=$null;$fixture=$null;$window=$null;$frameCount=0;$clock=[Diagnostics.Stopwatch]::StartNew();$timeline=[Collections.Generic.List[object]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function ById([string]$id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name)}
function Capture([string]$path){$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}}
function Shot([string]$name){Save ($name+'-text.json') (Texts);Capture (Join-Path $directory ($name+'.png'))}
function Frame{$script:frameCount++;Capture (Join-Path $frames ('{0:D4}.png' -f $script:frameCount));$timeline.Add(@{frame=$script:frameCount;ms=$clock.ElapsedMilliseconds})|Out-Null}
function Card{$title=WaitFor {@(All|Where-Object {$_.Current.ControlType -eq $CT::Text -and $_.Current.Name -ceq 'Game priority'})|Select-Object -First 1} 30 'Game priority card';$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($title);@($panel.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name})}
function Read-Fixture($p){$p.Refresh();[ordered]@{priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64()}}
try{
 Assert-NoUnownedAppProcess
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $AppRoot 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe')
 if($exe.Count -ne 1){throw 'Expected exactly one built app in the app root.'}
 $state=Join-Path $AppRoot 'backend\state'
 if([IO.Directory]::Exists($state) -and @(Get-ChildItem -LiteralPath $state -Force).Count){throw 'The app root backend state is not empty; retained.'}
 $image=Join-Path $directory ('Pvu76Kept'+[Guid]::NewGuid().ToString('N').Substring(0,4)+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $image
 $process=Start-Process $image -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$fixture=New-OwnedProcess $process;$process.PriorityClass='Normal'
 $before=Read-Fixture $process
 $affinity=if(($before.affinityMask -band 1) -eq 1 -and $before.affinityMask -ne 1){1}elseif(($before.affinityMask -band 2) -eq 2){2}else{throw 'The fixture needs at least two CPUs.'}
 $name=$process.ProcessName+'.exe'
 Save 'profile.json' ([ordered]@{
  schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='restore-kept-ui';name='Restore keeps another program value';profileKind='process-controls';risk='medium'
  protectedCatalogPath=(Join-Path $AppRoot 'backend\profiles\protected-processes.json')
  foregroundGame=[ordered]@{ruleId='restore-kept-ui';processNames=@($name);priorityClass='AboveNormal';affinityMask=[int64]$affinity;reason='Validate the Game priority restore text.';reasonCodes=@('LIVE_VALIDATION')}
  targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@()
  rollbackPolicy=[ordered]@{supported=$true;scope='process-controls';stateRoot='backend\state';restoreOriginalPriorityClass=$true}
  safety=[ordered]@{confirmedApplyChanges=@('PriorityClass','Affinity');continuousEnforcement=$true;runtimeService=$false}
 })
 $start=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $AppRoot 'backend\scripts\Start-GameTuneSession.ps1') -ProfilePath (Join-Path $directory 'profile.json') -TargetGameProcessName $name -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply
 if($LASTEXITCODE){throw 'Game priority start failed.'}
 $start=($start -join "`n")|ConvertFrom-Json;Save 'start.json' $start
 $applied=Read-Fixture $process
 if($applied.priorityClass -ne 'AboveNormal' -or $applied.affinityMask -ne $affinity -or -not$start.restorable){throw ('Game priority did not apply to the fixture: '+$applied.priorityClass+' '+$applied.affinityMask)}
 $process.PriorityClass='BelowNormal';$changed=Read-Fixture $process
 $app=Start-Process $exe[0].FullName -PassThru;$receipt=New-OwnedProcess $app
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))} 120 'app window'
 $handle=[IntPtr]::new($window.Current.NativeWindowHandle)
 [RooIndustriesRestoreKeptUi]::SetWindowPos($handle,[IntPtr]::new(-1),40,40,1360,960,0x40)|Out-Null
 [RooIndustriesRestoreKeptUi]::SetForegroundWindow($handle)|Out-Null
 if(ById 'UpdateLaterButton'){Activate (ById 'UpdateLaterButton')}
 WaitFor {@(Texts) -contains 'Start here'} 90 'Home'|Out-Null
 Nav 'Games';Activate (WaitFor {ById 'BackgroundTab'} 60 'Background apps tab')
 $restore=WaitFor {$b=Button 'Restore game priority';if($b -and $b.Current.IsEnabled){$b}} 90 'Restore game priority enabled'
 try{$restore.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 Start-Sleep -Milliseconds 800
 $ready=Card;Save 'card-ready.json' $ready;Shot 'ready'
 for($i=0;$i -lt 12;$i++){Frame;Start-Sleep -Milliseconds 60}
 $clicked=$clock.ElapsedMilliseconds;Activate $restore
 $deadline=[DateTime]::UtcNow.AddSeconds(60);$done=$null
 while([DateTime]::UtcNow -lt $deadline){Frame;$card=Card;if($card -contains 'Game priorities restored' -or $card -contains 'Game restore needs attention' -or $card -contains 'Game restore not confirmed'){$done=$clock.ElapsedMilliseconds;break}}
 if(-not$done){throw 'The game restore result did not appear.'}
 $settle=[DateTime]::UtcNow.AddSeconds(3);while([DateTime]::UtcNow -lt $settle){Frame}
 $result=Card;Save 'card-result.json' $result;Shot 'result'
 $after=Read-Fixture $process
 Save 'observed.json' ([ordered]@{label=$Label;fixture=$name;before=$before;applied=$applied;otherProgram=$changed;after=$after;cardReady=$ready;cardResult=$result;clickedMs=$clicked;resultMs=$done;frames=$timeline})
 $detail=($result -join "`n")
 if($after.priorityClass -ne 'BelowNormal'){throw ('Restore overwrote the priority another program set: '+$after.priorityClass)}
 if($after.affinityMask -ne $before.affinityMask){throw ('Restore did not return the affinity it changed: '+$after.affinityMask)}
 if($result -notcontains 'Game priorities restored' -or $detail -notmatch ([regex]::Escape($process.ProcessName)+'(\.exe)? CPU priority \(BelowNormal\)') -or $detail -notmatch 'Left as another program set it'){throw 'The restore result does not name the priority it left.'}
 Save 'done.json' @{passed=$true;label=$Label}
}catch{
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Shot 'failure'}catch{}}
 throw
}finally{
 if($app){Stop-OwnedValidationApp $app $receipt}
 if($fixture){Stop-OwnedProcess $fixture}
}
