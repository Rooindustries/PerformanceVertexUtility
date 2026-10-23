param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('restart-check-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('restart-check-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesRestartCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesRestartCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$evidence=[ordered]@{label=$Label;frames=@();states=@()}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function ById($Root,[string]$Id){$Root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function ByName($Root,[string]$Name,$Type){$Root.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$Name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$Type)))}
function PageState($Window){
 $review=ByName $Window 'Review recovery' $CT::Button;$apply=ById $Window 'WindowsTweaksApply'
 return [ordered]@{status=(ById $Window 'WindowsTweaksStatus').Current.Name;detail=(ById $Window 'WindowsTweaksDetail').Current.Name;reviewRecovery=[bool]($review -and -not$review.Current.IsOffscreen);applyLabel=$(if($apply){@($apply.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name}) -join ' '})}
}
function Shot($Window,[string]$Path,[string]$Format='png'){
 $r=$Window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save($Path,$(if($Format -eq 'png'){[Drawing.Imaging.ImageFormat]::Png}else{[Drawing.Imaging.ImageFormat]::Jpeg}))}finally{$graphics.Dispose();$bitmap.Dispose()}
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$parent='Software\RooIndustriesTweakTests';$fixture=$parent+'\'+[Guid]::NewGuid().ToString('N');$recovery=$fixture+'\Recovery'
$parentExisted=Test-Path -LiteralPath ('HKCU:\'+$parent)
$states=Join-Path $directory 'feature-states.json'
$app=$null;$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 [IO.File]::WriteAllText($states,'{"HypervisorPlatform":2,"VirtualMachinePlatform":2}',[Text.UTF8Encoding]::new($false))
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 & $dotnet run --project (Join-Path $Source 'tools\validation\Tweaks\Tweaks.csproj') --configuration Release --disable-build-servers -p:UseSharedCompilation=false -- $Source --seed-feature-restart $recovery $states *>> $build
 $evidence.seed=@(Get-Content -LiteralPath $build|Where-Object {$_ -like 'ROO_INDUSTRIES_FEATURE_SEED *'})
 if($LASTEXITCODE -ne 0 -or -not$evidence.seed.Count){throw 'Seeding the pending feature record failed; see build.log.'}
 $env:ROO_INDUSTRIES_TEST_TWEAK_RECOVERY=$recovery;$env:ROO_INDUSTRIES_TEST_FEATURE_STATES=$states;$env:ROO_INDUSTRIES_INITIAL_NAV='windows';$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid))} 120 'the Suite window'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 $evidence.loaded=WaitFor {$state=PageState $window;if($state.status -eq 'Restart required to finish Windows settings recovery' -and $state.reviewRecovery){$state}} 300 'the pending restart record to load'
 [RooIndustriesRestartCapture]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesRestartCapture]::SetForegroundWindow($hwnd)|Out-Null
 Start-Sleep -Milliseconds 1500
 Shot $window (Join-Path $directory ('pending-'+$Label+'.png'))
 $frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
 $clock=[Diagnostics.Stopwatch]::StartNew();$reviewed=$null;$approved=$null;$checked=$null;$done=$null;$count=0;$last=0.0
 while($clock.Elapsed.TotalSeconds -lt 240 -and -not($done -and $clock.Elapsed.TotalSeconds -ge $done+3)){
  $count++;$name=('frame-{0:D4}.jpg' -f $count);Shot $window (Join-Path $frames $name) 'jpg'
  $now=$clock.Elapsed.TotalSeconds;if($count -gt 1){$evidence.frames[-1].duration=[Math]::Round($now-$last,3)};$evidence.frames+=@([ordered]@{file=$name;at=[Math]::Round($now,3);duration=0.1});$last=$now
  if(-not$reviewed){if($now -ge 1.5){(ByName $window 'Review recovery' $CT::Button).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$reviewed=$now;$evidence.states+=@([ordered]@{at=[Math]::Round($now,3);action='review recovery'})};continue}
  if(-not$approved){if($now -ge $reviewed+1.5){$box=(ById $window 'WindowsTweaksApproval').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if($box.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$box.Toggle()};$approved=$now;$evidence.states+=@([ordered]@{at=[Math]::Round($now,3);action='approve'})};continue}
  if(-not$checked){if($now -ge $approved+1.5){$apply=ById $window 'WindowsTweaksApply';$evidence.states+=@([ordered]@{at=[Math]::Round($now,3);action='check restart completion';page=(PageState $window)});$apply.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$checked=$now};continue}
  if(-not$done){
   $state=PageState $window
   if($state.status -eq 'Settings were not confirmed' -or $state.detail -like "Windows undid these feature changes*"){$done=$now;$evidence.states+=@([ordered]@{at=[Math]::Round($now,3);action='settled';page=$state})}
  }
 }
 if(-not$done){throw ('The restart check did not settle while recording: '+((PageState $window)|ConvertTo-Json -Compress))}
 Start-Sleep -Milliseconds 500
 $evidence.final=PageState $window
 Shot $window (Join-Path $directory ('result-'+$Label+'.png'))
 [RooIndustriesRestartCapture]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status='pass'
}finally{
 if($app){Stop-HarnessProcess $app}
 if(Test-Path -LiteralPath ('HKCU:\'+$fixture)){Remove-Item -LiteralPath ('HKCU:\'+$fixture) -Recurse -Force}
 if(-not$parentExisted -and (Test-Path -LiteralPath ('HKCU:\'+$parent))){$left=Get-Item -LiteralPath ('HKCU:\'+$parent);if($left.SubKeyCount -eq 0 -and $left.ValueCount -eq 0){Remove-Item -LiteralPath ('HKCU:\'+$parent) -Force}}
 $evidence.fixtureRemoved=-not(Test-Path -LiteralPath ('HKCU:\'+$fixture))
 $evidence.status=$status
 Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
 Write-Output ('ROO_INDUSTRIES_RESTART_CAPTURE '+$status+' '+$directory)
}
if($status -ne 'pass' -or -not$evidence.fixtureRemoved){exit 1}
