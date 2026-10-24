param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label='drivers')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('drivers-page-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('drivers-page-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesDriversPage {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesDriversPage]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$words=[IO.File]::ReadAllText((Join-Path $Source 'tools\validation\DriversUi\plain-words.json'))|ConvertFrom-Json
$banned=@($words.banned|ForEach-Object {
 $options=if($_.caseSensitive){[Text.RegularExpressions.RegexOptions]::None}else{[Text.RegularExpressions.RegexOptions]::IgnoreCase}
 [pscustomobject]@{regex=[regex]::new($_.pattern,$options);why=$_.why}
})
$driverLine=[regex]::new($words.driverLine);$nvidiaLine=[regex]::new($words.nvidiaDriverLine);$nvidiaUndatedLine=[regex]::new($words.nvidiaUndatedDriverLine)
$evidence=[ordered]@{label=$Label;gpus=@();nvidia=$false;nvidiaDated=$false;checks=@();shots=@();shown=@();driverLines=@()}
function Check([bool]$Ok,[string]$Name,[string]$Detail=''){$script:evidence.checks+=@([ordered]@{pass=$Ok;name=$Name;detail=$Detail})}
function WaitFor([scriptblock]$Probe,[double]$Limit){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};return $null}
function ById([string]$Id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function ByText([string]$Name){$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$Name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text)))}
function Visible($Element){$Element -and -not $Element.Current.IsOffscreen}
function Shown{
 $kinds=[Windows.Automation.OrCondition]::new([Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Group))
 @($script:window.FindAll($TS::Descendants,$kinds)|ForEach-Object {$_.Current.Name}|Where-Object {$_}|Select-Object -Unique)
}
function Shot([string]$Name){
 [RooIndustriesDriversPage]::SetForegroundWindow($script:hwnd)|Out-Null;Start-Sleep -Milliseconds 700
 $r=$script:window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $directory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 $script:evidence.shots+=@($Name+'.png')
}
function Scroller{$e=ByText 'Processor';$walker=[Windows.Automation.TreeWalker]::ControlViewWalker;while($e -and -not [bool]$e.GetCurrentPropertyValue($A::IsScrollPatternAvailableProperty)){$e=$walker.GetParent($e)};$e}
function ScrollTo([double]$Percent){$s=Scroller;if($s){$p=$s.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern);if($p.Current.VerticallyScrollable){$p.SetScrollPercent(-1,$Percent)}};Start-Sleep -Milliseconds 600}
function CanScroll{$s=Scroller;$s -and $s.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this check does not take over another window.'}
 $evidence.gpus=@(Get-CimInstance Win32_VideoController|ForEach-Object {[string]$_.Name})
 $nvidiaGpu=@(Get-CimInstance Win32_VideoController|Where-Object {([string]$_.Name+' '+[string]$_.PNPDeviceID) -match 'nvidia|ven_10de'}|Select-Object -First 1)
 $evidence.nvidia=[bool]$nvidiaGpu.Count
 $evidence.nvidiaDated=[bool]@($nvidiaGpu|Where-Object {$null -ne $_.DriverDate}).Count
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $script:window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and $w.Current.NativeWindowHandle -ne 0){$w}} 180
 if(-not$script:window){throw ('The app window never opened'+$(if($app.process.HasExited){'; the app exited with code '+$app.process.ExitCode}else{'; the app is still running without a window'})+'.')}
 $script:hwnd=[IntPtr]::new([long]$script:window.Current.NativeWindowHandle)
 [RooIndustriesDriversPage]::ShowWindow($script:hwnd,9)|Out-Null
 [RooIndustriesDriversPage]::SetWindowPos($script:hwnd,[IntPtr]::new(-1),0,0,1280,1000,0x0040)|Out-Null

 $nav=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'Graphics drivers'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 60
 if(-not$nav){throw 'The Graphics drivers nav item never showed.'}
 $nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 $ready=WaitFor {if(Visible (ByText 'Processor')){'ready'}elseif((Visible (ById 'DriversRetry')) -or (Visible (ByText "Couldn't read your hardware")) -or (Visible (ByText "Can't read your hardware yet"))){'error panel'}} 120
 Check ($ready -eq 'ready') 'the Graphics drivers page loads its hardware panel' ([string]$ready)
 Start-Sleep 2
 $texts=@(Shown)
 ScrollTo 0;Shot 'drivers-page'
 if(CanScroll){ScrollTo 100;$texts+=@(Shown);Shot 'drivers-page-bottom';ScrollTo 0}
 $texts=@($texts|Select-Object -Unique);$evidence.shown=$texts

 $found=@(foreach($text in $texts){foreach($rule in $banned){if($rule.regex.IsMatch($text)){'"'+$text+'" shows '+$rule.why}}})
 Check ($found.Count -eq 0) 'the Graphics drivers page shows no old labels, trademark marks, raw driver versions or raw dates' (($found|Select-Object -First 12) -join ' | ')
 $lines=@($texts|Where-Object {$driverLine.IsMatch($_)});$evidence.driverLines=$lines
 if($evidence.nvidia){$expected=if($evidence.nvidiaDated){$nvidiaLine}else{$nvidiaUndatedLine};Check ($lines.Count -eq 1 -and $expected.IsMatch($lines[0])) 'with an NVIDIA card the driver line shows the NVIDIA driver number, and a readable date when Windows reports one' ($lines -join ' | ')}
 [RooIndustriesDriversPage]::SetWindowPos($script:hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status=if(@($evidence.checks|Where-Object {-not $_.pass}).Count){'fail'}else{'pass'}
}catch{
 $evidence.error=$_.Exception.Message
 throw
}finally{
 try{
  if($app){Stop-HarnessProcess $app}
 }catch{
  $status='fail';$evidence.cleanupError=$_.Exception.Message
  throw
 }finally{
  $evidence.status=$status
  Write-HarnessResult $directory 'drivers-page.json' $evidence|Out-Null
  foreach($check in $evidence.checks){Write-Output ('CHECK '+$(if($check.pass){'PASS '}else{'FAIL '})+$check.name+$(if($check.detail){' :: '+$check.detail}else{''}))}
  Write-Output ('ROO_INDUSTRIES_DRIVERS_PAGE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
