$ErrorActionPreference='Stop'
$script:Failed=0
function Check([bool]$Passed,[string]$Message){if($Passed){Write-Output ('PASS '+$Message)}else{$script:Failed++;Write-Output ('FAIL '+$Message)}}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Output 'SKIP Governor setup needs administrator rights to suspend its own scratch task';return}
$others=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)
if($others.Count -gt 0){Write-Output ('SKIP This PC has '+$others.Count+' real governor tasks, which setup would suspend');return}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw 'The fake helper needs the Windows .NET Framework C# compiler'}
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$local=[Environment]::GetFolderPath('LocalApplicationData')
$app=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-setup-legacy-'+$id)
$script=Join-Path $PSScriptRoot 'Invoke-GovernorSetup.ps1'
$cases=@(
    @{label='plain';task=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+$id.ToUpperInvariant()+'A0B1C2D3');root=(Join-Path $local ('RooIndustriesDataFix-setup-'+$id+'-a'));link=$false},
    @{label='junction';task=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+$id.ToUpperInvariant()+'B1C2D3E4');root=(Join-Path $local ('RooIndustriesDataFix-setup-'+$id+'-b'));link=$true}
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
        $definition=@{
            Action=(New-ScheduledTaskAction -Execute (Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe') -Argument ('--headless "'+(Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe')+'" policy-run "'+(Join-Path $policy 'worker-request.json')+'"') -WorkingDirectory (Join-Path $app 'backend\bin\optimizer'))
            Trigger=(New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddYears(2)))
            Principal=(New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest)
            Description=(('Roo Industries process rules' -replace ' Industries','')+' | '+$sid+' | '+$policy)
        }
        Register-ScheduledTask -TaskName $case.task @definition|Out-Null
    }
    $output=@(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Action Suspend -AppRoot $app -StatePath (Join-Path $app 'setup-state.json') -LogPath (Join-Path $app 'setup.log') -SetupProcessId $PID 2>&1)
    Check ($LASTEXITCODE -eq 0) ('Governor setup suspends the earlier version''s tasks: '+(($output|Select-Object -Last 3) -join ' / '))
    foreach($case in $cases){
        Check ((Get-ScheduledTask -TaskName $case.task).State -eq 'Disabled') ('The '+$case.label+' rules folder''s task is suspended')
        Check (-not(Test-Path -LiteralPath (Join-Path $case.written 'governor.json'))) ('Setup writes nothing into the earlier, still user-writable '+$case.label+' rules folder and a stopped state it holds does not pause the rules')
    }
} finally {
    foreach($case in $cases){
        Unregister-ScheduledTask -TaskName $case.task -Confirm:$false -ErrorAction SilentlyContinue
        $policy=Join-Path $case.root 'process-rules'
        if(Test-Path -LiteralPath $policy){if((Get-Item -LiteralPath $policy -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd.exe /c rmdir ('"'+$policy+'"')|Out-Null}}
        foreach($path in @($case.root,($case.root+'-target'))){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    }
    Unregister-ScheduledTask -TaskName 'RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -Confirm:$false -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $app){Remove-Item -LiteralPath $app -Recurse -Force}
}
Check (-not(Test-Path -LiteralPath $app) -and @(Get-ScheduledTask -TaskName ('*'+$id+'*') -ErrorAction SilentlyContinue).Count -eq 0 -and $null -eq (Get-ScheduledTask -TaskName 'RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -ErrorAction SilentlyContinue)) 'The scenario removes its tasks, helper and folders'
if($script:Failed -gt 0){throw ($script:Failed.ToString()+' governor setup checks failed')}
