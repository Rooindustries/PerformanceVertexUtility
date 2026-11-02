param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$AppExe)
$ErrorActionPreference='Stop'
if(-not$env:DOTNET_ROOT -and [IO.Directory]::Exists((Join-Path $env:USERPROFILE '.dotnet'))){$env:DOTNET_ROOT=Join-Path $env:USERPROFILE '.dotnet';$env:DOTNET_ROOT_X64=$env:DOTNET_ROOT}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\GameTuneSession.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class RooIndustriesGameTuneRecoveryUi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
}
'@
[RooIndustriesGameTuneRecoveryUi]::SetProcessDPIAware()|Out-Null
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$scripts=Join-Path $Source 'backend\scripts'
$stateRoot=Join-Path $Source 'backend\state'
$sessions=Join-Path $stateRoot 'game-tune-sessions'
$expected="cs2.exe (CPU priority): Restore couldn't confirm it set this value, so it was left alone. It resets when that app restarts; then Restore again."
$owned=[Collections.Generic.List[object]]::new();$app=$null;$receipt=$null;$window=$null;$ownsState=$false;$backendRoot=$env:ROO_INDUSTRIES_BACKEND_ROOT
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot $name),($value|ConvertTo-Json -Depth 20),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function All{@($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))}
function Texts{@(All|Where-Object {$_.Current.ControlType -eq $CT::Text}|ForEach-Object {$_.Current.Name})}
function Button([string]$name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button)))}
function Activate($e){if(-not$e){throw 'Missing UI element'};try{$e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){Activate (WaitFor {@(All|Where-Object {$_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem})|Select-Object -First 1} 45 $name)}
function Card{$texts=@(Texts);$i=[Array]::IndexOf($texts,'Game priority');if($i -lt 0 -or $i+2 -ge $texts.Count){return $null};[pscustomobject]@{status=$texts[$i+1];detail=$texts[$i+2]}}
function Shot([string]$name){$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $OutRoot ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()};Save ($name+'-card.json') (Card)}
function Priority($p){$p.Refresh();[string]$p.PriorityClass}
try {
 Assert-NoUnownedAppProcess
 if(@(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue).Count){throw 'The staged backend state is not empty; refusing to share it'}
 if(@(Get-Process cs2 -ErrorAction SilentlyContinue).Count){throw 'A process named cs2 is already running; refusing to share the fixture name'}
 $ownsState=$true
 $probeDir=Join-Path $OutRoot 'probe';[IO.Directory]::CreateDirectory($probeDir)|Out-Null
 $exe=Join-Path $probeDir 'cs2.exe';Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $exe
 $game=Start-Process $exe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 900' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $game))
 Start-Sleep -Milliseconds 800;$game.PriorityClass='Normal'
 $profile=Join-Path $OutRoot 'profile.json';$reviewPath=Join-Path $OutRoot 'review.json'
 Write-RooIndustriesOperationJson ([pscustomobject]@{schemaVersion=1;profileId='recovery-ui-probe';name='Recovery UI probe';profileKind='process-controls';foregroundGame=@{ruleId='recovery-ui-game';processNames=@('cs2.exe');priorityClass='AboveNormal';reason='Disposable recovery probe.'};protectedCatalogPath=(Join-Path $Source 'backend\profiles\protected-processes.json');targetGames=@();rules=@();safeCandidates=@();protectedCompanions=@();protectedPreviewProcessNames=@()}) $profile
 $review=& (Join-Path $scripts 'Start-GameTuneSession.ps1') -ProfilePath $profile -PollIntervalSeconds 1 -MaxDurationSeconds 1|ConvertFrom-Json
 if($null -eq $review.review){throw 'The disposable profile produced no review'}
 Write-RooIndustriesOperationJson $review.review $reviewPath
 $command="& '$($scripts.Replace("'","''"))\Start-GameTuneSession.ps1' -ProfilePath '$($profile.Replace("'","''"))' -PollIntervalSeconds 1 -MaxDurationSeconds 600 -ReviewPath '$($reviewPath.Replace("'","''"))' -ReviewSha256 '$((Get-FileHash $reviewPath).Hash)' -ConfirmApply"
 $controller=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-EncodedCommand',([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) -WindowStyle Hidden -PassThru
 $controllerReceipt=New-OwnedProcess $controller;$owned.Add($controllerReceipt)
 $sessionPath=WaitFor {$path=Get-RooIndustriesGameTuneLatestSessionFile $sessions;if($path -and (Priority $game) -eq 'AboveNormal'){$path}} 60 'tuned session'
 $backupPath=WaitFor {$b=[string](Read-RooIndustriesJsonFile $sessionPath).backupManifestPath;if($b -and (Test-Path -LiteralPath $b) -and @((Read-RooIndustriesJsonFile $b).snapshots|ForEach-Object {$_.controlChanges}|Where-Object outcome -eq 'applied').Count){$b}} 60 'saved backup'
 Stop-OwnedProcess $controllerReceipt
 $backup=Read-RooIndustriesJsonFile $backupPath
 foreach($change in @($backup.snapshots|ForEach-Object {$_.controlChanges})){$change.outcome='pending'}
 Write-RooIndustriesGameTuneJsonFile $backup $backupPath
 $game.PriorityClass='High'
 $env:ROO_INDUSTRIES_BACKEND_ROOT=$Source
 $app=Start-Process $AppExe -PassThru;$receipt=New-OwnedProcess $app;Save 'owned-app.json' $receipt.Identity
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))} 120 'app window'
 $handle=[IntPtr]::new($window.Current.NativeWindowHandle)
 [RooIndustriesGameTuneRecoveryUi]::SetWindowPos($handle,[IntPtr]::new(-1),40,40,1280,860,0x40)|Out-Null
 [RooIndustriesGameTuneRecoveryUi]::SetForegroundWindow($handle)|Out-Null
 $later=$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'UpdateLaterButton'));if($later){Activate $later}
 WaitFor {@(Texts) -contains 'Start here'} 120 'Home'|Out-Null
 Nav 'Games';Activate (WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'BackgroundTab'))} 60 'Background apps tab')
 $card=WaitFor {$c=Card;if($c -and $c.status -notlike 'Checking*' -and $c.status -ne 'No active game priorities'){$c}} 120 'game card settled'
 $restore=Button 'Restore game priority';if($restore){try{$restore.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}}
 Start-Sleep -Seconds 2
 Shot '01-recovery'
 $card=Card;$session=Read-RooIndustriesJsonFile $sessionPath
 $named=$card.status -eq 'Needs attention' -and $card.detail -ceq $expected -and (Priority $game) -eq 'High' -and [bool]$session.restorable -and $session.sessionStatus -eq 'failed'
 Save 'result.json' @{machine=$env:COMPUTERNAME;card=$card;expected=$expected;gamePriority=(Priority $game);sessionStatus=$session.sessionStatus;restorable=$session.restorable;errors=@($session.errors|ForEach-Object {$_.message});skipped=@($session.skippedItems|ForEach-Object {$_.reason});named=$named}
 if(-not$named){throw ('The Game priority card did not name the held setting: '+$card.status+' / '+$card.detail)}
} catch {
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 if($window){try{Shot 'failure'}catch{}}
 throw
} finally {
 if($app){Stop-OwnedValidationApp $app $receipt}
 foreach($o in $owned){Stop-OwnedProcess $o}
 $env:ROO_INDUSTRIES_BACKEND_ROOT=$backendRoot
 if($ownsState -and (Test-Path -LiteralPath $sessions)){Remove-Item -LiteralPath $sessions -Recurse -Force}
 Save 'cleanup.json' @{appStopped=if($app){$app.HasExited}else{$true};probesExited=@($owned|ForEach-Object {$_.process.HasExited});stateEmpty=(@(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0)}
}
