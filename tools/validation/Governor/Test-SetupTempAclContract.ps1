param(
    [Parameter(Mandatory=$true)][string]$Frame,
    [ValidateSet('before','after')][string]$Scenario='after'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($env:COMPUTERNAME -cne 'CS2-GEN4' -or $identity.User.Value -cne 'S-1-5-21-1846494563-3099854232-4004002307-1001' -or -not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Unexpected fixture machine, SID or token'}
if($Frame -notmatch '^C:\\RooBuild\\[0-9a-f]{32}$'){throw 'Fixture frame must be a new GUID child of C:\RooBuild'}
foreach($path in 'C:\RooBuild',$Frame){
    $item=Get-Item -LiteralPath $path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse fixture frame'}
    $acl=Get-Acl -LiteralPath $path
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Fixture frame is not protected'}
    foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and ([long]$ace.FileSystemRights -band 0x500D0156)){throw 'Non-admin fixture writer'}}
}
$env:TEMP=$Frame;$env:TMP=$Frame
$source=Join-Path $Frame 'source'
. (Join-Path $source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
$helper=Join-Path $source 'tools\validation\Governor\Measure-SetupTempAcl.ps1'
$runner=Join-Path $source 'tools\validation\Release\Invoke-IntegrationVerification.ps1'
$tokens=$null;$parseErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Runner parser errors'}
$runAst=@($runnerAst.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Run'},$false))
if($runAst.Count -ne 1){throw 'Expected one real Run function'}
Invoke-Expression $runAst[0].Extent.Text
$text=Get-Content -Raw -LiteralPath $helper
$helperAst=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Helper parser errors'}
$isolations=@($helperAst.FindAll({param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left -is [Management.Automation.Language.VariableExpressionAst] -and $a.Left.VariablePath.UserPath -cin @('app','roots')},$false))
if($isolations.Count -ne 2){throw 'Expected exactly app and roots observation assignments'}
$temp=Join-Path $Frame 'temp'
New-Item -ItemType Directory -Path $temp|Out-Null
$existing=Join-Path $temp 'is-existing.tmp'
New-Item -ItemType Directory -Path $existing|Out-Null
$sentinelFile=Join-Path $existing 'keep.txt'
[IO.File]::WriteAllText($sentinelFile,'unrelated-existing-temp')
$beforeHash=(Get-FileHash -LiteralPath $sentinelFile).Hash
foreach($a in @($isolations|Sort-Object {$_.Right.Extent.StartOffset} -Descending)){
    $replacement=if($a.Left.VariablePath.UserPath -ceq 'app'){"'"+(Join-Path $Frame 'absent-app').Replace("'","''")+"'"}else{"@('"+$temp.Replace("'","''")+"')"}
    $text=$text.Substring(0,$a.Right.Extent.StartOffset)+$replacement+$text.Substring($a.Right.Extent.EndOffset)
}
$isolated=Join-Path (Split-Path $helper) 'Measure-SetupTempAcl.fixture.ps1'
[IO.File]::WriteAllText($isolated,$text,[Text.UTF8Encoding]::new($true))
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$fixtureSource=Join-Path $Frame 'Fixture.cs'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
class Fixture {
 static int Main(string[] args) {
  string log=null;
  foreach(string a in args) if(a.StartsWith("/LOG=")) log=a.Substring(5).Trim('"');
  if(log==null) return 91;
  using(Process p=Process.GetCurrentProcess()) {
   File.WriteAllText(log+".fixture.json","{\"pid\":"+p.Id+",\"creationTimeFileTimeUtc\":\""+p.StartTime.ToUniversalTime().ToFileTimeUtc()+"\",\"imagePath\":\""+p.MainModule.FileName.Replace("\\","\\\\")+"\"}");
   string name=Path.GetFileNameWithoutExtension(p.MainModule.FileName);
   Thread.Sleep(name.Contains("Timeout") || name.Contains("Sentinel") ? 60000 : 800);
   return name.Contains("Fail") ? 7 : 0;
  }
 }
}
'@|Set-Content -LiteralPath $fixtureSource -Encoding UTF8
& $compiler /nologo /target:exe ('/out:'+(Join-Path $Frame 'FixtureOk.exe')) $fixtureSource
if($LASTEXITCODE -ne 0){throw 'Native fixture compilation failed'}
foreach($name in 'Fail','Timeout','Sentinel'){Copy-Item -LiteralPath (Join-Path $Frame 'FixtureOk.exe') -Destination (Join-Path $Frame ('Fixture'+$name+'.exe'))}
$Evidence=Join-Path $Frame $Scenario
New-Item -ItemType Directory -Path $Evidence|Out-Null
$Phase='fixture'
$script:Checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Ok,[string]$Name,[string]$Detail=''){$script:Checks.Add([pscustomobject]@{passed=$Ok;name=$Name;detail=$Detail});Write-Output ($(if($Ok){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail)}
function Require([bool]$Ok,[string]$Name){if(-not $Ok){throw $Name};Write-Output ('PASS E2E '+$Name)}
function Invoke-Case([string]$Name,[string]$Executable,[bool]$ExpectedPass,[int]$Timeout=0){
    $out=Join-Path $Evidence $Name
    $arguments=@{Installer=(Join-Path $Frame $Executable);OutDir=$out}
    if($Timeout){$arguments.TimeoutSeconds=$Timeout}
    $index=$script:Checks.Count
    Run $Name {if($Name -ceq 'exit0'){& (Join-Path $Frame 'FixtureFail.exe') ('/LOG="'+(Join-Path $Evidence 'prior-native.log')+'"')}; & $isolated @arguments}
    Require ($script:Checks.Count -eq $index+1 -and $script:Checks[$index].passed -eq $ExpectedPass) ($Name+' real Run guard matches '+$ExpectedPass)
    $result=Get-Content -Raw -LiteralPath (Join-Path $out 'setup-temp-acl.json')|ConvertFrom-Json
    $native=Get-Content -Raw -LiteralPath (Join-Path $out 'setup.log.fixture.json')|ConvertFrom-Json
    if($Name -cin @('exit0','exit0-json-only')){Require ($result.exit -is [int] -and $result.exit -eq 0) ($Name+' actual native exit zero')}
    if($Scenario -ceq 'after'){
        Require ($result.process.pid -eq $native.pid -and $result.process.creationTimeFileTimeUtc -ceq $native.creationTimeFileTimeUtc -and $result.process.imagePath -ieq ('\\?\'+$native.imagePath)) ($Name+' actual native identity recorded')
        Require ($result.exit -is [int] -and $result.completed -eq $ExpectedPass -and ($result.status -ceq 'completed') -eq $ExpectedPass) ($Name+' completion fields agree')
        if($Name -ceq 'exit7'){Require ($result.exit -eq 7) 'native exit 7 retained'}
        if($Name -ceq 'timeout'){Require ($result.status -ceq 'timeout' -and -not $result.completed -and $result.exit -ne 0) 'timeout cannot become success'}
        Require (-not (Get-Process -Id $native.pid -ErrorAction SilentlyContinue)) ($Name+' native fixture exited')
    }
}
$sentinel=$null;$owned=$null;$suiteCompleted=$false
try {
    if($Scenario -ceq 'before'){
        Invoke-Case 'exit0-json-only' 'FixtureOk.exe' $false
        Write-Output 'PASS E2E reproduced VR22: actual exit zero, JSON only, real Run rejected'
    }else{
        $sentinel=Start-Process -FilePath (Join-Path $Frame 'FixtureSentinel.exe') -ArgumentList ('/LOG="'+(Join-Path $Evidence 'sentinel.log')+'"') -PassThru
        $owned=New-OwnedProcess $sentinel
        if(-not $owned){throw 'Sentinel ownership receipt missing'}
        Invoke-Case 'exit0' 'FixtureOk.exe' $true
        Invoke-Case 'exit7' 'FixtureFail.exe' $false
        Invoke-Case 'timeout' 'FixtureTimeout.exe' $false 2
        $badOut=Join-Path $Evidence 'missing-completion-evidence'
        New-Item -ItemType Directory -Path (Join-Path $badOut 'setup-temp-acl.json') -Force|Out-Null
        $index=$script:Checks.Count
        Run 'missing-completion-evidence' {& $isolated -Installer (Join-Path $Frame 'FixtureOk.exe') -OutDir $badOut}
        Require (-not $script:Checks[$index].passed) 'actual exit zero cannot pass when completion evidence cannot be written'
        $missingNative=Get-Content -Raw -LiteralPath (Join-Path $badOut 'setup.log.fixture.json')|ConvertFrom-Json
        Require (-not (Get-Process -Id $missingNative.pid -ErrorAction SilentlyContinue)) 'missing-completion native fixture exited'
        Require (-not $sentinel.HasExited) 'unrelated native sentinel survived timeout'
        foreach($case in @(@{name='missing';text=''},@{name='malformed';text='PASS'},@{name='json-without-completion';text='{"status":"completed","exit":0}'})){
            $index=$script:Checks.Count
            Run $case.name {$case.text}
            Require (-not $script:Checks[$index].passed) ($case.name+' cannot pass real Run guard')
        }
    }
    Require ((Get-FileHash -LiteralPath $sentinelFile).Hash -ceq $beforeHash) 'pre-existing temporary directory retained'
    $suiteCompleted=$true
}finally{
    if($owned){Stop-OwnedProcess $owned}
    if($sentinel){$sentinel.Dispose()}
    $leftovers=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($Frame+'\',[StringComparison]::OrdinalIgnoreCase)}|Select-Object ProcessId,ExecutablePath)
    [ordered]@{completed=($suiteCompleted -and $leftovers.Count -eq 0);scenario=$Scenario;frame=$Frame;machine=$env:COMPUTERNAME;sid=$identity.User.Value;helperSha256=(Get-FileHash $helper).Hash;isolatedHelperSha256=(Get-FileHash $isolated).Hash;runnerSha256=(Get-FileHash $runner).Hash;fixtureSha256=(Get-FileHash (Join-Path $Frame 'FixtureOk.exe')).Hash;checks=@($script:Checks);sentinel=$(if($owned){$owned.Identity}else{$null});fixtureProcessesLeft=$leftovers}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $Evidence 'contract.json') -Encoding UTF8
    Require ($leftovers.Count -eq 0) 'no native fixture processes remain'
}
