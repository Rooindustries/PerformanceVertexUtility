param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
$checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Passed,[string]$Name,[string]$Detail=''){$checks.Add(@{passed=$Passed;check=$Name;detail=$Detail});$(if($Passed){'PASS '}else{'FAIL '})+$Name}
$actor=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') -ArgumentList '/d','/c','ping -n 3 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
$owned=New-OwnedProcess $actor
$script:exitedSnapshot=[Diagnostics.Process]::GetProcessById($actor.Id)
try {
    $actor.WaitForExit()
    $exited=$script:exitedSnapshot.HasExited
    function Get-Process {param([int]$Id,[object]$ErrorAction) if($Id -ne $script:exitedSnapshot.Id){throw 'Unexpected forced enumeration PID'};$script:exitedSnapshot}
    $errorText=''
    try {Stop-OwnedProcessIdentity $owned.Identity}catch{$errorText=$_.Exception.Message}
    Check ($errorText -eq '' -and $exited -and $actor.HasExited) 'A native actor exiting after PID enumeration is skipped without a null-handle cleanup failure' $errorText
} finally {Remove-Item -LiteralPath Function:\Get-Process;$script:exitedSnapshot.Dispose();Stop-OwnedProcess $owned;$actor.Dispose()}
$actor=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') -ArgumentList '-n','300','127.0.0.1' -PassThru -WindowStyle Hidden
$owned=New-OwnedProcess $actor
try {
    foreach($kind in @('creation','image')){
        $identity=[pscustomobject]@{pid=$owned.Identity.pid;creationTimeFileTimeUtc=$owned.Identity.creationTimeFileTimeUtc;imagePath=$owned.Identity.imagePath}
        if($kind -eq 'creation'){$identity.creationTimeFileTimeUtc=([long]$identity.creationTimeFileTimeUtc+1).ToString()}else{$identity.imagePath+='-foreign'}
        $refused=$false;try{Stop-OwnedProcessIdentity $identity}catch{$refused=$_.Exception.Message -match 'Process identity changed'}
        Check ($refused -and -not$actor.HasExited) ('A present native actor with different '+$kind+' remains strict and alive')
    }
    Stop-OwnedProcessIdentity $owned.Identity
    Check ($actor.WaitForExit(5000)) 'Only the exact started native identity is stopped'
    Stop-OwnedProcessIdentity $owned.Identity
    Check $true 'An absent native PID is skipped'
} finally {Stop-OwnedProcess $owned;$actor.Dispose()}
$passed=@($checks|Where-Object {-not$_.passed}).Count -eq 0
@{passed=$passed;checks=$checks.ToArray()}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
exit [int](-not$passed)
