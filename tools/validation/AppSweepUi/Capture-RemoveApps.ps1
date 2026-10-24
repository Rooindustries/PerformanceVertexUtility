param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('remove-apps-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('remove-apps-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesRemoveAppsCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
'@
[RooIndustriesRemoveAppsCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$private=@('\Users\','/Users/',$env:USERNAME,$env:COMPUTERNAME)|Where-Object {$_}
$evidence=[ordered]@{label=$Label;shots=@();skipped=@();simpleModeChanged=$false}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 250};throw ('Timed out waiting for '+$What+'.')}
function ById($Root,[string]$Id){$Root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Shown($Element){$Element -and -not $Element.Current.IsOffscreen}
function Texts($Root){@($Root.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name})}
function IsPrivate([string[]]$Lines){foreach($line in $Lines){foreach($word in $private){if($line -and $line.IndexOf($word,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}}};$false}
function Nav([string]$Name){
 $item=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$Name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 30 ('the '+$Name+' page in the sidebar')
 $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 2
}
function SimpleMode([bool]$On){
 Nav 'Settings'
 $toggle=(WaitFor {ById $script:window 'SimpleModeToggle'} 30 'the Simple mode switch').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 if(($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -ne $On){$toggle.Toggle();Start-Sleep -Seconds 1}
 Nav 'Remove apps'
}
function Busy{(Texts $script:window|Where-Object {$_ -match '^(Checking|Looking for|Scanning)'}).Count -gt 0}
function Invoke([string]$Id){
 $button=WaitFor {$b=ById $script:window $Id;if($b -and $b.Current.IsEnabled){$b}} 30 ($Id+' to be enabled')
 $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Milliseconds 500
 WaitFor {-not (Busy)} 180 ($Id+' to finish')|Out-Null;Start-Sleep -Seconds 1
}
function Shot([string]$Name){
 [RooIndustriesRemoveAppsCapture]::SetForegroundWindow($script:hwnd)|Out-Null
 [RooIndustriesRemoveAppsCapture]::SetCursorPos([RooIndustriesRemoveAppsCapture]::GetSystemMetrics(0)-8,8)|Out-Null;Start-Sleep -Milliseconds 1200
 $r=$script:window.Current.BoundingRectangle;$path=Join-Path $directory ($Label+'-'+$Name+'.png')
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 $evidence.shots+=@($Label+'-'+$Name+'.png')
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null|Where-Object {$_ -match '^8\.'}).Count})
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$status='fail';$script:window=$null;$simpleWasOn=$false
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:ROO_INDUSTRIES_INITIAL_NAV='uninstall'
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $script:window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and (ById $w 'RemovalTab')){$w}} 180 'the Remove apps page'
 $script:hwnd=[IntPtr]::new([long]$script:window.Current.NativeWindowHandle)
 [RooIndustriesRemoveAppsCapture]::SetWindowPos($script:hwnd,[IntPtr]::Zero,40,40,1440,940,0x0040)|Out-Null
 if(-not (Shown (ById $script:window 'LeftoversTab'))){$simpleWasOn=$true;$evidence.simpleModeChanged=$true;SimpleMode $false}
 WaitFor {Shown (ById $script:window 'LeftoversTab')} 30 'the Leftover cleanup tab'|Out-Null

 (ById $script:window 'RemovalTab').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 $list=WaitFor {$l=ById $script:window 'RemovalApps';if($l -and $l.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)).Count){$l}} 120 'the installed apps list'
 $picked=$false
 foreach($item in @($list.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Select-Object -First 15)){
  if(IsPrivate (Texts $item)){continue}
  $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).AddToSelection();$picked=$true;break
 }
 if(-not$picked){throw 'No installed app without a private name was found.'}
 Start-Sleep -Seconds 1
 if(IsPrivate (Texts $script:window)){throw 'The Remove apps tab shows a private name; no screenshot was kept.'}
 Shot 'remove-apps'

 (ById $script:window 'LeftoversTab').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 $apps=WaitFor {$l=ById $script:window 'AppsCleanupInstalledAppsList';if($l -and $l.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)).Count){$l}} 120 'the Leftover cleanup app list'
 $chosen=$null
 foreach($item in @($apps.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Select-Object -First 25)){
  $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 1
  $check=ById $script:window 'AppsCleanupCheckRouteButton'
  if(-not (IsPrivate (Texts $script:window)) -and $check -and $check.Current.IsEnabled){$chosen=$item;break}
 }
 if(-not$chosen){throw 'No app without a private folder could be checked.'}
 Shot 'leftover-picked'
 Invoke 'AppsCleanupCheckRouteButton'
 if(IsPrivate (Texts $script:window)){throw 'The checked app shows a private name; no screenshot was kept.'}
 Shot 'leftover-checked'
 $scan=ById $script:window 'AppsCleanupScanLeftoversButton'
 if($scan -and $scan.Current.IsEnabled){
  Invoke 'AppsCleanupScanLeftoversButton'
  if(IsPrivate (Texts $script:window)){$evidence.skipped+=@('leftover-found: it lists a folder inside a user profile')}else{Shot 'leftover-found'}
 }else{$evidence.skipped+=@('leftover-found: Find leftovers was not available for this app')}
 $status='pass'
}catch{
 $evidence.error=$_.Exception.Message
 throw
}finally{
 try{
  if($script:window -and $simpleWasOn){SimpleMode $true}
  if($script:window){$script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}
  if($app -and -not $app.process.WaitForExit(20000)){Stop-HarnessProcess $app}
 }catch{
  $status='fail';$evidence.cleanupError=$_.Exception.Message
  if($app){Stop-HarnessProcess $app}
 }finally{
  $evidence.status=$status
  Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
  Write-Output ('ROO_INDUSTRIES_REMOVE_APPS_CAPTURE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
