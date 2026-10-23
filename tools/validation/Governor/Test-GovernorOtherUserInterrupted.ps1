$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$fixture=Join-Path $PSScriptRoot 'Test-GovernorOtherUser.ps1'
$account='rigovtest'
$work=Join-Path $env:ProgramData 'RooIndustriesGovernorTest'
$ownerPath=Join-Path $work 'fixture-owner.txt'
$out=[ordered]@{atUtc=[DateTime]::UtcNow.ToString('o');checks=@()}
function Check([bool]$Condition,[string]$Message){$script:out.checks+=[ordered]@{passed=$Condition;check=$Message};if($Condition){"PASS $Message"}else{"FAIL $Message"}}
function Invoke-Fixture([string[]]$Arguments){
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$text=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixture @Arguments 2>&1|Out-String)}finally{$ErrorActionPreference=$previous}
    [ordered]@{exit=$LASTEXITCODE;text=$text}
}
function Current-Sid{try{(Get-LocalUser -Name $account -ErrorAction Stop).SID.Value}catch{$null}}

if(Test-Path -LiteralPath $work){throw 'The test folder already exists; run the fixture cleanup first.'}
if(Current-Sid){throw 'The test account already exists and was not created by this test.'}
$createdSid=$null
$setupStarted=$false
try{
    $setupStarted=$true
    $setup=Invoke-Fixture @('-Phase','setup','-InterruptAfter','account-created')
    $createdSid=Current-Sid
    $out.setupExit=$setup.exit
    Check ($setup.exit -ne 0 -and $null -ne $createdSid) 'Setup stopped right after creating the test account'
    $cleanup=Invoke-Fixture @('-Phase','cleanup')
    $out.cleanup=$cleanup.text
    Check ((Current-Sid) -ceq $createdSid -and (Test-Path -LiteralPath $ownerPath) -and $cleanup.text -match 'FAIL Setup stopped before recording the test account') 'Cleanup after that stop keeps the account and the setup record and reports it'
}finally{
    if(-not $createdSid -and $setupStarted){$createdSid=Current-Sid}
    if($createdSid -and (Current-Sid) -ceq $createdSid){
        $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
        try{& net.exe user $account /delete 2>&1|Out-Null}finally{$ErrorActionPreference=$previous}
    }
    if(-not(Current-Sid)){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}
Check (-not(Current-Sid) -and -not(Test-Path -LiteralPath $work)) 'The test removed the account and folder it created'
$out|ConvertTo-Json -Depth 5
if(@($out.checks|Where-Object {-not $_.passed}).Count -gt 0){exit 1}
