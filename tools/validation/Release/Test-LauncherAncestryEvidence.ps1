param([Parameter(Mandatory=$true)][string]$LauncherCommon,[Parameter(Mandatory=$true)][string]$Chain,[Parameter(Mandatory=$true)][string]$TaskXml,[Parameter(Mandatory=$true)][string]$OutDir,[switch]$Before)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$system=[Environment]::SystemDirectory
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($LauncherCommon,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Launcher common script does not parse'}
$function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Check-Chain'},$true))
if($function.Count -ne 1){throw 'Exactly one actual Check-Chain implementation is required'}
. ([scriptblock]::Create($function[0].Extent.Text))
$captured=Get-Content -Raw -LiteralPath $Chain|ConvertFrom-Json
if($captured.Count -ne 3 -or $captured[0].name -cne 'Optimizer.Host.exe' -or $captured[1].name -cne 'cmd.exe' -or $captured[2].name -cne 'conhost.exe'){throw 'Exact three-actor native chain is required'}
$actionArguments=([xml](Get-Content -Raw -LiteralPath $TaskXml)).Task.Actions.Exec.Arguments
if(-not$actionArguments){throw 'Actual registered task action is required'}
$checks=[Collections.Generic.List[object]]::new()
function Process-Row([int]$processId){@($script:Rows|Where-Object {$_.ProcessId -eq $processId -and $_.ProcessId -notin $script:Missing})|Select-Object -First 1}
function Check([bool]$Passed,[string]$Name,[string]$Detail){$script:Observed.Add(@{passed=$Passed;check=$Name;detail=$Detail})}
function Case([string]$Name,[bool]$Expected,[scriptblock]$Change){
 $script:Rows=@($captured|ForEach-Object {[pscustomobject]@{ProcessId=$_.pid;ParentProcessId=$_.parent;Name=$_.name;ExecutablePath=$_.image;CreationDate=[DateTime]::Parse($_.created);CommandLine=$_.commandLine}})
 $script:Missing=@();$script:Observed=[Collections.Generic.List[object]]::new()
 & $Change
 Check-Chain $Name $script:Rows[0] $actionArguments
 $ok=$script:Observed.Count -eq 1 -and $script:Observed[0].passed -eq $Expected
 $checks.Add(@{passed=$ok;check=$Name;expected=$Expected;actual=$(if($script:Observed.Count){$script:Observed[0].passed}else{$null});observations=$script:Observed.ToArray()})
 if(-not$ok){throw ('Ancestry evidence case failed: '+$Name)}
 'PASS '+$Name
}
$tail=$actionArguments -replace '^--headless\s+"[^"]*cmd\.exe"\s*',''
try{
 Case 'actual-native-unquoted-SET' (-not$Before) {}
 Case 'equivalent-quoted-SET' $true {$script:Rows[1].CommandLine=$script:Rows[1].ExecutablePath+' '+$tail}
 Case 'quoted-cmd-image-accepted' $true {$script:Rows[1].CommandLine='"'+$script:Rows[1].ExecutablePath+'" '+$tail}
 Case 'foreign-SystemRoot-value-refused' $false {$script:Rows[1].CommandLine=$script:Rows[1].CommandLine.Replace('SystemRoot=C:\WINDOWS','SystemRoot=C:\OtherWindows')}
 Case 'different-SET-variable-refused' $false {$script:Rows[1].CommandLine=$script:Rows[1].CommandLine.Replace('SystemRoot=','ComSpec=')}
 Case 'changed-clean-helper-path-refused' $false {$script:Rows[1].CommandLine=$script:Rows[1].CommandLine.Replace('Start-RooIndustriesHelper.cmd','OtherHelper.cmd')}
 Case 'changed-packed-request-refused' $false {$script:Rows[1].CommandLine=$script:Rows[1].CommandLine.Replace('worker-request.json','other-request.json')}
 Case 'foreign-cmd-image-refused' $false {$script:Rows[1].ExecutablePath='C:\Users\Public\cmd.exe'}
 Case 'foreign-conhost-image-refused' $false {$script:Rows[2].ExecutablePath='C:\Users\Public\conhost.exe'}
 Case 'missing-parent-refused' $false {$script:Missing=@($script:Rows[1].ProcessId)}
 Case 'wrong-conhost-parent-refused' $false {$script:Rows[1].ParentProcessId=2147483647}
 Case 'conhost-created-after-cmd-refused' $false {$script:Rows[2].CreationDate=$script:Rows[1].CreationDate.AddSeconds(1)}
 Case 'parent-created-after-worker-refused' $false {$script:Rows[1].CreationDate=$script:Rows[0].CreationDate.AddSeconds(1)}
 if(-not$Before){
  Case 'extra-cmd-command-refused' $false {$script:Rows[1].CommandLine+='&echo unexpected'}
  Case 'changed-conhost-action-refused' $false {$script:Rows[2].CommandLine=$script:Rows[2].CommandLine.Replace('worker-request.json','other-request.json')}
 }
}finally{
 [ordered]@{phase='launcher-ancestry-evidence';machine=$env:COMPUTERNAME;before=[bool]$Before;checks=$checks.ToArray();launcherSha256=(Get-FileHash -LiteralPath $LauncherCommon).Hash;nativeChainSha256=(Get-FileHash -LiteralPath $Chain).Hash;taskXmlSha256=(Get-FileHash -LiteralPath $TaskXml).Hash}|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}
