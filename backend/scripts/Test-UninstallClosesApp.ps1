$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
function Check([bool]$Passed,[string]$Message){if(-not $Passed){throw $Message};Write-Output ('PASS '+$Message)}
# Uninstall cleanup (Invoke-ProtectedGameSession.ps1 -Action RemoveAll) closes the app and the helpers it runs its scripts with,
# and leaves alone programs the user opened from it. A disposable install folder holds a stand-in app that starts a PowerShell
# helper, a helper inside the install folder and a tool outside it.
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Output 'SKIP Uninstall cleanup needs administrator rights';return}
$hostDirectory=Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\optimizer'
if(-not (Test-Path -LiteralPath (Join-Path $hostDirectory 'Optimizer.Host.dll'))){Write-Output 'SKIP The native helper is not built; run Build-OptimizerHost.ps1 first';return}
$base=Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp') ('roo-industries-uninstall-close-'+[Guid]::NewGuid().ToString('N'))
$install=Join-Path $base 'install';$outside=Join-Path $base 'tool';$operations=Join-Path $base 'operations'
# Each process is held open while the check runs, so its number can't go to another program before cleanup.
$held=[Collections.Generic.List[Diagnostics.Process]]::new()
try{
    foreach($folder in (Join-Path $install 'backend\scripts'),(Join-Path $install 'app'),$outside,$operations){[IO.Directory]::CreateDirectory($folder)|Out-Null}
    foreach($script in 'Invoke-ProtectedGameSession.ps1','BrandCompatibility.Common.ps1'){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination (Join-Path $install ('backend\scripts\'+$script))}
    $standIn=Join-Path $base 'stand-in.exe'
    Add-Type -OutputType ConsoleApplication -OutputAssembly $standIn -TypeDefinition @'
using System; using System.Diagnostics; using System.IO;
public static class StandIn {
    static void Start(string file, string arguments) { Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true }); }
    public static void Main(string[] args) {
        if (args.Length == 1 && args[0] == "wait") { System.Threading.Thread.Sleep(600000); return; }
        Start(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 600");
        Start(args[0], "wait");
        Start(args[1], "wait");
        File.WriteAllText(args[2], "ready");
        System.Threading.Thread.Sleep(600000);
    }
}
'@
    $app=Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe';$helper=Join-Path $install 'app\stand-in-helper.exe';$tool=Join-Path $outside 'stand-in-tool.exe'
    foreach($copy in $app,$helper,$tool){Copy-Item -LiteralPath $standIn -Destination $copy}
    $ready=Join-Path $base 'ready.txt'
    $process=Start-Process -FilePath $app -ArgumentList @('"'+$helper+'"','"'+$tool+'"','"'+$ready+'"') -WindowStyle Hidden -PassThru
    $null=$process.Handle;$held.Add($process)
    $deadline=[DateTime]::UtcNow.AddSeconds(30);while(-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
    Check (Test-Path -LiteralPath $ready) 'The stand-in app started its helpers and the tool'
    function Hold($Child){
        if(-not $Child){return $null}
        try{$open=[Diagnostics.Process]::GetProcessById([int]$Child.ProcessId);$null=$open.Handle}catch{return $null}
        if([Math]::Abs(($open.StartTime-$Child.CreationDate).TotalSeconds) -ge 1){$open.Dispose();return $null}
        $held.Add($open);return $open
    }
    $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$process.Id))
    $shell=Hold @($children|Where-Object {$_.Name -eq 'powershell.exe'})[0];$inside=Hold @($children|Where-Object {$_.ExecutablePath -ieq $helper})[0];$outsideTool=Hold @($children|Where-Object {$_.ExecutablePath -ieq $tool})[0]
    Check ($shell -and $inside -and $outsideTool) 'The stand-in app has a PowerShell helper, a helper in its install folder and a tool outside it'
    $output=@(& (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $install 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action RemoveAll -OperationsRoot $operations -HostDirectory $hostDirectory -ConfirmApply) -join "`n"
    $exit=$LASTEXITCODE
    $result=$output|ConvertFrom-Json
    Check ($exit -eq 0 -and $result.status -eq 'completed') ('Uninstall cleanup completes (exit '+$exit+': '+(@($result.data.sessions)|ConvertTo-Json -Compress -Depth 5)+')')
    Check ($process.WaitForExit(15000)) 'Uninstall cleanup closes the app'
    Check ($shell.WaitForExit(15000) -and $inside.WaitForExit(15000)) 'It closes the PowerShell helper the app started and the helper in its install folder'
    Check (-not $outsideTool.HasExited) 'It leaves a program the user opened from the app running'
}
finally{
    foreach($open in $held){try{if(-not $open.HasExited){$open.Kill();[void]$open.WaitForExit(15000)}}catch{};$open.Dispose()}
    if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}
}
Check (-not (Test-Path -LiteralPath $base)) 'Uninstall cleanup check removes its folder'
