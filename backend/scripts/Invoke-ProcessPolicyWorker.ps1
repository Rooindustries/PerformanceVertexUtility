param(
    [Parameter(Mandatory=$true)][ValidateSet('Status','Sync','Pause','Resume','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$PolicyRoot,
    [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,
    [string]$HostDirectory='',
    [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
try {
if($Action -ne 'Status' -and -not $ConfirmApply){throw 'Confirm the governor operation before changing it.'}
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$PolicyRoot=[IO.Path]::GetFullPath($PolicyRoot)
$owner=Get-RooIndustriesOperationOwner
$hash=[Security.Cryptography.SHA256]::Create()
try {$suffix=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($owner.userSid+'|'+$PolicyRoot.ToUpperInvariant())))).Replace('-','').Substring(0,20)}
finally {$hash.Dispose()}
$taskName='RooIndustriesOptimizationSuite.ProcessRules.'+$suffix
$description='Roo Industries process rules | '+$owner.userSid+' | '+$PolicyRoot
if(-not $HostDirectory){$HostDirectory=Join-Path $repoRoot 'backend\bin\optimizer'}
$hostDll=Join-Path $HostDirectory 'Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostDll)){throw 'Build the policy worker with Build-OptimizerHost.ps1 before starting saved rules.'}
$hostArgs=@($hostDll)
if(Test-Path -LiteralPath (Join-Path $HostDirectory 'hostpolicy.dll')){$DotNetPath=Join-Path $HostDirectory 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){$DotNetPath=Get-RooIndustriesDevelopmentDotNet $HostDirectory}
$DotNetPath=[IO.Path]::GetFullPath($DotNetPath)
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$requestPath=Join-Path $PolicyRoot 'worker-request.json'
$task=Find-RooIndustriesCompatibleTask $taskName ($script:RooIndustriesLegacyIdentity.policyTask+$suffix) $description ($script:RooIndustriesLegacyIdentity.policyDescription+$owner.userSid+' | '+$PolicyRoot)
if($task){$taskName=$task.TaskName;$description=$task.Description}

$OutputEncoding=[Text.UTF8Encoding]::new($false)
function Invoke-Core([string]$CoreAction,[object]$Extra=@{}) {
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$PolicyRoot;confirm=$true}
    foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
    $text=@(($request|ConvertTo-Json -Depth 32 -Compress)|& $DotNetPath @hostArgs $CoreAction '-') -join "`n"
    $exitCode=$LASTEXITCODE
    if([string]::IsNullOrWhiteSpace($text)){throw ($CoreAction+' failed (exit '+$exitCode+'): the helper returned no output.')}
    try {$result=$text|ConvertFrom-Json} catch {throw ($CoreAction+' failed (exit '+$exitCode+'): the helper returned '+$text.Substring(0,[Math]::Min(300,$text.Length)))}
    if($exitCode -ne 0 -or $result.status -ne 'completed'){throw ($CoreAction+' failed (exit '+$exitCode+'): '+$result.error.message)}
    return $result.data
}

function Stop-Worker {
    $status=Invoke-Core 'policy-status'
    if($null -eq $status.hostRunning){throw ('Governor identity could not be verified: '+$status.error)}
    if($status.hostRunning){
        $target=$status.state.host
        $same={param($Live) $Live.hostRunning -eq $true -and $Live.state.host.processId -eq $target.processId -and [string]$Live.state.host.creationTimeFileTimeUtc -eq [string]$target.creationTimeFileTimeUtc}
        Invoke-Core 'policy-stop'|Out-Null
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 200
            $status=Invoke-Core 'policy-status'
            if($null -eq $status.hostRunning){throw ('Governor shutdown could not be verified: '+$status.error)}
        } while((& $same $status) -and $clock.Elapsed.TotalSeconds -lt 30)
        if(& $same $status){
            $process=Get-Process -Id $target.processId -ErrorAction SilentlyContinue
            if($process -and $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq [string]$target.creationTimeFileTimeUtc){$process.Kill();$process.WaitForExit(10000)|Out-Null}
            $status=Invoke-Core 'policy-status'
            if($null -eq $status.hostRunning -or (& $same $status)){throw 'The governor did not stop. Its recovery state was preserved.'}
        }
    }
    Restore-Interrupted $status
}

function Restore-Interrupted($Status) {
    if($Status.state -and $Status.state.status -notin @('stopped','stoppedWithConflicts') -and (Invoke-Core 'policy-summary').secured){
        for($attempt=1;;$attempt++){
            try {Invoke-Core 'policy-run' @{durationSeconds=0}|Out-Null;return}
            catch {
                $live=Invoke-Core 'policy-status'
                if($live.hostRunning -eq $true){return}
                if($attempt -ge 3){throw}
                Start-Sleep -Milliseconds 400
            }
        }
    }
}

function Get-GovernorTask {return Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}

function Register-Governor([switch]$Disabled) {
    $admin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){throw 'Saved rules need administrator rights. Open the app as an administrator and try again.'}
    Write-RooIndustriesOperationJson @{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$PolicyRoot;confirm=$true} $requestPath
    $execute=New-RooIndustriesElevatedTaskAction $DotNetPath (@($hostArgs)+@('policy-run',$requestPath)) $HostDirectory
    $principal=New-ScheduledTaskPrincipal -UserId $owner.userSid -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6
    $settings.Enabled=-not $Disabled
    $clock=New-ScheduledTaskTrigger -Once -At ([DateTime]::Now) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $logon=New-ScheduledTaskTrigger -AtLogOn -User $owner.userSid
    $logon.Repetition=$clock.Repetition
    Register-ScheduledTask -TaskName $taskName -Description $description -Action $execute -Principal $principal -Settings $settings -Trigger @($logon,$clock) -Force|Out-Null
}

