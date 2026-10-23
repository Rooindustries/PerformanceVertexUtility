$ErrorActionPreference='Stop'
$script:Failed=0
function Check([bool]$Passed,[string]$Message){if($Passed){Write-Output ('PASS '+$Message)}else{$script:Failed++;Write-Output ('FAIL '+$Message)}}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Output 'SKIP Governor setup needs administrator rights to suspend its own scratch task';return}
$others=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)
if($others.Count -gt 0){Write-Output ('SKIP This PC has '+$others.Count+' real governor tasks, which setup would suspend');return}
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
$watchdogGate=[Threading.Mutex]::new($false,'Global\RooIndustriesGovernorSetupWatchdogFixture');$gateHeld=$false;try{$gateHeld=$watchdogGate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$gateHeld=$true}
if(-not $gateHeld){Write-Output 'SKIP Another validation run is using the setup recovery task';return}
if(Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue){Write-Output 'SKIP This PC has a pending setup recovery task, which setup would replace';return}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw 'The fake helper needs the Windows .NET Framework C# compiler'}
$id=[Guid]::NewGuid().ToString('N').Substring(0,19).ToUpperInvariant()
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$local=[Environment]::GetFolderPath('LocalApplicationData')
$app=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-setup-legacy-'+$id)
$script=Join-Path $PSScriptRoot 'Invoke-GovernorSetup.ps1'
$cases=@(
    @{label='plain';task=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+$id)+'A';root=(Join-Path $local ('RooIndustriesDataFix-setup-'+$id+'-a'));link=$false},
    @{label='junction';task=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+$id)+'B';root=(Join-Path $local ('RooIndustriesDataFix-setup-'+$id+'-b'));link=$true}
)
try {
    [IO.Directory]::CreateDirectory((Join-Path $app 'backend\bin\optimizer'))|Out-Null
    $source=Join-Path $app 'FakeHost.cs'
    [IO.File]::WriteAllText($source,@'
using System;
public static class FakeHost {
 public static int Main(string[] args) {
  Console.In.ReadToEnd();
  if(args.Length>0 && args[0]=="policy-status"){Console.Out.Write("{\"status\":\"completed\",\"data\":{\"hostRunning\":false,\"state\":{\"status\":\"stopped\"}}}");return 0;}
  Console.Out.Write("{\"status\":\"failed\",\"error\":{\"message\":\"The earlier version's rules folder is not protected.\"}}");
  return 1;
 }
}
'@)
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+(Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe')) $source
    if($LASTEXITCODE -ne 0){throw 'Could not compile the fake helper'}
    foreach($case in $cases){
        $target=$case.root+'-target'
        $policy=Join-Path $case.root 'process-rules'
        if($case.link){
            [IO.Directory]::CreateDirectory((Join-Path $target 'rules'))|Out-Null
            [IO.Directory]::CreateDirectory($case.root)|Out-Null
            cmd.exe /c mklink /J ('"'+$policy+'"') ('"'+$target+'"')|Out-Null
            if($LASTEXITCODE -ne 0){throw 'Could not create the junction'}
            $case.written=$target
        } else {
            [IO.Directory]::CreateDirectory((Join-Path $policy 'rules'))|Out-Null
            $case.written=$policy
        }
        [IO.File]::WriteAllText((Join-Path $case.written 'rules\rule.json'),'{}')
        $launcher=Join-Path $app 'backend\scripts\Start-RooIndustriesHelper.cmd'
        [IO.Directory]::CreateDirectory((Split-Path $launcher -Parent))|Out-Null
        [IO.File]::WriteAllText($launcher,"@echo off`r`nexit /b 0`r`n")
        $scriptsRoot=$script:RooIndustriesScriptsRoot
        $script:RooIndustriesScriptsRoot=Split-Path $launcher -Parent
        try {$action=New-RooIndustriesElevatedTaskAction (Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe') @('policy-run',(Join-Path $policy 'worker-request.json')) (Join-Path $app 'backend\bin\optimizer')} finally {$script:RooIndustriesScriptsRoot=$scriptsRoot}
        $definition=@{
            Action=$action
            Trigger=(New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddYears(2)))
            Principal=(New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest)
            Description=(('Roo Industries process rules' -replace ' Industries','')+' | '+$sid+' | '+$policy)
        }
        Register-ScheduledTask -TaskName $case.task @definition|Out-Null
    }
    $setupFolder=Join-Path $app 'setup'
    [IO.Directory]::CreateDirectory($setupFolder)|Out-Null
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Action Suspend -AppRoot $app -StatePath (Join-Path $setupFolder 'governor-suspended.json') -LogPath (Join-Path $setupFolder 'governor-setup.log') -SetupProcessId $PID 2>&1)}finally{$ErrorActionPreference=$previous}
    Check ($LASTEXITCODE -eq 0) ('Governor setup suspends the earlier version''s tasks: '+(($output|Select-Object -Last 3) -join ' / '))
    foreach($case in $cases){
        Check ((Get-ScheduledTask -TaskName $case.task).State -eq 'Disabled') ('The '+$case.label+' rules folder''s task is suspended')
        Check (-not(Test-Path -LiteralPath (Join-Path $case.written 'governor.json'))) ('Setup writes nothing into the earlier, still user-writable '+$case.label+' rules folder and a stopped state it holds does not pause the rules')
    }
} finally {
    Unregister-ScheduledTask -TaskName $watchdog -Confirm:$false -ErrorAction SilentlyContinue
    foreach($case in $cases){
        Unregister-ScheduledTask -TaskName $case.task -Confirm:$false -ErrorAction SilentlyContinue
        $policy=Join-Path $case.root 'process-rules'
        if(Test-Path -LiteralPath $policy){if((Get-Item -LiteralPath $policy -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd.exe /c rmdir ('"'+$policy+'"')|Out-Null}}
        foreach($path in @($case.root,($case.root+'-target'))){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    }
    if(Test-Path -LiteralPath $app){Remove-Item -LiteralPath $app -Recurse -Force}
}
Check (-not(Test-Path -LiteralPath $app) -and @(Get-ScheduledTask -TaskName ('*'+$id+'*') -ErrorAction SilentlyContinue).Count -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'The scenario removes its tasks, setup recovery task, helper and folders'
$watchdogGate.ReleaseMutex()
if($script:Failed -gt 0){throw ($script:Failed.ToString()+' governor setup checks failed')}
