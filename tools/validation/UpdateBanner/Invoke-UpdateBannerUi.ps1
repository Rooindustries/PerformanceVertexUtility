param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,40}$')][string]$Label)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooUpdateBannerUi
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
}
'@
[RooUpdateBannerUi]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$version='9.9.9-beta'
$ready="Version $version is ready to install"
$changeRunning='A change is still running. You can install the update once it finishes.'
$appName='RooIndustries.OptimizationSuite.App'
$out=Join-Path $OutRoot $Label
if(Test-Path -LiteralPath $out){throw 'The output folder already exists; use a new label.'}
New-Item -ItemType Directory -Path $out|Out-Null
$flag=Join-Path $out 'hold-change.flag'
$checks=[Collections.Generic.List[object]]::new()
$script:app=$null;$script:window=$null;$script:frames=$null

function Check([string]$name,[bool]$passed,$detail){
 $checks.Add([pscustomobject]@{name=$name;passed=$passed;detail=$detail})
 Write-Output ($(if($passed){'PASS '}else{'FAIL '})+$name+' :: '+(ConvertTo-Json $detail -Compress -Depth 5))
}
function Poll([scriptblock]$probe,[double]$seconds){$until=[DateTime]::UtcNow.AddSeconds($seconds);do{$value=& $probe;if($value){return $value};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until);$null}
function Find([string]$property,[string]$value){
 $key=if($property -eq 'id'){$A::AutomationIdProperty}else{$A::NameProperty}
 $script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($key,$value))
}
function Activate($element){
 if($element.Current.ProcessId -ne $script:app.Id){throw 'The control belongs to another process.'}
 try{$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{}
 $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Press([string]$property,[string]$value){$element=Poll {$x=Find $property $value;if($x -and $x.Current.IsEnabled){$x}} 30;if(-not$element){throw ('Not found or disabled: '+$value)};Activate $element}
function Enabled([string]$id){$x=Find 'id' $id;[bool]($x -and $x.Current.IsEnabled)}
function BannerTexts{
 $banner=Find 'id' 'UpdateBanner'
 if(-not$banner -or $banner.Current.IsOffscreen){return @()}
 @($banner.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {[string]$_.Current.Name}|Where-Object {$_})
}
function SettingsStatus{$x=Find 'id' 'UpdateStatusText';if($x){[string]$x.Current.Name}else{''}}
function Nav([string]$name){
 $item=Poll {@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))|Where-Object {$_.Current.ControlType -eq $CT::ListItem})[0]} 30
 if(-not$item){throw ('Navigation item not found: '+$name)}
 Activate $item
}
function OpenSettings{Nav 'Settings';if(-not(Poll {Find 'id' 'UpdateStatusText'} 30)){throw 'Settings did not open.'}}
function OpenTools{Nav 'Tools';Start-Sleep -Milliseconds 500}
function Raise([bool]$on){
 $handle=[IntPtr]::new($script:window.Current.NativeWindowHandle)
 [RooUpdateBannerUi]::ShowWindow($handle,9)|Out-Null
 [RooUpdateBannerUi]::SetWindowPos($handle,[IntPtr]::new($(if($on){-1}else{-2})),0,0,0,0,0x53)|Out-Null
}
function Area{
 $r=$script:window.Current.BoundingRectangle
 $height=$r.Height
 $limit=Find 'id' 'UpdateInstallButton'
 if($limit -and -not$limit.Current.IsOffscreen){$height=[Math]::Min($height,$limit.Current.BoundingRectangle.Bottom-$r.Y+24)}
 @{x=[int]$r.X;y=[int]$r.Y;width=[int]$r.Width;height=[int]$height}
}
function Shot([string]$name){
 Raise $true;Start-Sleep -Milliseconds 400
 $area=Area
 $bitmap=[Drawing.Bitmap]::new($area.width,$area.height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen($area.x,$area.y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $out ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}
 finally{$graphics.Dispose();$bitmap.Dispose()}
}
function StartFrames([string]$name){
 Raise $true;Start-Sleep -Milliseconds 300
 $folder=Join-Path $out ('frames-'+$name);New-Item -ItemType Directory -Path $folder|Out-Null
 $stop=Join-Path $out ('frames-'+$name+'.stop')
 $r=$script:window.Current.BoundingRectangle
 $shell=[PowerShell]::Create()
 $null=$shell.AddScript({
  param($folder,$stop,$x,$y,$width,$height)
  Add-Type -AssemblyName System.Drawing
  $clock=[Diagnostics.Stopwatch]::StartNew();$index=0
  while(-not(Test-Path -LiteralPath $stop) -and $clock.Elapsed.TotalSeconds -lt 45){
   $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
   try{$graphics.CopyFromScreen($x,$y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $folder ('{0:D5}.jpg' -f $index)),[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$graphics.Dispose();$bitmap.Dispose()}
   $index++;$wait=[int]($index*100-$clock.ElapsedMilliseconds);if($wait -gt 0){Start-Sleep -Milliseconds $wait}
  }
  $index
 }).AddArgument($folder).AddArgument($stop).AddArgument([int]$r.X).AddArgument([int]$r.Y).AddArgument([int]$r.Width).AddArgument([int]$r.Height)
 $script:frames=@{shell=$shell;handle=$shell.BeginInvoke();stop=$stop;name=$name}
}
function StopFrames{
 if(-not$script:frames){return}
 New-Item -ItemType File -Path $script:frames.stop|Out-Null
 $count=$script:frames.shell.EndInvoke($script:frames.handle);$script:frames.shell.Dispose()
 Write-Output ('frames '+$script:frames.name+': '+(@($count)[-1]))
 $script:frames=$null
}
function Launch([hashtable]$extra){
 Remove-Item Env:\ROO_INDUSTRIES_TEST_INSTALL_FREE_BYTES -ErrorAction SilentlyContinue
 $env:ROO_INDUSTRIES_TEST_UPDATE_READY=$version;$env:ROO_INDUSTRIES_TEST_HOLD_CHANGE=$flag;$env:ROO_INDUSTRIES_INITIAL_NAV='tools'
 foreach($key in $extra.Keys){Set-Item -Path ('Env:\'+$key) -Value $extra[$key]}
 $script:app=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
 $script:window=Poll {
  if($script:app.HasExited){throw ('The app exited during startup with code '+$script:app.ExitCode)}
  $w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id))
  if($w -and $w.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'UpdateBannerInstall'))){$w}
 } 120
 if(-not$script:window){throw 'The app window with the update banner did not appear.'}
 if(-not(Poll {Enabled 'UpdateBannerInstall'} 30)){throw 'Install now never became available.'}
 Start-Sleep -Seconds 2
}
function CloseApp{
 if(-not$script:app -or $script:app.HasExited){return}
 Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue
 Start-Sleep -Milliseconds 600
 try{$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}
 if(-not$script:app.WaitForExit(20000)){Stop-Process -Id $script:app.Id -Force}
}
function AfterClick{
 Start-Sleep -Milliseconds 700
 Poll {
  if(Find 'name' "Install version $version now?"){return 'dialog'}
  if((Enabled 'UpdateBannerInstall') -or (@(BannerTexts) -contains $changeRunning)){return 'settled'}
 } 30
}

