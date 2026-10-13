param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'tour-preflight' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
try{
 Add-Type -AssemblyName System.Drawing,System.Windows.Forms
 Add-Type -Path (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Tour\TourCapture.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms
 [RooTour.Desktop]::SetProcessDPIAware()|Out-Null
 $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea;$ffmpeg=Get-Command ffmpeg -ErrorAction SilentlyContinue
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';sessionId=(Get-Process -Id $PID).SessionId;workArea=$area.ToString();width=$area.Width;height=$area.Height;ffmpeg=if($ffmpeg){$ffmpeg.Source}else{$null};nativeCaptureCompiled=$true}|Out-Null
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
}catch{Complete-HarnessInvocation 'fail' -Cleanup|Out-Null;throw}
