param([Parameter(Mandatory=$true)][string]$Work)
$ErrorActionPreference='Stop'
Start-Transcript -Path (Join-Path $Work 'resume-wrapper-output.txt') -Force|Out-Null
$d=Get-Content -LiteralPath (Join-Path $Work 'setup-migration-fixture.json') -Raw|ConvertFrom-Json
[Reflection.Assembly]::LoadFrom((Join-Path $Work 'FixtureHive.dll'))|Out-Null
$p=[Diagnostics.Process]::GetCurrentProcess()
$created=$p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
@{processId=$p.Id;created=$created;executable=$p.MainModule.FileName;commandLine=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)).CommandLine;pointerBits=[IntPtr]::Size*8;cwd=[Environment]::CurrentDirectory;cwdExists=[IO.Directory]::Exists([Environment]::CurrentDirectory)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Work 'resume-wrapper-identity.json') -Encoding UTF8
$diagnostic=Test-Path -LiteralPath (Join-Path $Work 'diagnostic.flag')
$rows=New-Object System.Collections.Generic.List[object]
function CheckCompiler([string]$Phase){
    try {Add-Type -Namespace RooF12Diagnostic -Name ($Phase+'Native') -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", EntryPoint = "GetLongPathNameW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] public static extern uint Expand(string shortPath, System.Text.StringBuilder longPath, uint length);';$rows.Add(@{phase=$Phase;passed=$true;pointerBits=[IntPtr]::Size*8;cwd=[Environment]::CurrentDirectory;cwdExists=[IO.Directory]::Exists([Environment]::CurrentDirectory)})}
    catch {$exceptions=New-Object System.Collections.Generic.List[object];for($e=$_.Exception;$e;$e=$e.InnerException){$exceptions.Add(@{type=$e.GetType().FullName;message=$e.Message;hresult=$e.HResult;nativeError=$e.NativeErrorCode})};$rows.Add(@{phase=$Phase;passed=$false;exceptions=@($exceptions.ToArray());pointerBits=[IntPtr]::Size*8;cwd=[Environment]::CurrentDirectory;cwdExists=[IO.Directory]::Exists([Environment]::CurrentDirectory)})}
}
if($diagnostic){CheckCompiler 'BeforeOverlay'}
$overlay=[SetupMigrationHive]::new((Join-Path $Work ('hives\ps-'+$p.Id+'-'+$created+'.hive')),$d.local)
try {
    if($diagnostic){CheckCompiler 'AfterOverlay';$rows|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Work 'diagnostic-addtype.json');return}
    & (Join-Path $d.repo 'backend\scripts\Invoke-GovernorSetup.ps1') -Action Resume -AppRoot $d.repo -StatePath (Join-Path $Work 'setup-state.json') -LogPath (Join-Path $Work 'resume.log')
}
catch {$_|Out-String|Set-Content -LiteralPath (Join-Path $Work 'resume-wrapper-error.txt');throw}
finally {$overlay.Dispose();Stop-Transcript|Out-Null}
