param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir,[Parameter(Mandatory=$true)][string[]]$Arguments,[ValidateSet('OptimizerCore','AppSweepUi','ProtectedSessions')][string]$Project='OptimizerCore')
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$start=[Diagnostics.ProcessStartInfo]::new($dotnet)
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
$projectPath=Join-Path $Source ('tools\validation\'+$Project+'\'+$Project+'.csproj')
$start.Arguments='run --project "'+$projectPath+'" --configuration Release -p:GovernorTestHooks=true -- '+($Arguments -join ' ')
if($Project -eq 'ProtectedSessions'){
    & $dotnet build $projectPath -c Release -p:GovernorTestHooks=true
    if($LASTEXITCODE -ne 0){throw 'The protected-session fixture build failed.'}
    $dll=Join-Path $Source 'tools\validation\ProtectedSessions\bin\Release\net8.0-windows\RooIndustriesLaunchPolicyProbe.dll'
    $start.Arguments='"'+$dll+'" '+($Arguments -join ' ')
}
$start.EnvironmentVariables['DOTNET_ROOT']=Split-Path $dotnet
$start.EnvironmentVariables['ROO_INDUSTRIES_SCENARIO_CONTINUE']='1'
$child=[Diagnostics.Process]::Start($start)
try {
    $output=$child.StandardOutput.ReadToEndAsync();$errorText=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(600000)){$child.Kill();throw 'The private core scenario timed out.'}
    $text=$output.Result+"`n"+$errorText.Result
    [IO.File]::WriteAllText((Join-Path $OutDir 'native.log'),$text,[Text.UTF8Encoding]::new($false))
    Write-Output $text
    $checks=@($text -split '\r?\n'|Where-Object {$_ -match '^(PASS|FAIL) '}|ForEach-Object {[pscustomobject]@{passed=$_.StartsWith('PASS ');check=$_.Substring(5)}})
    $passed=$child.ExitCode -eq 0 -and $checks.Count -gt 0 -and @($checks|Where-Object {-not $_.passed}).Count -eq 0 -and $text -notmatch '(?m)^(SKIP|NOT RUN|FATAL) '
    [pscustomobject]@{passed=$passed;checks=$checks;exit=$child.ExitCode;arguments=$Arguments;source=$Source}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
} finally {$child.Dispose()}
exit [int](-not $passed)
