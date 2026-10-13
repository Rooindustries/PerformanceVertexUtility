param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'desktop-inspection' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'desktop-inspection'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
$state='fail'
try{
 $rows=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{hwnd=$_.Current.NativeWindowHandle;pid=$_.Current.ProcessId;name=$_.Current.Name;class=$_.Current.ClassName;controls=@($_.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;pid=$_.Current.ProcessId;class=$_.Current.ClassName}})}})
 Write-HarnessResult $directory 'windows.json' $rows|Out-Null
 $bounds=[Windows.Forms.SystemInformation]::VirtualScreen
 $bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 $path=Get-HarnessOutputPath $directory 'desktop.png';$stream=[IO.FileStream]::new((Get-HarnessLongPath $path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$graphics.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bitmap.Size);$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose();$stream.Dispose()}
 Register-HarnessFile $path 'screenshot'|Out-Null
 $state='pass'
}finally{Complete-HarnessInvocation $state -Cleanup|Out-Null}
