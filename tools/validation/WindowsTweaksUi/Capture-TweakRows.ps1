param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label,[Parameter(Mandatory)][string]$Searches,[Parameter(Mandatory)][string]$SettingIds)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('tweak-rows-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('tweak-rows-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesRowsCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesRowsCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope]
$terms=@($Searches.Split(';')|ForEach-Object {$_.Trim()}|Where-Object {$_})
$ids=@($SettingIds.Split(',')|ForEach-Object {$_.Trim()}|Where-Object {$_})
$evidence=[ordered]@{label=$Label;searches=$terms;settingIds=$ids;frames=@();rows=[ordered]@{}}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function ById($Root,[string]$Id){$Root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Current($Window,[string]$Id){
 $item=ById $Window ($Id+'.details');if(-not$item){return $null}
 $walker=[Windows.Automation.TreeWalker]::ControlViewWalker
 while($item -and $item.Current.ControlType -ne [Windows.Automation.ControlType]::ListItem){$item=$walker.GetParent($item)}
 if(-not$item){return $null}
 $text=@($item.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::Text))|ForEach-Object {$_.Current.Name}|Where-Object {$_ -like '*: current value *'}|Select-Object -First 1)
 if(-not$text.Count){return $null}
 return $text[0].Substring($text[0].IndexOf(': current value ')+16)
}
function Shot($Window,[string]$Path,[string]$Format='png'){
 $r=$Window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save($Path,$(if($Format -eq 'png'){[Drawing.Imaging.ImageFormat]::Png}else{[Drawing.Imaging.ImageFormat]::Jpeg}))}finally{$graphics.Dispose();$bitmap.Dispose()}
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $env:ROO_INDUSTRIES_INITIAL_NAV='windows';$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid))} 120 'the Suite window'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 $search=WaitFor {ById $window 'WindowsTweaksSearch'} 120 'the Windows tweaks page'
 WaitFor {ById $window 'WindowsTweaksList'} 120 'the Windows tweaks list'|Out-Null
 $advanced=WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'Show advanced options'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::CheckBox)))} 60 'the advanced options switch'
 $toggle=$advanced.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
 $value=$search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
 $value.SetValue($terms[0])
 WaitFor {$first=Current $window $ids[0];$first -and $first -notlike 'Checking*' -and $first -ne 'Not checked'} 240 'the first row to finish loading'|Out-Null
 $value.SetValue('')
 [RooIndustriesRowsCapture]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesRowsCapture]::SetForegroundWindow($hwnd)|Out-Null
 Start-Sleep -Milliseconds 1500
 $frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
 $clock=[Diagnostics.Stopwatch]::StartNew();$count=0;$last=0.0
 function Frame{$script:count++;$name=('frame-{0:D4}.jpg' -f $script:count);Shot $window (Join-Path $frames $name) 'jpg';$now=$clock.Elapsed.TotalSeconds;if($script:count -gt 1){$evidence.frames[-1].duration=[Math]::Round($now-$script:last,3)};$evidence.frames+=@([ordered]@{file=$name;at=[Math]::Round($now,3);duration=0.1});$script:last=$now}
 for($index=0;$index -lt $terms.Count;$index++){
  $start=$clock.Elapsed.TotalSeconds
  while($clock.Elapsed.TotalSeconds -lt $start+1){Frame}
  $value.SetValue($terms[$index])
  $shown=$null
  while($clock.Elapsed.TotalSeconds -lt $start+60){
   Frame
   $visible=@($ids|ForEach-Object {[pscustomobject]@{id=$_;current=(Current $window $_)}}|Where-Object {$_.current})
   if($visible.Count -and @($visible|Where-Object {$_.current -like 'Checking*' -or $_.current -eq 'Not checked'}).Count -eq 0){if(-not$shown){$shown=$clock.Elapsed.TotalSeconds};if($clock.Elapsed.TotalSeconds -ge $shown+2){break}}
  }
  if(-not$shown){throw ('No listed row settled for search: '+$terms[$index])}
  foreach($row in $visible){$evidence.rows[$row.id]=$row.current}
  Shot $window (Join-Path $directory ('rows-'+$Label+'-'+($index+1)+'.png'))
 }
 Frame
 $missing=@($ids|Where-Object {-not$evidence.rows.Contains($_)})
 if($missing.Count){throw ('Rows never shown: '+($missing -join ', '))}
 [RooIndustriesRowsCapture]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status='pass'
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
  Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
  Write-Output ('ROO_INDUSTRIES_ROWS_CAPTURE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
