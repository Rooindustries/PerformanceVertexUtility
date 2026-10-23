param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$AppStage,[ValidateSet('before','after')][string]$Label='after',[int]$Probes=24,[string]$Ffmpeg='')
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Add-Type 'using System;using System.Runtime.InteropServices;public static class RooIndustriesInterruptedUi{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);[DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);}'
[RooIndustriesInterruptedUi]::SetProcessDPIAware()|Out-Null
Assert-NoUnownedAppProcess
$directory=Join-Path $OutRoot ('interrupted-apply-ui-'+$Label);[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$app=$null;$receipt=$null;$window=$null;$recorder=$null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$settings=Join-Path (Get-RooIndustriesLocalDataRoot) 'settings';$pointer=Join-Path $settings 'process-profile-recovery.json';$journal=Join-Path $settings 'process-profile-apply.json'
$generation=Join-Path $settings 'process-profile-operation-generation.json';$backups=Join-Path $settings 'process-profile-backups'
foreach($path in $pointer,$journal){if(Test-Path -LiteralPath $path){throw ('An earlier process restore is pending; preserve it before the fixture: '+$path)}}
$generationBytes=if(Test-Path -LiteralPath $generation){[IO.File]::ReadAllBytes($generation)}else{$null}
$backupsBefore=@(if(Test-Path -LiteralPath $backups){Get-ChildItem -LiteralPath $backups -Directory|ForEach-Object FullName})
$profilePath=Join-Path $AppStage 'backend\profiles\game-session.profile.json';$profileBytes=[IO.File]::ReadAllBytes($profilePath)
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
if($Label -eq 'after' -and -not$Ffmpeg){$Ffmpeg=(Get-Command ffmpeg.exe -ErrorAction Stop).Source}

function Save($name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 30),$utf8)}
function Own($p){$r=New-OwnedProcess $p;if($r){$owned.Add($r)};$r}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function ById([string]$id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function ProcessButton([string]$name){$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent((Button 'Review process changes'));while($panel){$buttons=@($panel.FindAll($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button))));if($buttons.Count -eq 1){return $buttons[0]};$panel=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($panel)};throw ('Missing process-card button: '+$name)}
function Texts{@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name})}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {$_.Current.Name -eq $name})|Select-Object -First 1} 45 $name)}
function Shot([string]$name){Save ($name+'-text') (Texts);$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $directory ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}}
function Read($p){$p.Refresh();[ordered]@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}}
function Changed($fixtures){@($fixtures|Where-Object {$_.Refresh();[string]$_.PriorityClass -ne 'Normal'})}

