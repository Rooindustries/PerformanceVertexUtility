param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidateSet('before','after')][string]$Label,[string]$DotNetPath='',[ValidateSet('kept','saved-change')][string]$Scenario='kept')
$ErrorActionPreference='Stop'
if($DotNetPath){
 if(-not[IO.File]::Exists($DotNetPath)){throw 'The requested runtime host does not exist.'}
 $env:DOTNET_ROOT=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DotNetPath))
 $env:DOTNET_ROOT_X64=$env:DOTNET_ROOT
}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooIndustriesRestoreKeptUi {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
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
$app=$null;$receipt=$null;$fixture=$null;$window=$null;$operation=$null;$journal=$null;$journalRestored=$false;$gameSession=$null;$frameCount=0;$clock=[Diagnostics.Stopwatch]::StartNew();$timeline=[Collections.Generic.List[object]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function ById([string]$id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name)}
function Capture([string]$path){
 $h=[IntPtr]::new($window.Current.NativeWindowHandle);$rect=New-Object RooIndustriesRestoreKeptUi+Rect;if(-not[RooIndustriesRestoreKeptUi]::GetWindowRect($h,[ref]$rect)){throw 'The app window could not be measured.'}
 $frame=New-Object RooIndustriesRestoreKeptUi+Rect;if([RooIndustriesRestoreKeptUi]::DwmGetWindowAttribute($h,9,[ref]$frame,16) -ne 0){$frame=$rect}
 $b=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top);$g=[Drawing.Graphics]::FromImage($b);$dc=$g.GetHdc()
 try{if(-not[RooIndustriesRestoreKeptUi]::PrintWindow($h,$dc,2)){throw 'The app window could not be drawn for a screenshot.'}}finally{$g.ReleaseHdc($dc);$g.Dispose()}
 $area=[Drawing.Rectangle]::Intersect([Drawing.Rectangle]::new($frame.Left-$rect.Left,$frame.Top-$rect.Top,$frame.Right-$frame.Left,$frame.Bottom-$frame.Top),[Drawing.Rectangle]::new(0,0,$b.Width,$b.Height))
 $c=$b.Clone($area,$b.PixelFormat);try{$c.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$c.Dispose();$b.Dispose()}
}
function Shot([string]$name){Save ($name+'-text.json') (Texts);Capture (Join-Path $directory ($name+'.png'))}
function Frame{$script:frameCount++;Capture (Join-Path $frames ('{0:D4}.png' -f $script:frameCount));$timeline.Add(@{frame=$script:frameCount;ms=$clock.ElapsedMilliseconds})|Out-Null}
function Card{$title=WaitFor {@(All|Where-Object {$_.Current.ControlType -eq $CT::Text -and $_.Current.Name -ceq 'Game priority'})|Select-Object -First 1} 30 'Game priority card';$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($title);@($panel.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name})}
function HostCall([string]$action,[hashtable]$fields){
 $request=@{schemaVersion=1;repoRoot=$AppRoot;confirm=$true};foreach($key in $fields.Keys){$request[$key]=$fields[$key]}
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'));$start.Arguments=$action+' -'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $call=[Diagnostics.Process]::Start($start);$owned=New-OwnedProcess $call
 try{
  $read=$call.StandardOutput.ReadToEndAsync();$errors=$call.StandardError.ReadToEndAsync()
  $call.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 20 -Compress));$call.StandardInput.Close()
  if(-not$call.WaitForExit(60000)){throw ('The native helper did not finish '+$action+'.')}
  $raw=$read.GetAwaiter().GetResult();$text=$errors.GetAwaiter().GetResult()
  $result=$raw|ConvertFrom-Json;if($call.ExitCode -ne 0 -or $result.status -ne 'completed'){throw ($action+' failed: '+$raw+$text)}
  return $result.data
 }finally{Stop-OwnedProcess $owned}
}
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
 $start=($start -join "`n")|ConvertFrom-Json;$gameSession=$start;Save 'start.json' $start
 $applied=Read-Fixture $process
 if($applied.priorityClass -ne 'AboveNormal' -or $applied.affinityMask -ne $affinity -or -not$start.restorable){throw ('Game priority did not apply to the fixture: '+$applied.priorityClass+' '+$applied.affinityMask)}
 if($Scenario -eq 'saved-change'){
  . (Join-Path $AppRoot 'backend\scripts\BrandCompatibility.Common.ps1')
  $operation=Join-Path (Get-RooIndustriesLocalDataRoot) ('operations\process-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($operation)|Out-Null
  $preview=Join-Path $operation 'preview.json';$journal=Join-Path $operation 'journal.json'
  HostCall 'process-preview' @{processId=$process.Id;controls=@{cpuPriority='High'};outputPath=$preview}|Out-Null
  HostCall 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal}|Out-Null
  $changed=Read-Fixture $process
  if($changed.priorityClass -ne 'High'){throw ('The saved one-time change did not apply: '+$changed.priorityClass)}
 }else{$process.PriorityClass='BelowNormal';$changed=Read-Fixture $process}
 $app=Start-Process $exe[0].FullName -PassThru;$receipt=New-OwnedProcess $app
 $window=WaitFor {
  $windows=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id)))
  foreach($dialog in $windows|Where-Object {$_.Current.ClassName -eq '#32770'}){
   $message=$dialog.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'The earlier data folder was gone, so the app started fresh. Its saved rules and undo history are no longer available.'))
   if($message){
    $script:window=$dialog
    Save 'as-found-missing-data-notice.json' @{message=$message.Current.Name}
    Shot 'as-found-missing-data-notice'
    $ok=$dialog.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'OK'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))
    Activate $ok
   }
  }
  @($windows|Where-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings'))})|Select-Object -First 1
 } 120 'app window'
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
 if($after.affinityMask -ne $before.affinityMask){throw ('Restore did not return the affinity it changed: '+$after.affinityMask)}
 if($Scenario -eq 'saved-change'){
  if($after.priorityClass -ne 'High'){throw ('Restore overwrote the priority the saved one-time change holds: '+$after.priorityClass)}
  if($result -notcontains 'Game restore needs attention' -or $detail -notmatch ([regex]::Escape($process.ProcessName)+'(\.exe)? \(CPU priority\): Another saved change still uses this control\.')){throw 'The restore result does not name the setting another saved change holds.'}
  if($detail -match 'Undo that change first|Run Undo again|Undo couldn'){throw ('The Game priority card uses Undo wording on a page whose button says Restore: '+$detail)}
 }else{
  if($after.priorityClass -ne 'BelowNormal'){throw ('Restore overwrote the priority another program set: '+$after.priorityClass)}
  if($result -notcontains 'Game priorities restored' -or $detail -notmatch ([regex]::Escape($process.ProcessName)+'(\.exe)? CPU priority \(BelowNormal\)') -or $detail -notmatch 'Left as another program set it'){throw 'The restore result does not name the priority it left.'}
 }
 Save 'done.json' @{passed=$true;label=$Label}
}catch{
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Shot 'failure'}catch{}}
 throw
}finally{
 try{if($app){Stop-OwnedValidationApp $app $receipt}}
 finally{
  try{if($journal -and [IO.File]::Exists($journal)){HostCall 'process-restore' @{journalPath=$journal;acceptEarlierVersion=$true}|Out-Null};$journalRestored=$true}
  finally{
   try{if($gameSession -and $gameSession.restorable -and [IO.File]::Exists($gameSession.sessionPath) -and ([IO.File]::ReadAllText($gameSession.sessionPath)|ConvertFrom-Json).restorable){$stopped=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $AppRoot 'backend\scripts\Stop-GameTuneSession.ps1') -SessionId $gameSession.sessionId -SessionPath $gameSession.sessionPath -BackupPath $gameSession.backupManifestPath -ConfirmApply;$code=$LASTEXITCODE;$closed=try{($stopped -join "`n")|ConvertFrom-Json}catch{$null};if($code -or $null -eq $closed -or $closed.restorable -ne $false){throw ('Game priority cleanup left its session open: '+($stopped -join ' '))}}}
   finally{
    try{if($fixture){Stop-OwnedProcess $fixture}}
    finally{if($journalRestored -and $operation -and [IO.Directory]::Exists($operation)){Remove-Item -LiteralPath $operation -Recurse -Force}}
   }
  }
 }
}
