param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$id=[Guid]::NewGuid().ToString('N')
$work=Join-Path $OutDir ('fixture-'+$id)
New-Item -ItemType Directory -Path $work|Out-Null
$rows=New-Object System.Collections.Generic.List[object]
function Check([bool]$Passed,[string]$Check,[string]$Detail=''){$rows.Add([pscustomobject]@{passed=$Passed;check=$Check;detail=$Detail});$(if($Passed){'PASS '}else{'FAIL '})+$Check+' '+$Detail}
function Literal([string]$Text){"'"+$Text.Replace("'","''")+"'"}
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$other='S-1-5-18'
$names=@(('RooIndustries_ResumeFixture_'+$id+'_current'),('RooIndustries_ResumeFixture_'+$id+'_other'))
$created=New-Object System.Collections.Generic.List[string]
$scriptPath=Join-Path $Source 'backend\scripts\Invoke-GovernorSetup.ps1'
try {
    $records=@()
    for($index=0;$index -lt 2;$index++){
        if(Get-ScheduledTask -TaskName $names[$index] -ErrorAction SilentlyContinue){throw 'Fixture task already exists'}
        $sid=if($index -eq 0){$me}else{$other}
        $probe=Join-Path $work ('probe-'+$index+'.ps1')
        [IO.File]::WriteAllText($probe,('[IO.File]::WriteAllText('+(Literal (Join-Path $work ('ran-'+$index+'.txt')))+',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)'),[Text.UTF8Encoding]::new($false))
        $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$probe+'"')
        $principal=if($index -eq 0){New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest}else{New-ScheduledTaskPrincipal -UserId $sid -LogonType ServiceAccount -RunLevel Highest}
        Register-ScheduledTask -TaskName $names[$index] -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet) -Description ('Resume fixture '+$id) |Out-Null
        $created.Add($names[$index]);Disable-ScheduledTask -TaskName $names[$index]|Out-Null
        $records+=@{taskName=$names[$index];taskPath='\';description=('Resume fixture '+$id);userSid=$sid;policyRoot=(Join-Path $work ('rules-'+$index));enabled=$true;wasRunning=$false;trusted=$true}
    }
    $state=Join-Path $work 'records.json';[IO.File]::WriteAllText($state,($records|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $sourceText=[IO.File]::ReadAllText($scriptPath)
    $needle='switch($Action){'
    if(([regex]::Matches($sourceText,[regex]::Escape($needle))).Count -ne 1){throw 'The Resume provider seam is not unique'}
    $seam='function Get-GovernorTasks {foreach($row in @((Get-Content -LiteralPath '+(Literal $state)+' -Raw|ConvertFrom-Json))){$row}}'+"`n"+'function Get-RooIndustriesLocalDataRoot {throw ''fixture: this Windows user has a damaged marked data root''}'+"`n"
    $copy=Join-Path $work 'Invoke-GovernorSetup.ps1'
    [IO.File]::WriteAllText($copy,$sourceText.Replace($needle,$seam+$needle),[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1') -Destination $work
    $log=Join-Path $OutDir 'resume.log'
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$copy+'" -Action Resume -AppRoot "'+$work+'" -StatePath "'+$state+'" -LogPath "'+$log+'"'))
    $start.UseShellExecute=$false;$start.RedirectStandardError=$true;$start.RedirectStandardOutput=$true
    $child=[Diagnostics.Process]::Start($start)
    try {$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();if(-not $child.WaitForExit(30000)){$child.Kill();throw 'Resume fixture timed out'};$text=$stdout.Result+"`n"+$stderr.Result;[IO.File]::WriteAllText((Join-Path $OutDir 'native.log'),$text,[Text.UTF8Encoding]::new($false));$exit=$child.ExitCode}finally{$child.Dispose()}
    Check ($exit -eq 2) 'Resume reports a per-user failure with exit 2' ('exit='+$exit)
    $enabled=[string](Get-ScheduledTask -TaskName $names[1]).State -ne 'Disabled'
    Check $enabled 'Resume continues and enables the other Windows user''s exact task'
    if($enabled){Start-ScheduledTask -TaskName $names[1];$clock=[Diagnostics.Stopwatch]::StartNew();while(-not (Test-Path -LiteralPath (Join-Path $work 'ran-1.txt')) -and $clock.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 100}}
    Check ((Test-Path -LiteralPath (Join-Path $work 'ran-1.txt')) -and [IO.File]::ReadAllText((Join-Path $work 'ran-1.txt')) -ceq $other) 'The resumed native task runs as the other Windows principal'
    $detail=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
    Check ($detail.Contains($me) -and $detail.Contains('damaged marked data root') -and $detail.Contains('Setup recovery stays registered')) 'The log names the failing SID, cause and recovery decision' $detail
    [pscustomobject]@{sourceSha256=(Get-FileHash -LiteralPath $scriptPath).Hash;generatedSha256=(Get-FileHash -LiteralPath $copy).Hash;seam='only data-root and task-enumeration providers; Resume and Windows Task Scheduler are real'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutDir 'source-proof.json') -Encoding UTF8
} finally {
    foreach($name in $created){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){if($task.Description -cne ('Resume fixture '+$id)){throw 'Fixture cleanup refused a changed task'};Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false}}
    Remove-Item -LiteralPath $work -Recurse -Force
    $rows|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}
Check (-not (Test-Path -LiteralPath $work) -and @($names|Where-Object {Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue}).Count -eq 0) 'The native user/task fixtures are removed'
$rows|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
if(@($rows|Where-Object {-not $_.passed}).Count){exit 1}
