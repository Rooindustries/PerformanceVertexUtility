param([Parameter(Mandatory=$true)][string]$Runner,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The runner does not parse.'}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$checks=New-Object System.Collections.Generic.List[object]
function Check([bool]$Passed,[string]$Name){$checks.Add([pscustomobject]@{passed=$Passed;check=$Name});$(if($Passed){'PASS '}else{'FAIL '})+$Name}
function Hash([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
$backup=$OutDir;$local=Join-Path $OutDir 'local';$app=Join-Path $OutDir 'install';$baseline=@{tasks=@()}
$scope=@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
$control=Join-Path $local 'RooIndustriesOptimizationSuite\operations\windows-timer'
New-Item -ItemType Directory -Path $control -Force|Out-Null
$startup=Join-Path $control 'startup.ps1';$receipt=Join-Path $control 'startup.json'
[IO.File]::WriteAllText($startup,("& '"+$app+"\backend\scripts\owned-fixture.ps1'"),[Text.UTF8Encoding]::new($false))
$name='RooIndustries.Timer.'+[Guid]::NewGuid().ToString('N').Substring(0,16).ToUpperInvariant()
$action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -NonInteractive -File "'+$startup+'"')
$principal=New-ScheduledTaskPrincipal -UserId $scope.sid -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -Disable
$service=New-Object -ComObject Schedule.Service;$service.Connect();$folder=$service.GetFolder('\')
$registered=$null;$xml='';$sddl=''
try {
    if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'The private task name already exists.'}
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Description 'Roo Industries recovery hash fixture'|Out-Null
    $registered=$folder.GetTask($name);$xml=[string]$registered.Xml;$sddl=[string]$registered.GetSecurityDescriptor(7)
    Add-Type -AssemblyName System.Xml.Linq
    $document=[System.Xml.Linq.XDocument]::Parse($xml);$ns=$document.Root.Name.Namespace
    $enabled=$document.Root.Element($ns+'Settings').Element($ns+'Enabled');if($enabled){$enabled.Remove()}
    $definitionHash=Hash ([Text.Encoding]::UTF8.GetBytes($document.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)+"`n"+$sddl))
    $scriptHash=(Get-FileHash -LiteralPath $startup -Algorithm SHA256).Hash
    $task=Get-ScheduledTask -TaskName $name
    foreach($case in @(
        @{name='Uppercase receipts match the computed SHA256 hashes';script=$scriptHash;definition=$definitionHash;accepted=$true},
        @{name='A different script hash is refused';script=('0'*64);definition=$definitionHash;accepted=$false},
        @{name='A 63-character script hash is refused';script=$scriptHash.Substring(0,63);definition=$definitionHash;accepted=$false},
        @{name='A non-hex script hash is refused';script=('Z'+$scriptHash.Substring(1));definition=$definitionHash;accepted=$false},
        @{name='A different definition hash is refused';script=$scriptHash;definition=('0'*64);accepted=$false},
        @{name='A 63-character definition hash is refused';script=$scriptHash;definition=$definitionHash.Substring(0,63);accepted=$false},
        @{name='A non-hex definition hash is refused';script=$scriptHash;definition=('Z'+$definitionHash.Substring(1));accepted=$false}
    )){
        $r=@{owner=@{userSid=$scope.sid;machine=$env:COMPUTERNAME};taskName=$name;phase='created';scriptHash=$case.script;definitionHash=$case.definition}
        [IO.File]::WriteAllText($receipt,($r|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        Check ((Test-RecoveryTaskOwnership $task $scope $xml $sddl) -eq $case.accepted) $case.name
    }
    $r.scriptHash=$scriptHash;$r.definitionHash=$definitionHash
    [IO.File]::WriteAllText($receipt,($r|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    $originalAcl=Get-Acl -LiteralPath $receipt
    $writer=Get-Acl -LiteralPath $receipt
    $writer.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($scope.sid),'Modify','Allow'))
    Set-Acl -LiteralPath $receipt -AclObject $writer
    try {Check (-not (Test-RecoveryTaskOwnership $task $scope $xml $sddl)) 'A user-writable receipt remains refused even with matching hashes'}
    finally {Set-Acl -LiteralPath $receipt -AclObject $originalAcl}
} finally {
    if($registered){
        $current=$folder.GetTask($name)
        try {if([string]$current.Xml -cne $xml -or [string]$current.GetSecurityDescriptor(7) -cne $sddl){throw 'The private task definition changed; retained.'}}
        finally {[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($current)}
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($registered)
    }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)
}
Check (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) 'The private disabled task was removed'
$passed=@($checks|Where-Object {-not $_.passed}).Count -eq 0
[pscustomobject]@{passed=$passed;checks=$checks.ToArray();runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash;scriptHash=$scriptHash;definitionHash=$definitionHash}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
exit [int](-not $passed)
