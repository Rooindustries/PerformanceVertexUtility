param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$checks=New-Object System.Collections.Generic.List[object]
function Check([bool]$Passed,[string]$Name,[string]$Detail=''){
    $checks.Add([pscustomobject]@{passed=$Passed;check=$Name;detail=$Detail})
    $(if($Passed){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail
}
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if(-not(Test-Path -LiteralPath $dotnet)){throw 'The verification SDK is unavailable.'}
$install=Join-Path $OutDir 'Roo Industries fixture install'
$hostFolder=Join-Path $install 'backend\bin\optimizer'
$scripts=Join-Path $install 'backend\scripts'
New-Item -ItemType Directory -Path $scripts -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'backend\profiles') -Destination (Join-Path $install 'backend') -Recurse
foreach($name in @(Get-Content -LiteralPath (Join-Path $Source 'tools\release\shipped-scripts.txt')|Where-Object {$_ -and -not $_.StartsWith('#')})){
    Copy-Item -LiteralPath (Join-Path $Source ('backend\scripts\'+$name)) -Destination $scripts
}
& $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release -r win-x64 --self-contained true -p:RooIndustriesRelease=true -p:EnableWindowsTargeting=true -o $hostFolder
if($LASTEXITCODE -ne 0){throw 'The release Host fixture build failed.'}
Check (Test-Path -LiteralPath (Join-Path $hostFolder 'hostpolicy.dll')) 'The fixture uses a self-contained release Host'
$ps=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$cases=@(
    @{name='worker';script='Invoke-ProcessPolicyWorker.ps1';arguments="-Action Status -PolicyRoot '"+(Join-Path $OutDir 'policy')+"'"},
    @{name='cleanup';script='Invoke-CleanupExclusions.ps1';arguments='-Action Status'}
)
foreach($case in $cases){
    $environment=Join-Path $OutDir ($case.name+'-environment.json')
    $script=Join-Path $scripts $case.script
    $body=@"
`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false);`$OutputEncoding=[Console]::OutputEncoding
foreach(`$name in @(Get-ChildItem Env:|Where-Object {`$_.Name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'}|ForEach-Object Name)){Remove-Item -LiteralPath ('Env:\'+`$name)}
`$code=0
try { & '$script' $($case.arguments);`$code=`$LASTEXITCODE } catch { Write-Output ('FATAL '+`$_.Exception.Message);`$code=1 }
[pscustomobject]@{dotnetRoot=[Environment]::GetEnvironmentVariable('DOTNET_ROOT','Process');completed=`$true}|ConvertTo-Json|Set-Content -LiteralPath '$environment' -Encoding UTF8
exit `$code
"@
    $output=Join-Path $OutDir ($case.name+'.out')
    $errorLog=Join-Path $OutDir ($case.name+'.err')
    $child=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))) -PassThru -Wait -RedirectStandardOutput $output -RedirectStandardError $errorLog
    $text=[IO.File]::ReadAllText($output)+[IO.File]::ReadAllText($errorLog)
    Check ($child.ExitCode -eq 0 -and $text -match '"status"\s*:\s*"completed"') ('The shipped '+$case.script+' Status succeeds with the release Host') ('exit='+$child.ExitCode+' '+$text)
    $state=if(Test-Path -LiteralPath $environment){Get-Content -LiteralPath $environment -Raw|ConvertFrom-Json}else{$null}
    Check ($null -ne $state -and $state.completed -eq $true -and $null -eq $state.dotnetRoot) ('The shipped '+$case.script+' leaves no DOTNET_ROOT in its caller') $(if($state){$state|ConvertTo-Json -Compress}else{'Caller did not finish'})
}
$development=Join-Path $OutDir 'Roo Industries development fixture'
$developmentHost=Join-Path $development 'backend\bin\optimizer'
$developmentScripts=Join-Path $development 'backend\scripts'
New-Item -ItemType Directory -Path $developmentScripts -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $install 'backend\profiles') -Destination (Join-Path $development 'backend') -Recurse
Get-ChildItem -LiteralPath $scripts -File|Copy-Item -Destination $developmentScripts
& $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release -r win-x64 --self-contained false -p:RooIndustriesRelease=false -p:EnableWindowsTargeting=true -o $developmentHost
if($LASTEXITCODE -ne 0){throw 'The development Host fixture build failed.'}
$fake=Join-Path $OutDir 'failed-development-host.cmd'
$attempt=Join-Path $OutDir 'failed-development-started.txt'
[IO.File]::WriteAllText($fake,"@echo off`r`necho %DOTNET_ROOT%>`"$attempt`"`r`nexit /b 17`r`n")
foreach($case in $cases){
    foreach($failure in @($false,$true)){
        if($failure){[IO.File]::Delete($attempt)}
        $name=$case.name+'-development-'+$(if($failure){'failure'}else{'success'})
        $environment=Join-Path $OutDir ($name+'-environment.json')
        $script=Join-Path $developmentScripts $case.script
        $runtime=if($failure){$fake}else{$dotnet}
        $prior='C:\Roo Industries prior caller value'
        $body=@"
`$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false);`$OutputEncoding=[Console]::OutputEncoding
foreach(`$entry in @(Get-ChildItem Env:|Where-Object {`$_.Name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'}|ForEach-Object Name)){Remove-Item -LiteralPath ('Env:\'+`$entry)}
`$env:DOTNET_ROOT='$prior';`$code=0
try { & '$script' $($case.arguments) -DotNetPath '$runtime';`$code=`$LASTEXITCODE } catch { Write-Output ('FATAL '+`$_.Exception.Message);`$code=1 }
[pscustomobject]@{dotnetRoot=[Environment]::GetEnvironmentVariable('DOTNET_ROOT','Process');completed=`$true}|ConvertTo-Json|Set-Content -LiteralPath '$environment' -Encoding UTF8
exit `$code
"@
        $output=Join-Path $OutDir ($name+'.out');$errorLog=Join-Path $OutDir ($name+'.err')
        $child=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))) -PassThru -Wait -RedirectStandardOutput $output -RedirectStandardError $errorLog
        $text=[IO.File]::ReadAllText($output)+[IO.File]::ReadAllText($errorLog)
        $state=if(Test-Path -LiteralPath $environment){Get-Content -LiteralPath $environment -Raw|ConvertFrom-Json}else{$null}
        Check ($null -ne $state -and $state.completed -eq $true -and $state.dotnetRoot -ceq $prior) ('The development '+$case.script+' restores the exact prior DOTNET_ROOT after '+$(if($failure){'child failure'}else{'success'})) ('exit='+$child.ExitCode+' '+$text)
        Check $(if($failure){$child.ExitCode -ne 0 -and (Test-Path -LiteralPath $attempt) -and $text -match 'failed|FATAL'}else{$child.ExitCode -eq 0 -and $text -match '"status"\s*:\s*"completed"'}) ('The development '+$case.script+' actually '+$(if($failure){'starts the failing child and surfaces its error'}else{'completes its native Host Status request'})) ('exit='+$child.ExitCode+' '+$text)
    }
}
$passed=@($checks|Where-Object {-not $_.passed}).Count -eq 0
[pscustomobject]@{passed=$passed;checks=$checks.ToArray();source=$Source;install=$install}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
exit [int](-not $passed)
