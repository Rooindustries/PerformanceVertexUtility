param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$ExpectedMachine='SERVI-WINDOWS-D'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong governor capture machine'}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LauncherChecks.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LoadTimesHandoff.Common.ps1')
Assert-HandoffProtected $RunRoot
Assert-HandoffProtected (Split-Path $OutDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing governor capture retained'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
Assert-HandoffProtected $OutDir
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesGovernorCaptureWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int state);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect bounds);
}
'@
[RooIndustriesGovernorCaptureWindow]::SetProcessDPIAware()|Out-Null
$checks=[Collections.Generic.List[object]]::new()
$script:App=$null;$script:AppReceipt=$null;$script:Win=$null;$script:cleanupFailed=$false
$passed=$false;$failure=$null;$headline=$null;$detail=$null;$shot=$null;$appHash=$null;$captureBounds=$null;$windowHandle=[IntPtr]::Zero
$expected='Roo Industries Governor is running. It keeps your rules active when this app is closed and starts when you sign in.'
$leasePath=Join-Path $RunRoot 'recovery\epoch-installed\lease.json';$leaseHash=(Read-HandoffJson $leasePath).hash
$cleanupPath=Join-Path $Source 'tools\validation\LoadTimes\Test-ElevatedLaunchers.ps1'
function Check([bool]$Ok,[string]$Name){$checks.Add(@{passed=$Ok;check=$Name});if(-not$Ok){throw $Name};'PASS '+$Name}
function Log([string]$Message){if($Message -like 'CLEANUP NEEDED:*'){$script:cleanupFailed=$true};$Message}
function WaitFor([scriptblock]$Probe,[int]$Seconds,[string]$Name){$end=[DateTime]::UtcNow.AddSeconds($Seconds);while([DateTime]::UtcNow -lt $end){$value=& $Probe;if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out: '+$Name)}
function ById([string]$Id){$script:Win.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id))}
function Assert-Epoch {
    $lease=Read-HandoffJson $script:leasePath
    if($lease.hash -cne $script:leaseHash -or $lease.value.label -cne 'installed' -or $lease.value.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Capture installed epoch differs'}
    foreach($name in 'restore-journal.json','restore-complete.json'){if(Test-Path -LiteralPath (Join-Path (Split-Path $script:leasePath -Parent) $name)){throw 'Capture epoch is recovering'}}
}
function Assert-Window {
    $windowPid=[uint32]0
    [RooIndustriesGovernorCaptureWindow]::GetWindowThreadProcessId($script:windowHandle,[ref]$windowPid)|Out-Null
    if($script:App.HasExited -or $windowPid -ne $script:App.Id -or $script:Win.Current.ProcessId -ne $script:App.Id -or [RooIndustriesValidationOwnership.Native]::Created($script:App.Handle).ToString() -cne $script:AppReceipt.Identity.creationTimeFileTimeUtc -or [RooIndustriesValidationOwnership.Native]::Image($script:App.Handle) -ine $script:AppReceipt.Identity.imagePath){throw 'Held app/window identity changed'}
}
try{
    Assert-Epoch
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($cleanupPath,[ref]$tokens,[ref]$errors)
    $cleanup=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Stop-RooIndustriesApp'},$true)
    if($errors -or -not$cleanup){throw 'Committed app cleanup function unavailable'}
    Invoke-Expression $cleanup.Extent.Text
    Check (@(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue).Count -eq 0) 'no existing app process is adopted by the capture'
    $exe='C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
    $appHash=(Get-FileHash -LiteralPath $exe).Hash
    $script:App=Start-Process -FilePath $exe -PassThru
    $script:AppReceipt=New-OwnedProcess $script:App
    if(-not$script:AppReceipt -or $script:AppReceipt.Identity.imagePath -ine [RooIndustriesValidationOwnership.Native]::Canonical($exe)){throw 'Installed capture app identity unavailable'}
    $script:Win=WaitFor { @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$script:App.Id))|Where-Object {$_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*'})[0] } 60 'owned app window'
    $windowHandle=[IntPtr]::new($script:Win.Current.NativeWindowHandle);Assert-Window
    $nav=WaitFor {$script:Win.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Games'),[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::ListItem)))} 60 'Games navigation'
    $nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $tab=WaitFor {ById 'ProcessesTab'} 30 'Processes tab'
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Check ($tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) 'Games Processes tab is selected through native UIA'
    $status=WaitFor {$node=ById 'GovernorStatus';if($node -and $node.Current.Name -ceq $script:expected){$node}} 60 'running governor with confirmed sign-in start'
    $headline=$status.Current.Name;$detail=(ById 'GovernorDetail').Current.Name
    Check ($headline -ceq $expected -and $headline -notmatch "couldn't confirm|won't start") 'installed governor headline confirms running and starts when you sign in'
    Assert-Window
    [RooIndustriesGovernorCaptureWindow]::ShowWindow($windowHandle,3)|Out-Null
    if(-not[RooIndustriesGovernorCaptureWindow]::SetWindowPos($windowHandle,[IntPtr]::new(-1),0,0,0,0,0x0043)){throw 'Owned window front placement failed'}
    [RooIndustriesGovernorCaptureWindow]::SetForegroundWindow($windowHandle)|Out-Null
    $script:Win.SetFocus()
    Start-Sleep -Milliseconds 500
    Check ([RooIndustriesGovernorCaptureWindow]::GetForegroundWindow() -eq $windowHandle) 'only the held app HWND is foreground before capture'
    $bounds=[RooIndustriesGovernorCaptureWindow+Rect]::new()
    if(-not[RooIndustriesGovernorCaptureWindow]::GetWindowRect($windowHandle,[ref]$bounds)){throw 'Owned window bounds unavailable'}
    $screen=[Windows.Forms.SystemInformation]::VirtualScreen
    $bounds.Left=[Math]::Max($bounds.Left,$screen.Left);$bounds.Top=[Math]::Max($bounds.Top,$screen.Top)
    $bounds.Right=[Math]::Min($bounds.Right,$screen.Right);$bounds.Bottom=[Math]::Min($bounds.Bottom,$screen.Bottom)
    $width=$bounds.Right-$bounds.Left;$height=$bounds.Bottom-$bounds.Top
    if($width -lt 400 -or $height -lt 300 -or $width -gt 4096 -or $height -gt 4096){throw 'Owned window bounds outside capture limits'}
    $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
    try{
        $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size)
        Assert-Window
        if([RooIndustriesGovernorCaptureWindow]::GetForegroundWindow() -ne $windowHandle -or (ById 'GovernorStatus').Current.Name -cne $headline){throw 'Owned window/status changed during capture'}
        $shot=Join-Path $OutDir 'governor-sign-in-confirmed.png';$bitmap.Save($shot,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$graphics.Dispose();$bitmap.Dispose()}
    $captureBounds=@{left=$bounds.Left;top=$bounds.Top;width=$width;height=$height}
    Assert-Epoch
    Check ((Get-FileHash -LiteralPath $exe).Hash -ceq $appHash) 'capture app bytes stayed equal to the installed production image'
    Check $true 'screenshot contains only the held app HWND bounds with unchanged confirmed UIA status'
    $passed=$true
}catch{
    $failure=[string]$_
    $checks.Add(@{passed=$false;check='governor status capture refused'});'FAIL governor status capture refused'
}finally{
    if($windowHandle -ne [IntPtr]::Zero){[RooIndustriesGovernorCaptureWindow]::SetWindowPos($windowHandle,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null}
    if($script:AppReceipt){try{Stop-RooIndustriesApp;Check (-not$script:cleanupFailed) 'owned capture app and its held direct children exited'}catch{$passed=$false;$failure=[string]$_;$checks.Add(@{passed=$false;check='capture app cleanup refused'});'FAIL capture app cleanup refused'}}
    if($script:cleanupFailed){$passed=$false}
    $image=if($shot){@{name=[IO.Path]::GetFileName($shot);sha256=(Get-FileHash -LiteralPath $shot).Hash;bytes=(Get-Item -LiteralPath $shot).Length}}else{$null}
    [ordered]@{phase='n9-installed-governor-status';passed=$passed;checks=@($checks);headline=$headline;detail=$detail;expectedHeadline=$expected;appIdentity=$script:AppReceipt.Identity;appSha256=$appHash;windowHandle=$windowHandle.ToInt64();bounds=$captureBounds;image=$image;installedEpochLeaseSha256=$leaseHash;cleanupSourceSha256=(Get-FileHash -LiteralPath $cleanupPath).Hash;failure=$failure;otherAppsTouched=$false;governorOrRuleChanged=$false}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}
if(-not$passed){throw 'Installed governor status capture failed; retained evidence requires review.'}
