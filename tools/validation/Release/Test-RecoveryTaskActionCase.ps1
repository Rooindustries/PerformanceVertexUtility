param([Parameter(Mandatory=$true)][string]$Runner,[Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The runner does not parse.'}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$checks=New-Object System.Collections.Generic.List[object]
function Check([bool]$Passed,[string]$Name){$checks.Add([pscustomobject]@{passed=$Passed;check=$Name});$(if($Passed){'PASS '}else{'FAIL '})+$Name}
$local=Join-Path $OutDir 'local';$app=Join-Path $OutDir 'install';$baseline=@{tasks=@()}
$scope=@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
$root=Join-Path $local 'RooIndustriesOptimizationSuite\process-rules'
$hostFolder=Join-Path $app 'backend\bin\optimizer'
$scripts=Join-Path $app 'backend\scripts'
New-Item -ItemType Directory -Path $scripts,$hostFolder,$root -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1'),(Join-Path $Source 'backend\scripts\Start-RooIndustriesHelper.cmd') -Destination $scripts
. (Join-Path $scripts 'BrandCompatibility.Common.ps1')
$action=New-RooIndustriesElevatedTaskAction (Join-Path $hostFolder 'Optimizer.Host.exe') @('policy-run',(Join-Path $root 'worker-request.json')) $hostFolder
$action.Arguments=$action.Arguments.Replace('\system32\','\System32\')
$name='RooIndustriesOptimizationSuite.ProcessRules.'+(Get-RecoveryTaskSuffix ($scope.sid+'|'+$root.ToUpperInvariant()) 20)
$principal=New-ScheduledTaskPrincipal -UserId $scope.sid -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -Disable
$service=New-Object -ComObject Schedule.Service;$service.Connect();$folder=$service.GetFolder('\')
$registered=$false;$lastXml='';$lastSddl=''
try {
    if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'The private governor task name already exists.'}
    foreach($case in @(
        @{name='The exact governor action is accepted';execute=$action.Execute;arguments=$action.Arguments;directory=$action.WorkingDirectory;accepted=$true},
        @{name='Casing-only command path differences are accepted';execute=$action.Execute.ToLowerInvariant();arguments=$action.Arguments;directory=$action.WorkingDirectory;accepted=$true},
        @{name='Casing-only argument path differences are accepted';execute=$action.Execute;arguments=$action.Arguments.Replace('System32','system32');directory=$action.WorkingDirectory;accepted=$true},
        @{name='Casing-only working directory differences are accepted';execute=$action.Execute;arguments=$action.Arguments;directory=$action.WorkingDirectory.ToLowerInvariant();accepted=$true},
        @{name='A different argument character is refused';execute=$action.Execute;arguments=$action.Arguments.Replace('/e:on','/e:ox');directory=$action.WorkingDirectory;accepted=$false},
        @{name='An extra argument token is refused';execute=$action.Execute;arguments=($action.Arguments+' extra');directory=$action.WorkingDirectory;accepted=$false},
        @{name='Policy-Run remains refused';execute=$action.Execute;arguments=$action.Arguments.Replace('?policy-run?','?Policy-Run?');directory=$action.WorkingDirectory;accepted=$false}
    )){
        if($registered){$current=$folder.GetTask($name);try{if([string]$current.Xml -cne $lastXml -or [string]$current.GetSecurityDescriptor(7) -cne $lastSddl){throw 'The private governor task changed; retained.'}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($current)}}
        $a=New-ScheduledTaskAction -Execute $case.execute -Argument $case.arguments -WorkingDirectory $case.directory
        Register-ScheduledTask -TaskName $name -Action $a -Principal $principal -Settings $settings -Description ('Roo Industries process rules | '+$scope.sid+' | '+$root) -Force|Out-Null
        $registered=$true;$native=$folder.GetTask($name)
        try{$lastXml=[string]$native.Xml;$lastSddl=[string]$native.GetSecurityDescriptor(7)}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($native)}
        $task=Get-ScheduledTask -TaskName $name
        [pscustomobject]@{name=$task.TaskName;path=$task.TaskPath;description=$task.Description;principal=@{user=$task.Principal.UserId;logon=[string]$task.Principal.LogonType;level=[string]$task.Principal.RunLevel};actions=@($task.Actions|Select-Object Execute,Arguments,WorkingDirectory);app=$app;local=$local;root=$root}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir ($checks.Count.ToString()+'-task.json')) -Encoding UTF8
        Check ((Test-RecoveryTaskOwnership $task $scope $lastXml $lastSddl) -eq $case.accepted) $case.name
    }
} finally {
    if($registered){$current=$folder.GetTask($name);try{if([string]$current.Xml -cne $lastXml -or [string]$current.GetSecurityDescriptor(7) -cne $lastSddl){throw 'The private governor task changed; retained.'}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($current)};Unregister-ScheduledTask -TaskName $name -Confirm:$false}
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)
}
Check (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) 'The private disabled governor task was removed'
$passed=@($checks|Where-Object {-not $_.passed}).Count -eq 0
[pscustomobject]@{passed=$passed;checks=$checks.ToArray();runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
exit [int](-not $passed)
