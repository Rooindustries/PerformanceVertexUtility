param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label,[ValidateSet('any','plain')][string]$Expect='plain')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('undo-changes-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('undo-changes-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesUndoCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out Rect value,int size);
}
'@
[RooIndustriesUndoCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$expected=@('Undo changes','See what this app changed on your PC and where to undo it.','Open Games','Open Windows tweaks','Open BIOS backups','What you can undo','Game priority','Background limits','Automatic app rules','Windows tweaks','Undo Windows changes in Windows tweaks, and game or app changes in Games.')
$jargon=@('overnor','No rules','restorable','Reversible','restraint','Restrained','Status unavailable','Backed up','session backup','recovery state','needs recovery','Interrupted change','verification','readback','requested controls','Partially applied','Recovery required','needs attention','value changes','selected settings','No active profile','Review profile','saved profiles','Saved settings','stepped back','kept by the governor','could not','process settings','file-permissions-','restore-point-','AboveNormal','BelowNormal','RealTime','0x',[string][char]0x2014)
$evidence=[ordered]@{label=$Label;expect=$Expect;texts=@();buttons=@();checkBoxes=@();missing=@();jargon=@()}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function Names($Root,$Type){@($Root.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$Type))|ForEach-Object {$_.Current.Name}|Where-Object {$_})}
function Shot($Window,[string]$Path){
 $r=[RooIndustriesUndoCapture+Rect]::new()
 $b=$Window.Current.BoundingRectangle
 if([RooIndustriesUndoCapture]::DwmGetWindowAttribute([IntPtr]::new([long]$Window.Current.NativeWindowHandle),9,[ref]$r,16) -eq 0){$x=$r.Left;$y=$r.Top;$w=$r.Right-$r.Left;$h=$r.Bottom-$r.Top}else{$x=[int]$b.X;$y=[int]$b.Y;$w=[int]$b.Width;$h=[int]$b.Height}
 $bitmap=[Drawing.Bitmap]::new($w,$h);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen($x,$y,0,0,$bitmap.Size);$bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
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
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:ROO_INDUSTRIES_INITIAL_NAV='restore'
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and (Names $w $CT::Button) -contains 'Open Windows tweaks'){$w}} 180 'the Undo changes page'
 WaitFor {$t=Names $window $CT::Text;if(($t -contains 'What you can undo' -or $t -contains 'Saved settings') -and ($t -contains 'Automatic app rules' -or $t -contains 'Governor') -and ($t -notcontains 'Checking what you can undo') -and ($t -notcontains 'Reading restore state')){$t}} 120 'the Undo changes rows to finish loading'|Out-Null
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 [RooIndustriesUndoCapture]::SetWindowPos($hwnd,[IntPtr]::new(-1),40,40,1280,960,0x0040)|Out-Null
 [RooIndustriesUndoCapture]::SetForegroundWindow($hwnd)|Out-Null
 Start-Sleep -Seconds 3
 $evidence.texts=@(Names $window $CT::Text)
 $evidence.buttons=@(Names $window $CT::Button)
 $evidence.checkBoxes=@(Names $window $CT::CheckBox)
 Shot $window (Join-Path $directory ('undo-changes-'+$Label+'.png'))
 [RooIndustriesUndoCapture]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $shown=@($evidence.texts)+@($evidence.buttons)
 $evidence.missing=@($expected|Where-Object {$shown -notcontains $_})
 $evidence.jargon=@(foreach($text in $shown){foreach($word in $jargon){if($text.Contains($word)){$word+' in: '+$text}}})
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 if($Expect -eq 'plain'){
  if($evidence.missing.Count){throw ('Undo changes is missing plain labels: '+($evidence.missing -join ' | '))}
  if($evidence.jargon.Count){throw ('Undo changes shows developer wording: '+($evidence.jargon -join ' | '))}
  if($evidence.checkBoxes.Count){throw ('Undo changes shows a confirmation checkbox: '+($evidence.checkBoxes -join ' | '))}
 }
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
  Write-Output ('ROO_INDUSTRIES_UNDO_CAPTURE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
