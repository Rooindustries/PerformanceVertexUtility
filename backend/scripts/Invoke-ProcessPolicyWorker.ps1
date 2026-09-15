param(
    [Parameter(Mandatory=$true)][ValidateSet('Status','Start','Stop','EnableLogon','DisableLogon','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$PolicyRoot,
    [string]$DotNetPath=$env:ROO_DOTNET_EXE,
    [string]$HostDirectory='',
    [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if($Action -ne 'Status' -and -not $ConfirmApply){throw 'Confirm the saved-policy worker operation before changing it.'}
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$PolicyRoot=[IO.Path]::GetFullPath($PolicyRoot)
$owner=Get-RooOperationOwner
$hash=[Security.Cryptography.SHA256]::Create()
try {$suffix=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($owner.userSid+'|'+$PolicyRoot.ToUpperInvariant())))).Replace('-','').Substring(0,20)}
finally {$hash.Dispose()}
$taskName='RooOptimizationSuite.ProcessRules.'+$suffix
$description='Roo process rules | '+$owner.userSid+' | '+$PolicyRoot
if(-not $HostDirectory){$HostDirectory=Join-Path $repoRoot 'backend\bin\optimizer'}
$hostDll=Join-Path $HostDirectory 'Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostDll)){throw 'Build the policy worker with Build-OptimizerHost.ps1 before starting saved rules.'}
if(-not $DotNetPath){
    $candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    if(Test-Path -LiteralPath $candidate){$DotNetPath=$candidate}else{$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
}
$DotNetPath=[IO.Path]::GetFullPath($DotNetPath)
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$requestPath=Join-Path $PolicyRoot 'worker-request.json'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task -and $task.Description -cne $description){throw 'The scheduled task has a different owner or policy folder.'}

function Invoke-Core([string]$CoreAction,[object]$Extra=@{}) {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('roo-policy-request-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $path=Join-Path $directory 'request.json'
    try {
        $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$PolicyRoot;confirm=$true}
        foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
        Write-RooOperationJson $request $path
        $text=@(& $DotNetPath $hostDll $CoreAction $path) -join "`n"
        $exitCode=$LASTEXITCODE
        $result=$text|ConvertFrom-Json
        if($exitCode -ne 0 -or $result.status -ne 'completed'){throw ($CoreAction+' failed (exit '+$exitCode+'): '+$result.error.message)}
        return $result.data
    } finally {Remove-Item -LiteralPath $directory -Recurse -Force}
}

function Stop-Worker {
    $status=Invoke-Core 'policy-status'
    if($null -eq $status.hostRunning){throw ('Worker identity could not be verified: '+$status.error)}
    if($status.hostRunning){
        Invoke-Core 'policy-stop'|Out-Null
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 200
            $status=Invoke-Core 'policy-status'
            if($null -eq $status.hostRunning){throw ('Worker shutdown could not be verified: '+$status.error)}
        } while($status.hostRunning -and $clock.Elapsed.TotalSeconds -lt 30)
        if($status.hostRunning){throw 'The policy worker did not finish restoring owned controls within 30 seconds. Its recovery state was preserved.'}
    } elseif($status.state -and $status.state.status -notin @('stopped','stoppedWithConflicts')) {
        Invoke-Core 'policy-run' @{durationSeconds=0}|Out-Null
    }
}

if($Action -in @('Start','EnableLogon','DisableLogon')) {
    [IO.Directory]::CreateDirectory($PolicyRoot)|Out-Null
    Write-RooOperationJson @{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$PolicyRoot;confirm=$true} $requestPath
    $atLogon=($Action -eq 'EnableLogon' -or ($Action -eq 'Start' -and $task -and @($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'}).Count -gt 0))
    $arguments='"'+$hostDll+'" policy-run "'+$requestPath+'"'
    $execute=New-ScheduledTaskAction -Execute $DotNetPath -Argument $arguments -WorkingDirectory $HostDirectory
    $admin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $principal=New-ScheduledTaskPrincipal -UserId $owner.userSid -LogonType Interactive -RunLevel $(if($admin){'Highest'}else{'Limited'})
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6
    $parameters=@{TaskName=$taskName;Description=$description;Action=$execute;Principal=$principal;Settings=$settings;Force=$true}
    if($atLogon){$parameters.Trigger=New-ScheduledTaskTrigger -AtLogOn -User $owner.userSid}
    Register-ScheduledTask @parameters|Out-Null
    if($Action -eq 'Start'){
        Start-ScheduledTask -TaskName $taskName
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {$status=Invoke-Core 'policy-status';if($status.hostRunning -eq $true){break};Start-Sleep -Milliseconds 200}while($clock.Elapsed.TotalSeconds -lt 20)
        if($status.hostRunning -ne $true){
            $info=Get-ScheduledTaskInfo -TaskName $taskName
            throw ('Policy worker startup was not confirmed. Task result: '+$info.LastTaskResult+'. '+$status.error)
        }
    }
}
if($Action -in @('Stop','Remove')){Stop-Worker}
if($Action -eq 'Remove' -and $task){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
[pscustomobject]@{schemaVersion=1;status='completed';data=@{taskName=$taskName;registered=($null -ne $task);runAtLogon=($null -ne $task -and @($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'}).Count -gt 0);worker=(Invoke-Core 'policy-status')}}|ConvertTo-Json -Depth 30
