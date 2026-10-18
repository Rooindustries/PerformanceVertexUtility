param([Parameter(Mandatory=$true)][string]$Name,[string]$Click='',[string]$Page='Games',[int]$SettleSeconds=6)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../LoadTimes/CleanupOwnership.Common.ps1')
$script:AppReceipt=$null
$ProgressPreference='SilentlyContinue'
$W=Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-governor-ui'
[IO.Directory]::CreateDirectory($W)|Out-Null
$Exe='C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesGovernorUser32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
}
'@
[RooIndustriesGovernorUser32]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope]
$log=Join-Path $W ('ui-'+$Name+'.txt')
function Log([string]$m){Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')+'Z '+$m);$m}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=(Get-Date).AddSeconds($seconds);while((Get-Date) -lt $deadline){try{$r=& $probe}catch{$r=$null};if($r){return $r};Start-Sleep -Milliseconds 200};throw "Timed out waiting for $what"}
function ById($root,$id){$root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function ByNameType($root,$name,$type){$root.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$type)))}
function Invoke-Element($e){try{$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}catch{$e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}}
function Shot([string]$n){$bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$b=New-Object Drawing.Bitmap $bounds.Width,$bounds.Height;$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$b.Size);$f=Join-Path $W ('shot-'+$n+'.png');$b.Save($f,[Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$b.Dispose();Log ('screenshot '+$f)}
function Start-GovernorCaptureApp {
    Stop-GovernorCaptureApp
    $script:App=Start-Process $Exe -PassThru
    $script:AppReceipt=New-OwnedProcess $script:App
}
function Stop-GovernorCaptureApp {
    Stop-OwnedValidationApp $script:App $script:AppReceipt
}
$app=$null
try {
    [RooIndustriesGovernorUser32]::mouse_event(1,3,0,0,[IntPtr]::Zero);Start-Sleep -Milliseconds 200;[RooIndustriesGovernorUser32]::mouse_event(1,-3,0,0,[IntPtr]::Zero)
    Start-GovernorCaptureApp
    $win=WaitFor {@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))|Where-Object {$_.Current.NativeWindowHandle -ne 0 -and ($_.Current.Name -like 'Performance Vertex Utility*' -or $_.Current.Name -like 'Roo Industries*')})[0]} 120 'main window'
    $h=[IntPtr]::new($win.Current.NativeWindowHandle);[RooIndustriesGovernorUser32]::ShowWindow($h,3)|Out-Null;[RooIndustriesGovernorUser32]::SetForegroundWindow($h)|Out-Null
    $nav=WaitFor {ByNameType $win $Page ([Windows.Automation.ControlType]::ListItem)} 60 ('nav '+$Page)
    Invoke-Element $nav
    if($Page -eq 'Games'){
        $tab=WaitFor {ById $win 'ProcessesTab'} 60 'Processes tab'
        Invoke-Element $tab
        $status=WaitFor {$e=ById $win 'GovernorStatus';if($e -and $e.Current.Name -and $e.Current.Name -notlike 'Checking*'){$e}} 60 'governor status'
        Start-Sleep -Seconds $SettleSeconds
        if($Click){
            $button=WaitFor {$e=ById $win $Click;if($e -and $e.Current.IsEnabled){$e}} 30 ('enabled '+$Click)
            Log ('click '+$Click)
            Invoke-Element $button
            WaitFor {$e=ById $win $Click;$e -and -not $e.Current.IsEnabled} 10 'busy' |Out-Null
            WaitFor {$s=ById $win 'ProcessStatus';$s -and $s.Current.Name -match 'Governor (paused|started)|needs attention'} 120 'governor action result'|Out-Null
            Start-Sleep -Seconds $SettleSeconds
        }
        $texts=@($win.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::Text))|ForEach-Object {$_.Current.Name}|Where-Object {$_ -match 'Governor|Wanted:|Now:|rule'})
        Log ('GovernorStatus: '+(ById $win 'GovernorStatus').Current.Name)
        Log ('GovernorDetail: '+(ById $win 'GovernorDetail').Current.Name)
        Log ('Pause enabled: '+(ById $win 'GovernorPause').Current.IsEnabled+'; Start enabled: '+(ById $win 'GovernorStart').Current.IsEnabled)
        Log ('ProcessStatus: '+(ById $win 'ProcessStatus').Current.Name+' | '+(ById $win 'ProcessDetail').Current.Name)
        Log ('Card texts: '+($texts -join ' || '))
    } else {
        Start-Sleep -Seconds ([Math]::Max($SettleSeconds,8))
        $texts=@($win.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,[Windows.Automation.ControlType]::Text))|ForEach-Object {$_.Current.Name}|Where-Object {$_})
        Log ('Page texts: '+($texts -join ' || '))
    }
    Shot $Name
} catch { Log ('ERROR '+($_|Out-String)) ; try {Shot ($Name+'-error')} catch {} }
finally {
    try {Stop-GovernorCaptureApp} catch {Log ('CLEANUP NEEDED: '+$_.Exception.Message)}
    Get-Content -LiteralPath $log
}