function Start-Governor {
    $status=Invoke-Core 'policy-status'
    if($status.hostRunning -eq $true -and $status.error){
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {Start-Sleep -Milliseconds 500;$status=Invoke-Core 'policy-status'}while($status.hostRunning -eq $true -and $status.error -and $clock.Elapsed.TotalSeconds -lt 8)
    }
    if($status.hostRunning -eq $true -and -not $status.error){return}
    if($status.hostRunning -eq $true){Stop-Worker}
    Start-ScheduledTask -TaskName $taskName
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {$status=Invoke-Core 'policy-status';if($status.hostRunning -eq $true){break};Start-Sleep -Milliseconds 200}while($clock.Elapsed.TotalSeconds -lt 20)
    if($status.hostRunning -ne $true){
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        throw ('The governor did not start. Task result: '+$info.LastTaskResult+'. '+$status.error)
    }
}

function Remove-Governor {
    if(Get-GovernorTask){Disable-ScheduledTask -TaskName $taskName|Out-Null}
    Stop-Worker
    if(Get-GovernorTask){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
}

function Sync-Governor {
    if((Test-Path -LiteralPath $PolicyRoot) -and -not (Invoke-Core 'policy-summary').secured -and (Invoke-Core 'policy-status').hostRunning){Stop-Worker}
    Invoke-Core 'policy-secure'|Out-Null
    $summary=Invoke-Core 'policy-summary'
    if($summary.enabledRules -eq 0 -and -not $summary.rulesError -and @($summary.unreadableRules|Where-Object {$_}).Count -eq 0){
        Remove-Governor
        if($summary.rules -eq 0 -and $summary.paused){Invoke-Core 'policy-pause' @{paused=$false}|Out-Null}
        return
    }
    if($summary.paused){
        Register-Governor -Disabled
        Stop-Worker
        return
    }
    Register-Governor
    Start-Governor
}

switch($Action){
    'Sync' {Sync-Governor}
    'Resume' {Invoke-Core 'policy-pause' @{paused=$false}|Out-Null;Sync-Governor}
    'Pause' {
        $secured=(Test-Path -LiteralPath $PolicyRoot) -and (Invoke-Core 'policy-summary').secured
        if($secured){Invoke-Core 'policy-pause' @{paused=$true}|Out-Null}
        if(Get-GovernorTask){Disable-ScheduledTask -TaskName $taskName|Out-Null}
        Stop-Worker
        if(-not $secured){Invoke-Core 'policy-pause' @{paused=$true}|Out-Null}
        Restore-Interrupted (Invoke-Core 'policy-status')
    }
    'Remove' {Remove-Governor}
}
$task=Get-GovernorTask
$summary=Invoke-Core 'policy-summary'
$triggers=@(if($task){$task.Triggers})
[pscustomobject]@{schemaVersion=1;status='completed';data=[ordered]@{
    taskName=$taskName;registered=($null -ne $task);enabled=($null -ne $task -and [string]$task.State -ne 'Disabled')
    runAtLogon=(@($triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'}).Count -gt 0)
    restartEveryMinute=(@($triggers|Where-Object {$_.Repetition -and $_.Repetition.Interval -eq 'PT1M' -and -not $_.Repetition.Duration}).Count -eq 2)
    paused=[bool]$summary.paused;rules=[int]$summary.rules;enabledRules=[int]$summary.enabledRules;secured=[bool]$summary.secured
    securityProblem=$summary.securityProblem;rulesError=$summary.rulesError;worker=(Invoke-Core 'policy-status')}}|ConvertTo-Json -Depth 30
} catch {
    [pscustomobject]@{schemaVersion=1;status='failed';data=$null;errors=@([pscustomobject]@{message=$_.Exception.Message})}|ConvertTo-Json -Depth 5
    exit 1
}