try {
 & $dotnet publish (Join-Path $Source 'tools\validation\ClientBoundary\ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -r win-x64 --self-contained false -o (Join-Path $directory 'probe') *> (Join-Path $directory 'probe-build.log')
 if($LASTEXITCODE){throw 'Client probe build failed'}
 $tag=[Guid]::NewGuid().ToString('N').Substring(0,6);$folder=Join-Path $directory 'fixtures';[IO.Directory]::CreateDirectory($folder)|Out-Null
 $fixtures=@(for($i=0;$i -lt $Probes;$i++){$path=Join-Path $folder ('RooIndustriesCutUi'+$tag+$i.ToString('00')+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$null=Own $p;$p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5);$p})
 $before=@{};foreach($p in $fixtures){$before[$p.Id]=Read $p};Save 'before' @($before.Values)
 $profile=[Text.Encoding]::UTF8.GetString($profileBytes).TrimStart([char]0xfeff)|ConvertFrom-Json;$profile.profileId='roo655-interrupted-apply-ui';$profile.foregroundGame.processNames=@();$profile.targetGames=@()
 $profile.rules=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($fixtures|ForEach-Object {$_.ProcessName+'.exe'})};action=@{actionType='setPriority';priorityClass='BelowNormal'}})
 [IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 30),$utf8)
 $arguments=@((Join-Path $directory 'probe\ClientBoundary.dll'),'--recovery-slot','apply',(Join-Path $directory 'cut-apply.json'),$AppStage,$settings)|ForEach-Object {'"'+$_+'"'}
 $runner=Own (Start-Process $dotnet -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory 'cut-apply.log'))
 $script=WaitFor {$child=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$runner.process.Id)|Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Apply-ProcessProfile.ps1*'});if($child.Count -eq 1){Own (Get-Process -Id $child[0].ProcessId)}} 90 'apply script'
 $null=WaitFor {(Changed $fixtures).Count} 120 'first fixture change'
 Stop-OwnedProcess $runner;Stop-OwnedProcess $script;$null=$runner.process.WaitForExit(15000);$null=$script.process.WaitForExit(15000)
 $cut=(Changed $fixtures).Count;Save 'cut' @{changed=$cut;of=$Probes;journal=(Test-Path -LiteralPath $journal);pointer=(Test-Path -LiteralPath $pointer)}
 if($cut -lt 1 -or $cut -ge $Probes){throw ('The cut did not land mid-apply: '+$cut+' of '+$Probes)}

 $app=Start-Process (Join-Path $AppStage 'app\RooIndustries.OptimizationSuite.App.exe') -PassThru;$receipt=New-OwnedProcess $app;Save 'owned-app' $receipt.Identity
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))} 120 'app window'
 $handle=[IntPtr]::new($window.Current.NativeWindowHandle);[RooIndustriesInterruptedUi]::SetWindowPos($handle,[IntPtr]::new(-1),40,40,1440,960,0x40)|Out-Null;[RooIndustriesInterruptedUi]::SetForegroundWindow($handle)|Out-Null
 if(ById 'UpdateLaterButton'){Activate (ById 'UpdateLaterButton')}
 WaitFor {@(Texts) -contains 'Start here'} 90 'Home'|Out-Null
 if($Label -eq 'after'){
  $r=$window.Current.BoundingRectangle;$w=[int]$r.Width-([int]$r.Width%2);$h=[int]$r.Height-([int]$r.Height%2)
  $recorder=Own (Start-Process $Ffmpeg -ArgumentList @('-y','-f','gdigrab','-framerate','30','-offset_x',[int]$r.X,'-offset_y',[int]$r.Y,'-video_size',($w.ToString()+'x'+$h),'-draw_mouse','0','-i','desktop','-t','18','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p',('"'+(Join-Path $directory 'restore-offer.mp4')+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $directory 'ffmpeg.log'))
  Start-Sleep 1
 }
 Nav 'Games';Activate (WaitFor {ById 'BackgroundTab'} 90 'Background tab');$null=WaitFor {ProcessButton 'Restore'} 90 'Background apps card'
 if($Label -eq 'before'){
  Start-Sleep 5;$restore=ProcessButton 'Restore'
  Save 'no-offer' @{restoreEnabled=$restore.Current.IsEnabled;applyEnabled=(ProcessButton 'Apply').Current.IsEnabled;stillChanged=(Changed $fixtures).Count;pointer=(Test-Path -LiteralPath $pointer);journal=(Test-Path -LiteralPath $journal)}
  Shot 'no-offer'
  if($restore.Current.IsEnabled){throw 'Main offered Restore after an interrupted apply'}
 } else {
  $restore=WaitFor {$b=ProcessButton 'Restore';if($b.Current.IsEnabled){$b}} 45 'Restore offered'
  $null=WaitFor {@(Texts) -contains "Last apply didn't finish"} 20 'interrupted apply notice'
  Save 'offer' @{restoreEnabled=$true;applyEnabled=(ProcessButton 'Apply').Current.IsEnabled;stillChanged=(Changed $fixtures).Count;pointer=(Test-Path -LiteralPath $pointer);journal=(Test-Path -LiteralPath $journal)}
  Start-Sleep 3;Shot 'offer';Activate $restore
  $null=WaitFor {-not(Test-Path -LiteralPath $pointer) -and (ProcessButton 'Apply').Current.IsEnabled} 90 'restored'
  $after=@{};foreach($p in $fixtures){$now=Read $p;$after[[string]$p.Id]=$now;foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$now.$field -cne [string]$before[$p.Id].$field){throw ('UI restore left '+$p.ProcessName+' '+$field+' at '+$now.$field)}}}
  Save 'restored' $after;Start-Sleep 3;Shot 'restored'
  if(-not$recorder.process.WaitForExit(60000)){throw 'Recording did not finish'}
 }
 Save 'done' @{status='passed';label=$Label;cut=$cut}
} catch {if($window){try{Shot 'failure'}catch{}};Save 'failure' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace};throw}
finally {
 if($app){Stop-OwnedValidationApp $app $receipt}
 for($i=$owned.Count-1;$i -ge 0;$i--){try{Stop-OwnedProcess $owned[$i]}catch{}}
 [IO.File]::WriteAllBytes($profilePath,$profileBytes)
 foreach($path in $pointer,$journal){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
 if($generationBytes){[IO.File]::WriteAllBytes($generation,$generationBytes)}elseif(Test-Path -LiteralPath $generation){Remove-Item -LiteralPath $generation}
 if(Test-Path -LiteralPath $backups){foreach($created in @(Get-ChildItem -LiteralPath $backups -Directory|Where-Object {$backupsBefore -notcontains $_.FullName})){Remove-Item -LiteralPath $created.FullName -Recurse};if(-not$backupsBefore.Count -and -not@(Get-ChildItem -LiteralPath $backups -Force).Count){Remove-Item -LiteralPath $backups}}
 Save 'cleanup' @{appStopped=if($app){$app.HasExited}else{$true};processes=@($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.process.HasExited}})}
}