try{
 if(@(Get-Process -Name $appName -ErrorAction SilentlyContinue).Count){throw 'Another app window is open; this run left it alone.'}
 $dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
 $env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:RooIndustriesTestHooks='true'
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 $builds=@(
  @{name='helper';arguments=('publish "'+(Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj')+'" -c Debug --self-contained false -p:UseSharedCompilation=false -o "'+(Join-Path $Source 'backend\bin\optimizer')+'"')},
  @{name='app';arguments=('build "'+$project+'" -c Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true -p:UseSharedCompilation=false --disable-build-servers')}
 )
 foreach($build in $builds){
  $process=Start-Process -FilePath $dotnet -ArgumentList $build.arguments -RedirectStandardOutput (Join-Path $out ($build.name+'-build.log')) -RedirectStandardError (Join-Path $out ($build.name+'-build-error.log')) -NoNewWindow -Wait -PassThru
  if($process.ExitCode){throw ($build.name+' build failed with code '+$process.ExitCode)}
 }
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin') -Recurse -Filter ($appName+'.exe'))[0].FullName

 Launch @{ROO_INDUSTRIES_TEST_INSTALL_FREE_BYTES='1048576'}
 Press 'id' 'UpdateBannerInstall'
 if((AfterClick) -eq 'dialog'){Shot 'low-space-dialog';Press 'name' 'Not now'}
 Start-Sleep -Seconds 1
 $banner=@(BannerTexts)
 Check 'Low disk space: the banner says why Install now did nothing' ((@($banner -like 'Free at least 1 GB on drive *')).Count -eq 1) $banner
 Shot 'low-space-banner'
 OpenSettings
 $status=SettingsStatus
 Check 'Low disk space: Settings shows the same reason as the banner' (($status -like 'Free at least 1 GB on drive *') -and ($banner -contains $status)) @{settings=$status;banner=$banner}
 Shot 'low-space-settings'
 CloseApp

 Launch @{}
 Shot 'ready'
 Check 'The banner offers the fixture update' ((BannerTexts) -contains $ready) (BannerTexts)
 New-Item -ItemType File -Path $flag|Out-Null
 Start-Sleep -Milliseconds 1500
 StartFrames 'install-while-change-runs'
 Start-Sleep -Milliseconds 1500
 Press 'id' 'UpdateBannerInstall'
 $outcome=AfterClick
 Start-Sleep -Seconds 2
 if($outcome -eq 'dialog'){
  Check 'Running change: Install now refuses before the confirmation' $false 'The install confirmation opened while a change was running.'
  Shot 'change-running-dialog'
  Press 'name' 'Not now'
  Start-Sleep -Seconds 1
 }else{Check 'Running change: Install now refuses before the confirmation' $true $outcome}
 $banner=@(BannerTexts)
 Check 'Running change: the banner says why' ($banner -contains $changeRunning) $banner
 Check 'Running change: Install now waits, disabled' (-not(Enabled 'UpdateBannerInstall')) @{enabled=(Enabled 'UpdateBannerInstall')}
 Shot 'change-running-banner'
 OpenSettings
 Start-Sleep -Seconds 1
 $status=SettingsStatus
 Check 'Running change: Settings shows the same reason and waits too' (($status -ceq $changeRunning) -and -not(Enabled 'UpdateInstallButton')) @{settings=$status;settingsInstallEnabled=(Enabled 'UpdateInstallButton')}
 Shot 'change-running-settings'
 Start-Sleep -Seconds 1
 Remove-Item -LiteralPath $flag
 $cleared=Poll {if((Enabled 'UpdateBannerInstall') -and (Enabled 'UpdateInstallButton') -and -not(@(BannerTexts) -contains $changeRunning) -and (SettingsStatus) -ceq $ready){$true}} 15
 Start-Sleep -Seconds 2
 StopFrames
 Check 'Change finished: Install is available again on the banner and Settings' ([bool]$cleared) @{banner=@(BannerTexts);settings=(SettingsStatus);bannerEnabled=(Enabled 'UpdateBannerInstall');settingsEnabled=(Enabled 'UpdateInstallButton')}
 Shot 'change-finished-settings'
 Press 'id' 'UpdateInstallButton'
 $outcome=AfterClick
 $banner=@(BannerTexts)
 Check 'Nothing running: Install opens the confirmation (or names another blocker)' (($outcome -eq 'dialog') -or (($banner -contains (SettingsStatus)) -and (SettingsStatus) -cne $ready)) @{outcome=$outcome;banner=$banner;settings=(SettingsStatus)}
 if($outcome -eq 'dialog'){Shot 'confirmation';Press 'name' 'Not now';Poll {Enabled 'UpdateInstallButton'} 20|Out-Null}
 Press 'id' 'UpdateLaterButton'
 $hidden=Poll {if(-not@(BannerTexts).Count){$true}} 10
 Check 'Later still hides the banner and Settings keeps the update' ([bool]$hidden -and (Enabled 'UpdateInstallButton')) @{banner=@(BannerTexts);settings=(SettingsStatus)}
 OpenTools
 New-Item -ItemType File -Path $flag|Out-Null
 Start-Sleep -Milliseconds 1500
 try{$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}
 $guard=Poll {if($script:app.HasExited){'exited'}elseif(Find 'name' 'Keep open'){'asked'}} 10
 Check 'Running change: closing the window asks instead of closing' ($guard -eq 'asked') @{outcome=$guard}
 if($guard -eq 'asked'){
  Shot 'close-guard'
  Press 'name' 'Keep open'
  Start-Sleep -Seconds 2
  Check 'Keep open leaves the app running' (-not$script:app.HasExited) @{alive=(-not$script:app.HasExited)}
  Remove-Item -LiteralPath $flag
  Start-Sleep -Milliseconds 800
  try{$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}
  Check 'With nothing running the window closes at once' ($script:app.WaitForExit(20000)) @{exited=$script:app.HasExited}
 }
}catch{
 Check ('Run error: '+$_.Exception.Message) $false $_.ScriptStackTrace
}finally{
 StopFrames
 if($script:window){try{Raise $false}catch{}}
 CloseApp
 Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue
 $failed=@($checks|Where-Object {-not$_.passed}).Count
 [IO.File]::WriteAllText((Join-Path $out 'results.json'),(ConvertTo-Json @{label=$Label;checks=$checks;failed=$failed} -Depth 8),[Text.UTF8Encoding]::new($false))
 Compress-Archive -Path (Join-Path $out '*') -DestinationPath (Join-Path $OutRoot ($Label+'.zip'))
 Write-Output ('Completed '+$checks.Count+' checks, '+$failed+' failed.')
}
if($failed){throw ([string]$failed+' update banner checks failed.')}
