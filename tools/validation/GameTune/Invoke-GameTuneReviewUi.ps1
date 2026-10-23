param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$AppExe)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooIndustriesGameTuneUi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
}
'@
[RooIndustriesGameTuneUi]::SetProcessDPIAware()|Out-Null
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$profilePath=Join-Path $Source 'backend\profiles\game-session.profile.json'
$profileBytes=[IO.File]::ReadAllBytes($profilePath)
$reviewPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'settings\game-tune-review.json'
$reviewExisted=Test-Path -LiteralPath $reviewPath
$reviewBytes=if($reviewExisted){[IO.File]::ReadAllBytes($reviewPath)}else{$null}
$stateRoot=Join-Path $Source 'backend\state'
$frames=Join-Path $OutRoot 'frames';$stopFile=Join-Path $OutRoot 'frames.stop'
$owned=[Collections.Generic.List[object]]::new();$app=$null;$receipt=$null;$recorder=$null;$window=$null
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot $name),($value|ConvertTo-Json -Depth 20),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name)}
function Card{$texts=@(Texts);$i=[Array]::IndexOf($texts,'Game priority');if($i -lt 0 -or $i+2 -ge $texts.Count){return $null};[pscustomobject]@{status=$texts[$i+1];detail=$texts[$i+2];start=(Button 'Start game priority').Current.IsEnabled}}
function Shot([string]$name){$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $OutRoot ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()};Save ($name+'-card.json') (Card)}
function Probe([string]$folder){$directory=Join-Path $OutRoot $folder;[IO.Directory]::CreateDirectory($directory)|Out-Null;$exe=Join-Path $directory 'Overwatch.exe';if(-not(Test-Path $exe)){Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $exe};$command="Add-Type -AssemblyName System.Windows.Forms;`$w=New-Object Windows.Forms.Form;`$w.Text='Disposable game $folder';`$w.Width=400;`$w.Height=200;`$w.ShowDialog()|Out-Null";$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command));$p=Start-Process $exe -ArgumentList '-NoProfile','-EncodedCommand',$encoded -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));WaitFor {$p.Refresh();$p.MainWindowHandle -ne [IntPtr]::Zero} 30 'probe window'|Out-Null;$p.PriorityClass='Normal';return $p}
function Read($p){$p.Refresh();[pscustomobject]@{pid=$p.Id;path=$p.Path;priorityClass=[string]$p.PriorityClass}}
try {
 Assert-NoUnownedAppProcess
 if(@(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue).Count){throw 'The staged backend state is not empty; refusing to share it'}
 if(@(Get-Process Overwatch -ErrorAction SilentlyContinue).Count){throw 'A process named Overwatch is already running; refusing to share the fixture name'}
 $profile=[Text.Encoding]::UTF8.GetString($profileBytes).TrimStart([char]0xfeff)|ConvertFrom-Json
 $profile.foregroundGame.processNames=@('Overwatch.exe');$profile.rules=@();$profile.safeCandidates=@()
 [IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 20),$utf8)
 $a=Probe 'probe-a'
 $app=Start-Process $AppExe -PassThru;$receipt=New-OwnedProcess $app;Save 'owned-app.json' $receipt.Identity
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))} 120 'app window'
 $handle=[IntPtr]::new($window.Current.NativeWindowHandle)
 [RooIndustriesGameTuneUi]::SetWindowPos($handle,[IntPtr]::new(-1),40,40,1360,900,0x40)|Out-Null
 [RooIndustriesGameTuneUi]::SetForegroundWindow($handle)|Out-Null
 $later=$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'UpdateLaterButton'));if($later){Activate $later}
 WaitFor {@(Texts) -contains 'Start here'} 120 'Home'|Out-Null
 Nav 'Games';Activate (WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'BackgroundTab'))} 60 'Background apps tab')
 $review=WaitFor {$e=Button 'Review game priority';if($e -and $e.Current.IsEnabled){$e}} 120 'Review enabled'
 try{$review.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 WaitFor {$c=Card;$c -and $c.status -notlike 'Checking*'} 60 'game card settled'|Out-Null
 Start-Sleep -Seconds 2
 $r=$window.Current.BoundingRectangle
 [IO.Directory]::CreateDirectory($frames)|Out-Null
 $recorder=[powershell]::Create()
 [void]$recorder.AddScript({param($x,$y,$w,$h,$dir,$stop)Add-Type -AssemblyName System.Drawing;$i=0;while(-not(Test-Path $stop) -and $i -lt 1200){$b=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen($x,$y,0,0,$b.Size);$b.Save((Join-Path $dir ('frame-{0:D5}.jpg' -f $i)),[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$g.Dispose();$b.Dispose()};$i++;Start-Sleep -Milliseconds 70}}).AddArgument([int]$r.X).AddArgument([int]$r.Y).AddArgument([int]$r.Width).AddArgument([int]$r.Height).AddArgument($frames).AddArgument($stopFile)
 $recording=$recorder.BeginInvoke()
 Start-Sleep -Seconds 1
 Shot '01-before-review'
 $beforeReview=Card
 Activate $review
 $reviewed=WaitFor {$c=Card;if($c -and $c.status -in 'Game priorities checked','Game priority check not confirmed'){$c}} 90 'review result'
 Start-Sleep -Seconds 1
 Shot '02-reviewed'
 $aAtReview=Read $a
 Stop-OwnedProcess ($owned|Where-Object {$_.Identity.pid -eq $a.Id}|Select-Object -First 1)
 $b=Probe 'probe-b'
 [RooIndustriesGameTuneUi]::SetForegroundWindow($b.MainWindowHandle)|Out-Null
 Start-Sleep -Seconds 1
 [RooIndustriesGameTuneUi]::SetForegroundWindow($handle)|Out-Null
 Activate (WaitFor {$e=Button 'Start game priority';if($e -and $e.Current.IsEnabled){$e}} 30 'Start enabled')
 $started=WaitFor {$c=Card;if($c -and $c.status -notin $reviewed.status,'Starting game priorities' -and (Button 'Review game priority').Current.IsEnabled){$c}} 120 'Start result'
 Start-Sleep -Seconds 8
 Shot '03-after-start'
 $after=Card;$bAfter=Read $b
 Start-Sleep -Seconds 2
 [IO.File]::WriteAllText($stopFile,'stop');[void]$recorder.EndInvoke($recording)
 $restored=$null
 if($bAfter.priorityClass -ne 'Normal'){
  Activate (WaitFor {$e=Button 'Restore game priority';if($e -and $e.Current.IsEnabled){$e}} 30 'Restore enabled')
  WaitFor {$c=Card;$c -and $c.status -in 'Game priorities restored','Game restore needs attention','Game restore not confirmed'} 90 'restore result'|Out-Null
  Start-Sleep -Seconds 2;Shot '04-restored';$restored=Read $b
 }
 $bound=$bAfter.priorityClass -eq 'Normal' -and $after.status -eq 'Not started' -and $after.detail -like 'Overwatch.exe closed or restarted after you reviewed it*'
 Save 'result.json' @{machine=$env:COMPUTERNAME;startEnabledBeforeReview=$beforeReview.start;reviewed=$reviewed;gameAAtReview=$aAtReview;startResult=$started;afterReload=$after;gameBAfterStart=$bAfter;gameBAfterRestore=$restored;bound=$bound;frames=@(Get-ChildItem $frames -Filter '*.jpg').Count}
 if(-not$bound){throw ('Start did not stay bound to the reviewed game: B '+$bAfter.priorityClass+', status '+$after.status)}
} catch {
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Shot 'failure'}catch{}}
 throw
} finally {
 if($recorder){if(-not(Test-Path $stopFile)){[IO.File]::WriteAllText($stopFile,'stop')};try{[void]$recorder.EndInvoke($recording)}catch{};$recorder.Dispose()}
 if($app){Stop-OwnedValidationApp $app $receipt}
 foreach($o in $owned){Stop-OwnedProcess $o}
 [IO.File]::WriteAllBytes($profilePath,$profileBytes)
 if($reviewExisted){[IO.File]::WriteAllBytes($reviewPath,$reviewBytes)}elseif(Test-Path -LiteralPath $reviewPath){Remove-Item -LiteralPath $reviewPath}
 if($app -and (Test-Path -LiteralPath (Join-Path $stateRoot 'game-tune-sessions'))){Remove-Item -LiteralPath (Join-Path $stateRoot 'game-tune-sessions') -Recurse -Force}
 Save 'cleanup.json' @{appStopped=if($app){$app.HasExited}else{$true};probesExited=@($owned|ForEach-Object {$_.process.HasExited});profileRestored=((Get-FileHash $profilePath).Hash -eq [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($profileBytes)).Replace('-',''));reviewFileRemoved=($reviewExisted -or -not(Test-Path -LiteralPath $reviewPath))}
}
