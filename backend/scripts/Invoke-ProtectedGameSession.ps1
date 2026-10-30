param(
    [Parameter(Mandatory=$true)][ValidateSet('Preview','Start','Status','Affinity','Stop','Recover','RemoveAll')][string]$Action,
    [string]$SessionRoot='', [string]$PreviewPath='', [string]$ReviewHash='', [string]$OperationsRoot='',
    [int]$LauncherProcessId=0, [string]$GamePath='', [string]$ControlsPath='', [string]$AffinityMask='',
    [string]$HostDirectory='', [string]$DotNetPath='', [switch]$AcceptLauncherScope, [switch]$AcceptEarlierVersion, [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
$dotNetOverride=$DotNetPath
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if(-not $HostDirectory){$HostDirectory=Join-Path $repoRoot 'backend\bin\optimizer'}
$hostDll=Join-Path $HostDirectory 'Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostDll)){throw 'Build-OptimizerHost.ps1 must build the native session helper first.'}
$hostArgs=@($hostDll)
if(-not $DotNetPath -and (Test-Path -LiteralPath (Join-Path $HostDirectory 'hostpolicy.dll'))){$DotNetPath=Join-Path $HostDirectory 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){$DotNetPath=Get-RooIndustriesDevelopmentDotNet $HostDirectory}
$DotNetPath=[IO.Path]::GetFullPath($DotNetPath)
if($Action -notin @('Preview','Status') -and -not $ConfirmApply){throw 'Review the protected-session operation before using -ConfirmApply.'}
function Test-Restored($Worker){return $Worker -and $Worker.restored -eq $true}
# A worker removes its own task after a start that ended, so a task that is already gone counts as removed.
# Only a lookup that says not found proves that; any other lookup failure keeps the removal error.
function Remove-SessionTask([string]$Name){
    try{Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop}
    catch{
        $removal=$_
        try{Get-ScheduledTask -TaskName $Name -ErrorAction Stop|Out-Null}
        catch{if($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound){return};throw $removal}
        throw $removal
    }
}
function Invoke-Core([string]$Operation,[hashtable]$Fields=@{}) {
    $request=@{schemaVersion=1;repoRoot=$repoRoot;confirm=[bool]$ConfirmApply}
    if($SessionRoot){$request.sessionRoot=$SessionRoot}
    foreach($key in $Fields.Keys){$request[$key]=$Fields[$key]}
    $OutputEncoding=[Text.UTF8Encoding]::new($false)
    $text=@(($request|ConvertTo-Json -Depth 20)|& $DotNetPath @hostArgs $Operation '-') -join "`n";$exit=$LASTEXITCODE;$result=$text|ConvertFrom-Json
    # The helper's message is written for the person using the app; the operation name only stands in when there is none.
    if($exit -ne 0 -or $result.status -ne 'completed'){if($result.error.message){throw [string]$result.error.message};throw ($Operation+' failed (exit '+$exit+').')}
    return $result.data
}
function Complete-PendingStart{
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $now=Invoke-Core 'protected-session-status'
        if($now.state -or $now.hostRunning -ne $true){return}
        if((Invoke-Core 'protected-session-cancel').cancelled){return}
        Start-Sleep -Milliseconds 500
    }while($clock.Elapsed.TotalSeconds -lt 40)
    throw 'The session is still starting. Try again in a moment.'
}
if($Action -eq 'Preview'){
    if(-not $PreviewPath -or -not $ControlsPath -or -not $GamePath -or $LauncherProcessId -le 0){throw 'Provide the launcher PID, game executable, controls JSON and preview output path.'}
    $plan=Invoke-Core 'protected-session-preview' @{processId=$LauncherProcessId;gamePath=[IO.Path]::GetFullPath($GamePath);controlsPath=[IO.Path]::GetFullPath($ControlsPath);outputPath=[IO.Path]::GetFullPath($PreviewPath);acceptLauncherScope=[bool]$AcceptLauncherScope}
    @{schemaVersion=1;status='completed';data=@{preview=$plan;previewPath=[IO.Path]::GetFullPath($PreviewPath);reviewHash=(Get-FileHash -LiteralPath $PreviewPath).Hash}}|ConvertTo-Json -Depth 30
    return
}
if($Action -eq 'Start'){
    if(-not $PreviewPath -or -not $ReviewHash){throw 'Provide the reviewed preview file and its hash.'}
    $plan=Invoke-Core 'protected-session-check' @{previewPath=[IO.Path]::GetFullPath($PreviewPath);reviewHash=$ReviewHash}
    if(-not $SessionRoot){
        $operations=Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
        Invoke-Core 'operations-secure' @{operationsRoot=$operations;confirm=$true}|Out-Null
        $SessionRoot=Join-Path $operations ('game-session-'+$plan.operationId+'\session')
    }
}
if($Action -eq 'RemoveAll'){
    if(-not $OperationsRoot){$OperationsRoot=Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'}
    $OperationsRoot=[IO.Path]::GetFullPath($OperationsRoot).TrimEnd('\','/')
    $results=@();$failed=$false;$kept=@()
    $directories=if(Test-Path -LiteralPath $OperationsRoot){@(Get-ChildItem -LiteralPath $OperationsRoot -Directory -Filter 'game-session-*')}else{@()}
    foreach($directory in $directories){
        $root=Join-Path $directory.FullName 'session'
        if(-not(Test-Path -LiteralPath (Join-Path $root 'session.json')) -and -not(Test-Path -LiteralPath (Join-Path $root 'worker-request.json'))){continue}
        try{
            $result=(& $PSCommandPath -Action Stop -SessionRoot $root -HostDirectory $HostDirectory -DotNetPath $dotNetOverride -ConfirmApply)|ConvertFrom-Json
            if(-not(Test-Restored $result.data.worker)){throw 'The session still needs recovery; its saved state and task were kept.'}
            $results+=@{sessionRoot=$root;status='restored'}
        }
        catch{$failed=$true;$kept+=$root;$results+=@{sessionRoot=$root;status='failed';error=$_.Exception.Message}}
    }
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try{
        $leftovers=@(Get-ScheduledTask -ErrorAction Stop|Where-Object {$_.TaskName -like 'Roo Industries Protected Session *' -or $_.TaskName -like ($script:RooIndustriesLegacyIdentity.gameTask+'*')})
    }
    catch{$failed=$true;$results+=@{status='failed';error=$_.Exception.Message};$leftovers=@()}
    foreach($leftover in @($leftovers|Where-Object {
        $parts=@([string]$_.Description -split ' \| ')
        $parts.Count -eq 3 -and $parts[1] -eq $owner -and (Split-Path -Leaf $parts[2]) -eq 'session' -and
            (Split-Path -Leaf (Split-Path -Parent $parts[2])) -like 'game-session-*' -and
            (Split-Path -Parent (Split-Path -Parent $parts[2])) -ieq $OperationsRoot -and -not(Test-Path -LiteralPath (Join-Path $parts[2] 'session.json')) -and $kept -notcontains $parts[2]
    })){
        try{Remove-SessionTask $leftover.TaskName}
        catch{$failed=$true;$results+=@{taskName=$leftover.TaskName;status='failed';error=$_.Exception.Message}}
    }
    @{schemaVersion=1;status=$(if($failed){'failed'}else{'completed'});data=@{sessions=$results}}|ConvertTo-Json -Depth 10
    if($failed){exit 1}
    return
}
if(-not $SessionRoot){throw 'Provide the session directory returned by Start.'}
$SessionRoot=[IO.Path]::GetFullPath($SessionRoot)
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$sha=[Security.Cryptography.SHA256]::Create()
try{$suffix=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SessionRoot.ToLowerInvariant())))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
$taskName='Roo Industries Protected Session '+$suffix
$description='Roo Industries protected game session | '+$owner+' | '+$SessionRoot
$task=Find-RooIndustriesCompatibleTask $taskName ($script:RooIndustriesLegacyIdentity.gameTask+$suffix) $description ($script:RooIndustriesLegacyIdentity.gameDescription+$owner+' | '+$SessionRoot)
if($task){$taskName=$task.TaskName;$description=$task.Description}
if($Action -eq 'Start'){
    if(Test-Path -LiteralPath (Join-Path $SessionRoot 'session.json')){throw 'This session already has recovery state. Stop/recover it, then create a new preview and session directory.'}
    $workerExe=Join-Path $HostDirectory 'session\RooIndustries.SessionHost.exe'
    if(-not(Test-Path -LiteralPath $workerExe)){throw 'The app''s background session program is missing, so nothing was changed. Reinstall the app, then try again.'}
    $requestPath=Join-Path $SessionRoot 'worker-request.json'
    $execute=New-RooIndustriesElevatedTaskAction $workerExe @('run',$requestPath) (Split-Path $workerExe -Parent)
    $principal=New-ScheduledTaskPrincipal -UserId $owner -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6
    # A start that ends early removes the folder only if it made it; in a folder that was already there it removes just its request.
    $madeRoot=-not(Test-Path -LiteralPath $SessionRoot)
    [IO.Directory]::CreateDirectory($SessionRoot)|Out-Null
    try{
        # The sign-in task exists before the request does: session status reads a request whose task is gone as a start that ended.
        Register-ScheduledTask -TaskName $taskName -Description $description -Action $execute -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $owner) -Force|Out-Null
        [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;repoRoot=$repoRoot;sessionRoot=$SessionRoot;previewPath=[IO.Path]::GetFullPath($PreviewPath);reviewHash=$ReviewHash;confirm=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Start-ScheduledTask -TaskName $taskName
    }catch{
        $reason=$_.Exception.Message
        # Cancel under the worker's lock, then remove the task. If a worker already holds that lock, it started: wait for it below.
        # Once the request exists a worker may already have read it, so the folder keeps its cancel note for that worker to refuse on;
        # only a start that never wrote its request removes the folder it made.
        try{
            $written=Test-Path -LiteralPath $requestPath
            $cancelled=-not $written -or (Invoke-Core 'protected-session-cancel').cancelled
            if($cancelled){
                Remove-SessionTask $taskName
                if(-not $written -and $madeRoot){Remove-Item -LiteralPath $SessionRoot -Recurse -Force}
            }
        }catch{throw ('Session startup failed: '+$reason+' Its unused session files could not be removed: '+$_.Exception.Message)}
        if($cancelled){throw ('Session startup failed: '+$reason)}
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $failurePath=Join-Path $SessionRoot 'worker-error.json'
    $cancelPath=Join-Path $SessionRoot 'start-cancelled.json'
    $noReason='The background session program stopped before it changed anything. Try again, and reinstall the app if it keeps happening.'
    do {
        $status=Invoke-Core 'protected-session-status'
        if($status.hostRunning -eq $true -and $status.state.status -in @('armed','active','partial')){break}
        # Stop cancelled this start before its worker changed anything. Keep the folder: its note makes a worker that starts late refuse too.
        if($status.hostRunning -eq $false -and -not $status.state -and (Test-Path -LiteralPath $cancelPath)){throw 'Session start was cancelled before it changed anything.'}
        # Not running with nothing saved means the start ended: its worker gave up, with or without saying why, and can't run again.
        if($status.hostRunning -eq $false){
            $failure=if(Test-Path -LiteralPath $failurePath){Get-Content -Raw -LiteralPath $failurePath|ConvertFrom-Json}else{$null}
            if(-not $status.state){
                $wait=[Diagnostics.Stopwatch]::StartNew()
                while((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running' -and $wait.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 200}
                if(-not(Test-Path -LiteralPath (Join-Path $SessionRoot 'session.json'))){
                    try{
                        Remove-SessionTask $taskName
                        if($madeRoot){Remove-Item -LiteralPath $SessionRoot -Recurse -Force}else{foreach($file in $requestPath,$failurePath){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force -ErrorAction Stop}}}
                    }
                    catch{throw ('Session startup failed: '+$(if($failure){$failure.error}else{$noReason})+' Its unused session files could not be removed: '+$_.Exception.Message)}
                }
            }
            if($failure){throw ('Session startup failed: '+$failure.error)}
            if(-not $status.state){throw ('Session startup failed: '+$noReason)}
            throw ('Session stopped during startup: '+($status.state.errors -join '; '))
        }
        Start-Sleep -Milliseconds 200
    }while($clock.Elapsed.TotalSeconds -lt 35)
    if($status.hostRunning -ne $true -or $status.state.status -notin @('armed','active','partial')){throw 'Session startup was not verified; inspect its retained recovery state.'}
}
if($Action -eq 'Affinity'){
    $status=Invoke-Core 'protected-session-status'
    if(-not $AffinityMask){throw 'Provide an explicit affinity mask.'}
    Invoke-Core 'protected-session-affinity' @{affinity=@{group=$status.state.preview.originalAffinity.group;mask=$AffinityMask}}|Out-Null
}
if($Action -eq 'Stop'){
    $status=Invoke-Core 'protected-session-status'
    if($null -eq $status.hostRunning){throw $status.error}
    if(-not $status.state -and $status.hostRunning){Complete-PendingStart;$status=Invoke-Core 'protected-session-status'}
    if($status.hostRunning){Invoke-Core 'protected-session-stop'|Out-Null}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {$status=Invoke-Core 'protected-session-status';if($status.hostRunning -eq $false){break};Start-Sleep -Milliseconds 200}while($clock.Elapsed.TotalSeconds -lt 30)
    if($status.hostRunning -ne $false){throw 'Worker shutdown is not verified; recovery state was retained.'}
    if($status.state -and -not(Test-Restored $status)){Invoke-Core 'protected-session-recover' @{operationId=$status.state.preview.operationId;acceptEarlierVersion=[bool]$AcceptEarlierVersion}|Out-Null}
    if($task -and (Test-Restored (Invoke-Core 'protected-session-status'))){Remove-SessionTask $taskName}
}
if($Action -eq 'Recover'){
    $status=Invoke-Core 'protected-session-status'
    if(-not $status.state -and $status.hostRunning -and -not(Invoke-Core 'protected-session-cancel').cancelled){throw 'The session is still starting. Stop it instead, or try again in a moment.'}
    if($status.state){Invoke-Core 'protected-session-recover' @{operationId=$status.state.preview.operationId;acceptEarlierVersion=[bool]$AcceptEarlierVersion}|Out-Null}
    if($task -and (Test-Restored (Invoke-Core 'protected-session-status'))){Remove-SessionTask $taskName}
}
@{schemaVersion=1;status='completed';data=@{sessionRoot=$SessionRoot;taskName=$taskName;worker=(Invoke-Core 'protected-session-status')}}|ConvertTo-Json -Depth 40
