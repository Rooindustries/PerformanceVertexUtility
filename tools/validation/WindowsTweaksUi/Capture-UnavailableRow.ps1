param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label,[string]$SettingId='windows.171a004ed11767da',[string]$Search='Telemetry - Disable: system',[string]$HiddenModules='ConfigDefender,Defender,DefenderPerformance',[string]$HiddenCommand='Get-MpPreference')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('unavailable-row-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('unavailable-row-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesRowCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesRowCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope]
$hidden=@($HiddenModules.Split(',')|ForEach-Object {$_.Trim()}|Where-Object {$_})
$evidence=[ordered]@{label=$Label;settingId=$SettingId;search=$Search;hiddenModules=$hidden;frames=@()}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function ById($Root,[string]$Id){$Root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Row($Window){
 $details=ById $Window ($SettingId+'.details');if(-not$details){return $null}
 $walker=[Windows.Automation.TreeWalker]::ControlViewWalker;$item=$details
 while($item -and $item.Current.ControlType -ne [Windows.Automation.ControlType]::ListItem){$item=$walker.GetParent($item)}
 return $item
}
function RowState($Window){
 $item=Row $Window;if(-not$item){return $null}
 $texts=@($item.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::Text))|ForEach-Object {$_.Current.Name})
 $current=@($texts|Where-Object {$_ -like '*: current value *'}|Select-Object -First 1)
 return [ordered]@{current=$(if($current.Count){$current[0].Substring($current[0].IndexOf(': current value ')+16)}else{$null});retry=[bool](ById $item ($SettingId+'.retry'));texts=$texts}
}
function Shot($Window,[string]$Path,[string]$Format='png'){
 $r=$Window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save($Path,$(if($Format -eq 'png'){[Drawing.Imaging.ImageFormat]::Png}else{[Drawing.Imaging.ImageFormat]::Jpeg}))}finally{$graphics.Dispose();$bitmap.Dispose()}
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$copy=Join-Path $directory 'modules';$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $evidence.provider=[string](Get-Command $HiddenCommand -ErrorAction Stop).Module.Path
 $roots=@((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules'),(Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\Modules'))
 $paths=@()
 for($index=0;$index -lt $roots.Count;$index++){
  $target=Join-Path $copy ([string]$index);[IO.Directory]::CreateDirectory($target)|Out-Null
  foreach($module in @(Get-ChildItem -LiteralPath $roots[$index] -Directory)){
   if($module.Name -in $hidden){continue}
   & (Join-Path ([Environment]::SystemDirectory) 'robocopy.exe') $module.FullName (Join-Path $target $module.Name) /E /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP|Out-Null
   if($LASTEXITCODE -ge 8){throw ('Copying module '+$module.Name+' failed.')}
  }
  $paths+=$target
 }
 $modulePath=$paths -join ';'
 $probe=@(& (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -Command ("`$env:PSModulePath='"+$modulePath.Replace("'","''")+"';[bool](Get-Command "+$HiddenCommand+" -ErrorAction SilentlyContinue);[bool](Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue)"))
 $evidence.hiddenCommandFound=$probe[0];$evidence.firewallCommandFound=$probe[1]
 if($probe.Count -ne 2 -or $probe[0] -ne 'False' -or $probe[1] -ne 'True'){throw ('The module copy must hide '+$HiddenCommand+' and keep the other modules: '+($probe -join ','))}
 $env:ROO_INDUSTRIES_TEST_MODULE_PATH=$modulePath;$env:ROO_INDUSTRIES_INITIAL_NAV='windows';$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid))} 120 'the Suite window'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 $search=WaitFor {ById $window 'WindowsTweaksSearch'} 120 'the Windows tweaks page'
 WaitFor {ById $window 'WindowsTweaksList'} 120 'the Windows tweaks list'|Out-Null
 $advanced=WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'Show advanced options'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::CheckBox)))} 60 'the advanced options box'
 $toggle=$advanced.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 $evidence.advancedBefore=[string]$toggle.Current.ToggleState
 if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
 $value=$search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
 $value.SetValue($Search)
 $evidence.loaded=WaitFor {$state=RowState $window;if($state -and $state.current -in "Couldn't check",'Not available here'){$state}} 240 'the row to finish loading'
 $value.SetValue('')
 [RooIndustriesRowCapture]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesRowCapture]::SetForegroundWindow($hwnd)|Out-Null
 Start-Sleep -Milliseconds 1500
 $frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
 $clock=[Diagnostics.Stopwatch]::StartNew();$typed=$null;$retried=$null;$done=$null;$checked=$false;$count=0;$last=0.0;$states=@()
 while($clock.Elapsed.TotalSeconds -lt 45 -and -not($done -and $clock.Elapsed.TotalSeconds -ge $done+2)){
  $count++;$name=('frame-{0:D4}.jpg' -f $count);Shot $window (Join-Path $frames $name) 'jpg'
  $now=$clock.Elapsed.TotalSeconds;if($count -gt 1){$evidence.frames[-1].duration=[Math]::Round($now-$last,3)};$evidence.frames+=@([ordered]@{file=$name;at=[Math]::Round($now,3);duration=0.1});$last=$now
  if(-not$typed){if($now -ge 1.5){$value.SetValue($Search);$typed=$now};continue}
  $state=RowState $window
  if($state -and ($states.Count -eq 0 -or $states[-1].current -cne $state.current -or $states[-1].retry -ne $state.retry)){$states+=@([ordered]@{at=[Math]::Round($now,3);current=$state.current;retry=$state.retry})}
  if(-not$retried -and $now -ge $typed+3){
   $retry=ById $window ($SettingId+'.retry')
   if($retry){$retry.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$states+=@([ordered]@{at=[Math]::Round($now,3);action='retry clicked'})}else{$states+=@([ordered]@{at=[Math]::Round($now,3);action='no retry button'});$done=$now+1}
   $retried=$now;continue
  }
  $final=$state -and $state.current -in "Couldn't check",'Not available here'
  if($retried -and -not$final){$checked=$true}
  if($retried -and -not$done -and $final -and ($checked -or $now -ge $retried+8)){$done=$now}
 }
 if(-not$done){throw ('The row did not settle while recording: '+(($states|ConvertTo-Json -Compress -Depth 5)))}
 $final=RowState $window
 Shot $window (Join-Path $directory ('row-'+$Label+'.png'))
 $evidence.states=$states;$evidence.final=$final
 [RooIndustriesRowCapture]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status='pass'
}finally{
 if($app){Stop-HarnessProcess $app}
 if(Test-Path -LiteralPath $copy){Remove-Item -LiteralPath $copy -Recurse -Force}
 $evidence.status=$status
 Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
 Write-Output ('ROO_INDUSTRIES_ROW_CAPTURE '+$status+' '+$directory)
}
if($status -ne 'pass'){exit 1}
