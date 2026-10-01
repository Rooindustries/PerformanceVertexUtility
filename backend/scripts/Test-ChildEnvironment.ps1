param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateSet('all','control-helper','restart','hibernation','cleanup-temp-root','registry-hook','firmware-provider','firmware-extractor','host-script','host-watcher','session-host-watcher','app-host','app-script','app-live-script','app-capability-script')][string]$Scenario='all',[switch]$Release)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$mode=if($Release){'release'}else{'dev'}
$properties=@();if($Release){$properties+='-p:RooIndustriesRelease=true'}
$core=Join-Path $root 'tools\validation\OptimizerCore\OptimizerCore.csproj'
$boundary=Join-Path $root 'tools\validation\ClientBoundary\ClientBoundary.csproj'
$scenarios=if($Scenario -eq 'all'){@('control-helper','restart','hibernation','cleanup-temp-root','firmware-provider','firmware-extractor','host-script','host-watcher','session-host-watcher','app-host','app-script','app-live-script','app-capability-script','registry-hook')}else{@($Scenario)}
$work=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-child-env-run-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
$failed=@()
function Compile([string]$Source,[string]$Output){
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){throw "The fixtures need the Windows .NET Framework C# compiler: $compiler"}
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+$Output) (Join-Path $root ('tools\validation\fixtures\'+$Source))
    if($LASTEXITCODE -ne 0){throw "Could not compile $Source"}
}
try {
    foreach($name in $scenarios){
        Write-Output ('=== '+$name+' ('+$mode+')')
        switch -Wildcard ($name){
            'app-*' {& $DotNetPath run --project $boundary --configuration Release @properties -- $root '--child-environment' $name $mode}
            'firmware-*' {
                $fixture=Join-Path $work 'firmware';[IO.Directory]::CreateDirectory($fixture)|Out-Null
                if(-not(Test-Path (Join-Path $fixture 'SCEWIN64.exe'))){
                    Compile 'FirmwareHelperFixture.cs' (Join-Path $fixture 'SCEWIN64.exe')
                    Compile 'EnvironmentReporter.cs' (Join-Path $fixture 'EnvironmentReporter.exe')
                    [IO.File]::WriteAllText((Join-Path $fixture 'fixture-authority.txt'),'roo-industries-firmware-cli-fixture/v1')
                }
                & $DotNetPath run --project $core --configuration Release @properties -- '--child-env' $name $mode $fixture
            }
            'host-*' {
                $binaries=Join-Path $work ('host-'+$mode)
                if(-not(Test-Path $binaries)){& $DotNetPath publish (Join-Path $root 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $binaries @properties|Out-Null;if($LASTEXITCODE -ne 0){throw 'Optimizer host publish failed.'}}
                & $DotNetPath run --project $core --configuration Release @properties -- '--child-env' $name $mode $binaries
            }
            'session-host-watcher' {
                $binaries=Join-Path $work ('session-host-'+$mode)
                if(-not(Test-Path $binaries)){& $DotNetPath publish (Join-Path $root 'backend\native\Optimizer.SessionHost\Optimizer.SessionHost.csproj') -c Release -o $binaries @properties|Out-Null;if($LASTEXITCODE -ne 0){throw 'Session host publish failed.'}}
                & $DotNetPath run --project $core --configuration Release @properties -- '--child-env' $name $mode $binaries
            }
            'registry-hook' {& $DotNetPath run --project $core --configuration Release @properties '-p:RooTestHooks=true' -- '--child-env' $name $mode}
            default {& $DotNetPath run --project $core --configuration Release @properties -- '--child-env' $name $mode}
        }
        if($LASTEXITCODE -ne 0){$failed+=$name;Write-Output ('FAILED '+$name+' (exit '+$LASTEXITCODE+')')}
    }
} finally {Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
if($failed.Count -gt 0){throw ('Child-environment scenarios failed: '+($failed -join ', '))}
Write-Output ('Child-environment scenarios passed in '+$mode+' mode: '+($scenarios -join ', '))
