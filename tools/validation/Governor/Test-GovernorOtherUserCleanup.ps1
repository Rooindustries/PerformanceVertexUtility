param([string]$Script=(Join-Path $PSScriptRoot 'Test-GovernorOtherUser.ps1'),[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Script,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Other-user fixture source does not parse'}
$switches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Phase'},$true))
if($switches.Count -ne 1){throw 'Other-user fixture phase command was not uniquely found'}
$command=[scriptblock]::Create($switches[0].Extent.Text)
foreach($node in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Check','Governor-Task')},$true)){. ([scriptblock]::Create($node.Extent.Text))}
function Get-LocalUser {
    [CmdletBinding()]param([string]$Name)
    if($script:fixture.account){[pscustomobject]@{Name=$account;SID=[pscustomobject]@{Value=$sid}}}
}
function Get-ScheduledTask {
    [CmdletBinding()]param([string]$TaskName='*')
    $script:fixture.discoveries++
    if(($script:fixture.fault -eq 'discovery' -and $script:fixture.discoveries -eq 1) -or ($script:fixture.fault -eq 'rediscovery' -and $script:fixture.discoveries -eq 2)){Write-Error 'Injected task discovery failure';return}
    @($script:fixture.tasks|Where-Object TaskName -Like $TaskName)
}
function Stop-ScheduledTask {
    [CmdletBinding()]param([string]$TaskName,[string]$TaskPath)
    if($script:fixture.fault -eq 'stop' -and $TaskName -eq $tasks[0]){Write-Error 'Injected nonterminating stop failure'}
}
function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess=$true)]param([string]$TaskName,[string]$TaskPath)
    $target=if($script:fixture.target -eq 'fixture'){$tasks[0]}else{'RooIndustries.OptimizationSuite.ProcessRules.owned'}
    if($TaskName -eq $target){
        if($script:fixture.fault -eq 'removal'){Write-Error 'Injected nonterminating removal failure';return}
        if($script:fixture.fault -eq 'survivor'){return}
    }
    $script:fixture.tasks=@($script:fixture.tasks|Where-Object {-not($_.TaskName -eq $TaskName -and (-not$TaskPath -or $_.TaskPath -eq $TaskPath))})
}
function Get-CimInstance {
    [CmdletBinding()]param([Parameter(Position=0)][string]$ClassName,[string]$Filter)
    if($ClassName -eq 'Win32_UserProfile' -and $script:fixture.profile){[pscustomobject]@{SID=$sid}}
    elseif($ClassName -ne 'Win32_Process' -and $ClassName -ne 'Win32_UserProfile'){throw 'Unexpected fixture CIM query'}
}
function Remove-CimInstance {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process {if($InputObject.SID -cne $sid){throw 'Foreign profile removal attempted'};$script:fixture.profile=$false}
}
function Get-Item {
    [CmdletBinding()]param([string]$LiteralPath)
    if($LiteralPath -cne 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'){throw 'Unexpected fixture registry query'}
}
function Start-Sleep {param([int]$Seconds)}
function net.exe {
    if(($args -join ' ') -cne ('user '+$account+' /delete')){throw 'Unexpected fixture account command'}
    if(-not$script:fixture.account){Write-Error 'The fixture account does not exist';return}
    $script:fixture.account=$false
}
$rows=@()
$root=Join-Path $OutDir ('other-user-cleanup-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try {
    foreach($case in @('fixture-removal','governor-removal','fixture-survivor','governor-survivor','discovery','rediscovery','stop','foreign','success','account-missing')){
        $account='cleanup-fixture'
        $sid='S-1-5-21-111-222-333-1001';$foreignSid='S-1-5-21-111-222-333-1002'
        $work=Join-Path $root $case
        [IO.Directory]::CreateDirectory($work)|Out-Null
        $ownerPath=Join-Path $work 'fixture-owner.txt'
        Set-Content -LiteralPath $ownerPath -Value $sid -Encoding ASCII
        $probeExe=Join-Path $work 'probe.exe'
        $tasks=@('RooIndustriesGovernorOtherSetup','RooIndustriesGovernorOtherProbe','RooIndustriesGovernorOtherWorker')
        $script:fixture=@{account=($case -ne 'account-missing');profile=$true;discoveries=0;fault=($case -replace '^(fixture|governor)-','');target=$(if($case -like 'governor-*'){'governor'}else{'fixture'});tasks=@(
            [pscustomobject]@{TaskName=$tasks[0];TaskPath='\';Description='';Principal=[pscustomobject]@{UserId=$(if($case -eq 'foreign'){$foreignSid}else{$sid})}},
            [pscustomobject]@{TaskName=$tasks[1];TaskPath='\Nested\';Description='';Principal=[pscustomobject]@{UserId=$sid}},
            [pscustomobject]@{TaskName='RooIndustries.OptimizationSuite.ProcessRules.owned';TaskPath='\';Description=('owner | '+$sid);Principal=[pscustomobject]@{UserId=$sid}},
            [pscustomobject]@{TaskName='RooIndustries.OptimizationSuite.ProcessRules.foreign';TaskPath='\';Description=('owner | '+$foreignSid);Principal=[pscustomobject]@{UserId=$foreignSid}}
        )}
        $out=[ordered]@{checks=@()};$Phase='cleanup';$failure=''
        try{$transcript=@(& $command 2>&1|ForEach-Object {$_|Out-String}) -join ''}catch{$failure=$_.Exception.Message;$transcript=$failure}
        $mustKeep=$case -notin @('success','account-missing')
        $receipt=Test-Path -LiteralPath $ownerPath
        $foreign=@($script:fixture.tasks|Where-Object {$_.Principal.UserId -ceq $foreignSid})
        $passed=($script:fixture.account -eq $mustKeep) -and ($script:fixture.profile -eq $mustKeep) -and ($receipt -eq $mustKeep) -and ((Test-Path -LiteralPath $work) -eq $mustKeep) -and $foreign.Count -eq $(if($case -eq 'foreign'){2}else{1})
        $reported=$failure -or @($out.checks|Where-Object {-not $_.passed}).Count -gt 0
        $passed=$passed -and ([bool]$reported -eq $mustKeep)
        if(-not$mustKeep){$passed=$passed -and $script:fixture.tasks.Count -eq 1}
        if($receipt){$passed=$passed -and (Get-Content -Raw -LiteralPath $ownerPath).Trim() -ceq $sid}
        $rows+=@{case=$case;passed=[bool]$passed;accountPresent=$script:fixture.account;profilePresent=$script:fixture.profile;receiptPresent=$receipt;tasksLeft=@($script:fixture.tasks.TaskName);transcript=$transcript}
        if($case -eq 'foreign'){
            $passed=$passed -and $transcript -like ('*'+$tasks[0]+'*')
            $rows[-1].passed=[bool]$passed
            $script:fixture.tasks=@($script:fixture.tasks|Where-Object TaskName -ne $tasks[0])
        }
        if($mustKeep){
            $script:fixture.fault='';$script:fixture.discoveries=0
            $out=[ordered]@{checks=@()};$failure=''
            try{$transcript=@(& $command 2>&1|ForEach-Object {$_|Out-String}) -join ''}catch{$failure=$_.Exception.Message;$transcript=$failure}
            $passed=-not$failure -and -not$script:fixture.account -and -not$script:fixture.profile -and -not(Test-Path -LiteralPath $work) -and $script:fixture.tasks.Count -eq 1 -and $script:fixture.tasks[0].Principal.UserId -ceq $foreignSid -and @($out.checks|Where-Object {-not $_.passed}).Count -eq 0
            $rows+=@{case=($case+'-retry');passed=[bool]$passed;accountPresent=$script:fixture.account;profilePresent=$script:fixture.profile;receiptPresent=(Test-Path -LiteralPath $ownerPath);tasksLeft=@($script:fixture.tasks.TaskName);transcript=$transcript}
        }
    }
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
$rows|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'other-user-cleanup.json') -Encoding UTF8
foreach($row in $rows){$(if($row.passed){'PASS '}else{'FAIL '})+$row.case}
exit [int](@($rows|Where-Object {-not $_.passed}).Count -gt 0)
