param(
    [Parameter(Mandatory=$true)][ValidateSet('Preview','Start','Status','Affinity','Stop','Recover')][string]$Action,
    [string]$SessionRoot='', [string]$PreviewPath='', [string]$ReviewHash='',
    [int]$LauncherProcessId=0, [string]$GamePath='', [string]$ControlsPath='', [string]$AffinityMask='',
    [string]$HostDirectory='', [string]$DotNetPath='', [switch]$AcceptLauncherScope, [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if(-not $HostDirectory){$HostDirectory=Join-Path $repoRoot 'backend\bin\optimizer'}
$hostDll=Join-Path $HostDirectory 'Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostDll)){throw 'Build-OptimizerHost.ps1 must build the native session helper first.'}
$hostArgs=@($hostDll)
if(-not $DotNetPath -and (Test-Path -LiteralPath (Join-Path $HostDirectory 'hostpolicy.dll'))){$DotNetPath=Join-Path $HostDirectory 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
$DotNetPath=[IO.Path]::GetFullPath($DotNetPath)
if($Action -notin @('Preview','Status') -and -not $ConfirmApply){throw 'Review the protected-session operation before using -ConfirmApply.'}
function Invoke-Core([string]$Operation,[hashtable]$Fields=@{}) {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-session-request-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    try {
        $request=@{schemaVersion=1;repoRoot=$repoRoot;confirm=[bool]$ConfirmApply}
        if($SessionRoot){$request.sessionRoot=$SessionRoot}
        foreach($key in $Fields.Keys){$request[$key]=$Fields[$key]}
        $path=Join-Path $directory 'request.json';[IO.File]::WriteAllText($path,($request|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $text=@(& $DotNetPath @hostArgs $Operation $path) -join "`n";$exit=$LASTEXITCODE;$result=$text|ConvertFrom-Json
        if($exit -ne 0 -or $result.status -ne 'completed'){throw ($Operation+' failed (exit '+$exit+'): '+$result.error.message)}
        return $result.data
    }finally{Remove-Item -LiteralPath $directory -Recurse -Force}
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
    if(-not $SessionRoot){$SessionRoot=Join-Path $env:LOCALAPPDATA ('RooIndustries\ProtectedSessions\'+$plan.operationId)}
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
    [IO.Directory]::CreateDirectory($SessionRoot)|Out-Null
    $requestPath=Join-Path $SessionRoot 'worker-request.json'
    [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;repoRoot=$repoRoot;sessionRoot=$SessionRoot;previewPath=[IO.Path]::GetFullPath($PreviewPath);reviewHash=$ReviewHash;confirm=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $workerExe=Join-Path $HostDirectory 'session\RooIndustries.SessionHost.exe'
    if(-not(Test-Path -LiteralPath $workerExe)){throw 'Build-OptimizerHost.ps1 must package the background session executable.'}
    $execute=New-ScheduledTaskAction -Execute $workerExe -Argument ('run "'+$requestPath+'"') -WorkingDirectory (Split-Path $workerExe -Parent)
    $principal=New-ScheduledTaskPrincipal -UserId $owner -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6
    Register-ScheduledTask -TaskName $taskName -Description $description -Action $execute -Principal $principal -Settings $settings -Force|Out-Null
    Start-ScheduledTask -TaskName $taskName
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {$status=Invoke-Core 'protected-session-status';if($status.hostRunning -eq $true -and $status.state.status -in @('armed','active','partial')){break};if($status.state -and $status.hostRunning -eq $false){if(Test-Path (Join-Path $SessionRoot 'worker-error.json')){$failure=Get-Content -Raw (Join-Path $SessionRoot 'worker-error.json')|ConvertFrom-Json;throw ('Session startup failed: '+$failure.error+' '+$failure.hresult)};throw ('Session stopped during startup: '+($status.state.errors -join '; '))};Start-Sleep -Milliseconds 200}while($clock.Elapsed.TotalSeconds -lt 35)
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
    if($status.hostRunning){Invoke-Core 'protected-session-stop'|Out-Null}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {$status=Invoke-Core 'protected-session-status';if($status.hostRunning -eq $false){break};Start-Sleep -Milliseconds 200}while($clock.Elapsed.TotalSeconds -lt 30)
    if($status.hostRunning -ne $false){throw 'Worker shutdown is not verified; recovery state was retained.'}
    if($status.state){Invoke-Core 'protected-session-recover' @{operationId=$status.state.preview.operationId}|Out-Null}
    if($task){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
}
if($Action -eq 'Recover'){
    $status=Invoke-Core 'protected-session-status'
    if(-not $status.state){throw 'There is no session recovery state.'}
    Invoke-Core 'protected-session-recover' @{operationId=$status.state.preview.operationId}|Out-Null
    if($task){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
}
@{schemaVersion=1;status='completed';data=@{sessionRoot=$SessionRoot;taskName=$taskName;worker=(Invoke-Core 'protected-session-status')}}|ConvertTo-Json -Depth 40
