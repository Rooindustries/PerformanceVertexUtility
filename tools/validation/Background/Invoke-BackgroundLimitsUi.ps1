param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidateSet('before','after')][string]$Label,[string]$DotNetPath='')
$ErrorActionPreference='Stop'
if($DotNetPath){
 if(-not[IO.File]::Exists($DotNetPath)){throw 'The requested runtime host does not exist.'}
 $env:DOTNET_ROOT=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DotNetPath))
 $env:DOTNET_ROOT_X64=$env:DOTNET_ROOT
}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooIndustriesBackgroundLimitsUi {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
}
'@
[RooIndustriesBackgroundLimitsUi]::SetProcessDPIAware()|Out-Null
$directory=Join-Path $OutRoot $Label
if([IO.Directory]::Exists($directory)){throw 'Evidence directory exists; retained.'}
$frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$app=$null;$receipt=$null;$fixtures=@{};$processes=[ordered]@{};$stem=$null;$window=$null;$profilePath=$null;$profileBytes=$null;$frameCount=0;$clock=[Diagnostics.Stopwatch]::StartNew();$timeline=[Collections.Generic.List[object]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function ById([string]$id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name)}
function Capture([string]$path){
 $h=[IntPtr]::new($window.Current.NativeWindowHandle);$rect=New-Object RooIndustriesBackgroundLimitsUi+Rect;if(-not[RooIndustriesBackgroundLimitsUi]::GetWindowRect($h,[ref]$rect)){throw 'The app window could not be measured.'}
 $frame=New-Object RooIndustriesBackgroundLimitsUi+Rect;if([RooIndustriesBackgroundLimitsUi]::DwmGetWindowAttribute($h,9,[ref]$frame,16) -ne 0){$frame=$rect}
 $b=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top);$g=[Drawing.Graphics]::FromImage($b);$dc=$g.GetHdc()
 try{if(-not[RooIndustriesBackgroundLimitsUi]::PrintWindow($h,$dc,2)){throw 'The app window could not be drawn for a screenshot.'}}finally{$g.ReleaseHdc($dc);$g.Dispose()}
 $area=[Drawing.Rectangle]::Intersect([Drawing.Rectangle]::new($frame.Left-$rect.Left,$frame.Top-$rect.Top,$frame.Right-$frame.Left,$frame.Bottom-$frame.Top),[Drawing.Rectangle]::new(0,0,$b.Width,$b.Height))
 $c=$b.Clone($area,$b.PixelFormat);try{$c.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$c.Dispose();$b.Dispose()}
}
function Shot([string]$name){Save ($name+'-text.json') (Card);Capture (Join-Path $directory ($name+'.png'))}
function Frame{$path=Join-Path $frames ('{0:D4}.png' -f ($script:frameCount+1));try{Capture $path}catch{return};$script:frameCount++;$timeline.Add(@{frame=$script:frameCount;ms=$clock.ElapsedMilliseconds})|Out-Null}
function Card{WaitFor {$texts=@(Texts);$index=[Array]::IndexOf($texts,'Background limits');if($index -ge 0 -and $texts.Count -ge $index+3){,@($texts[$index+1],$texts[$index+2])}} 15 'Background limits card'}
function Idle{(Card)[0] -cnotin @('Watching background load','Restoring background limits','Running now')}
function Start-Fixture([string]$name){$p=Start-Process (Join-Path $directory ($stem+$name+'.exe')) -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$script:fixtures[$name]=New-OwnedProcess $p;$script:processes[$name]=$p;$p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5)}
function Read-Fixture([string]$name){$p=$processes[$name];$p.Refresh();[ordered]@{priorityClass=[string]$p.PriorityClass;ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}}
function Test-Original($value){$value.priorityClass -eq 'Normal' -and $value.ioPriority -eq 2 -and $value.memoryPriority -eq 5}
function Test-Lowered($value){$value.priorityClass -eq 'BelowNormal' -and $value.ioPriority -ne 2 -and $value.memoryPriority -ne 5}
function Run-Button([string]$name,[string]$shot){
 $button=WaitFor {$b=Button $name;if($b -and $b.Current.IsEnabled){$b}} 60 ($name+' enabled')
 for($i=0;$i -lt 8;$i++){Frame;Start-Sleep -Milliseconds 60}
 $clicked=$clock.ElapsedMilliseconds;Activate $button
 $busy=[DateTime]::UtcNow.AddSeconds(5);while([DateTime]::UtcNow -lt $busy -and (Idle)){Frame}
 if($shot){Shot $shot}
 $deadline=[DateTime]::UtcNow.AddSeconds(90);$done=$null
 while([DateTime]::UtcNow -lt $deadline){Frame;if(Idle){$done=$clock.ElapsedMilliseconds;break}}
 if(-not$done){throw ('The '+$name+' result did not appear.')}
 $settle=[DateTime]::UtcNow.AddSeconds(2);while([DateTime]::UtcNow -lt $settle){Frame}
 [ordered]@{clickedMs=$clicked;resultMs=$done}
}
function Restore-Enabled{(WaitFor {$b=Button 'Restore background limits';if($b){@{enabled=[bool]$b.Current.IsEnabled}}} 15 'Restore background limits').enabled}
try{
 Assert-NoUnownedAppProcess
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $AppRoot 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe')
 if($exe.Count -ne 1){throw 'Expected exactly one built app in the app root.'}
 $state=Join-Path $AppRoot 'backend\state'
 if([IO.Directory]::Exists($state) -and @(Get-ChildItem -LiteralPath $state -Force).Count){throw 'The app root backend state is not empty; retained.'}
 $stem='Pvu676Limits'+[Guid]::NewGuid().ToString('N').Substring(0,4)
 foreach($name in 'A','B','C'){$image=Join-Path $directory ($stem+$name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $image}
 Start-Fixture 'A'
 $original=Read-Fixture 'A'
 $profilePath=Join-Path $AppRoot 'backend\profiles\probalance-governor.profile.json';$profileBytes=[IO.File]::ReadAllBytes($profilePath)
 $profile=[Text.Encoding]::UTF8.GetString($profileBytes).TrimStart([char]0xfeff)|ConvertFrom-Json
 $profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='background-limits-ui';enabled=$true;match=@{processNames=@('A','B','C'|ForEach-Object {$stem+$_+'.exe'})}})
 $profile.governor.thresholds.totalCpuPressureThresholdPercent=0;$profile.governor.thresholds.perProcessCpuThresholdPercent=0
 $profile.governor.thresholds.minimumRestraintSeconds=600
 Save 'profile.json' $profile;[IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 40),$utf8)
 $app=Start-Process $exe[0].FullName -PassThru;$receipt=New-OwnedProcess $app
 $window=WaitFor {
  $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id)))
  foreach($dialog in $windows|Where-Object {$_.Current.ClassName -eq '#32770'}){
   $message=$dialog.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'The earlier data folder was gone, so the app started fresh. Its saved rules and undo history are no longer available.'))
   if($message){
    Save 'as-found-missing-data-notice.json' @{message=$message.Current.Name}
    $ok=$dialog.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'OK'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))
    Activate $ok
   }
  }
  @($windows|Where-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings'))})|Select-Object -First 1
 } 120 'app window'
 $handle=[IntPtr]::new($window.Current.NativeWindowHandle)
 [RooIndustriesBackgroundLimitsUi]::SetWindowPos($handle,[IntPtr]::new(-1),40,40,1360,960,0x40)|Out-Null
 [RooIndustriesBackgroundLimitsUi]::SetForegroundWindow($handle)|Out-Null
 if(ById 'UpdateLaterButton'){Activate (ById 'UpdateLaterButton')}
 WaitFor {@(Texts) -contains 'Start here'} 90 'Home'|Out-Null
 Nav 'Games';Activate (WaitFor {ById 'BackgroundTab'} 60 'Background apps tab')
 $start=WaitFor {$b=Button 'Start background limits';if($b -and $b.Current.IsEnabled){$b}} 90 'Start background limits enabled'
 try{$start.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 Start-Sleep -Milliseconds 800;Shot 'ready'
 $first=Run-Button 'Start background limits' 'first-running';Shot 'first-result';$firstCard=Card;$lowered=Read-Fixture 'A';$firstRestore=Restore-Enabled
 if(-not(Test-Lowered $lowered) -or -not$firstRestore){throw ('The first Start did not leave the fixture lowered with Restore: '+($lowered|ConvertTo-Json -Compress)+' restore '+$firstRestore)}
 Start-Fixture 'B';Start-Fixture 'C'
 $second=Run-Button 'Start background limits' $null;Shot 'second-result';$afterSecond=[ordered]@{A=Read-Fixture 'A';B=Read-Fixture 'B';C=Read-Fixture 'C'};$secondRestore=Restore-Enabled;$secondCard=Card
 # Another program raises one app the second run lowered; Restore must keep that value and say so.
 $processes['C'].PriorityClass='AboveNormal';$changedByOther=Read-Fixture 'C'
 $restored=$null;$third=$null;$restoreCard=$null
 if($secondRestore){$third=Run-Button 'Restore background limits' $null;Shot 'restore-result';$restored=[ordered]@{A=Read-Fixture 'A';B=Read-Fixture 'B';C=Read-Fixture 'C'};$restoreCard=Card}
 Save 'observed.json' ([ordered]@{label=$Label;fixtures=@($processes.Values|ForEach-Object {$_.ProcessName+'.exe'});original=$original;firstStart=$first;lowered=$lowered;restoreAfterFirst=$firstRestore;secondStart=$second;afterSecond=$afterSecond;restoreAfterSecond=$secondRestore;secondCard=$secondCard;changedByOther=$changedByOther;restore=$third;restored=$restored;restoreCard=$restoreCard;frames=$timeline})
 if(-not(Test-Lowered $afterSecond.A)){throw ('The second Start changed the earlier lowered fixture: '+($afterSecond.A|ConvertTo-Json -Compress))}
 if(-not(Test-Lowered $afterSecond.B) -or -not(Test-Lowered $afterSecond.C)){throw ('The second Start did not lower the new fixtures: '+($afterSecond|ConvertTo-Json -Compress))}
 if(-not$secondRestore){throw 'Restore disappeared after the second Start while the fixture stayed lowered.'}
 if(($secondCard -join "`n") -match 'Another Background limits run is still going'){throw 'The second Start was turned away instead of running again.'}
 foreach($card in @($firstCard,$secondCard)){
  $repeated=@(@(($card[1]) -split "`n")|Where-Object {$_ -match '^\S+\.exe: ' -and -not $_.Contains([string][char]0x2192)}|ForEach-Object {($_ -split ': ',2)[0]}|Group-Object|Where-Object Count -gt 1)
  if($repeated.Count){throw ('The card lists a skipped app more than once: '+(@($repeated|ForEach-Object Name) -join ', '))}
 }
 if(-not(Test-Original $restored.A) -or -not(Test-Original $restored.B) -or $restoreCard -notcontains 'Background limits restored'){throw ('Restore did not put both runs'' fixtures back exactly: '+($restored|ConvertTo-Json -Compress))}
 if($restored.C.priorityClass -ne 'AboveNormal' -or $restored.C.ioPriority -ne 2 -or $restored.C.memoryPriority -ne 5){throw ('Restore did not keep the value another program set and restore the rest: '+($restored.C|ConvertTo-Json -Compress))}
 if(($restoreCard[1]) -notmatch ('Left as another program set it: '+[regex]::Escape($processes['C'].ProcessName)+'(\.exe)? CPU priority \(AboveNormal\)')){throw ('The card does not name the value Restore kept: '+$restoreCard[1])}
 Save 'done.json' @{passed=$true;label=$Label}
}catch{
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Capture (Join-Path $directory 'failure.png')}catch{}}
 throw
}finally{
 try{if($app){Stop-OwnedValidationApp $app $receipt}}
 finally{try{$stopError=$null;foreach($owned in @($fixtures.Values)){try{Stop-OwnedProcess $owned}catch{if(-not$stopError){$stopError=$_}}};if($stopError){throw $stopError}}finally{if($profileBytes){[IO.File]::WriteAllBytes($profilePath,$profileBytes)}}}
}
