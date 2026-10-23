param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE, [ValidateSet('','launch-profiles','session-recovery','cleanup-failure','recovery-completion','launch-profile-same-name')][string]$Mode='')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& $DotNetPath run --project (Join-Path $root 'tools/validation/ClientBoundary/ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -- $root --game-session-display
if($LASTEXITCODE -ne 0){throw 'Game-session display checks failed'}
& (Join-Path $root 'backend/scripts/Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){throw 'Session package build failed'}
& $DotNetPath publish (Join-Path $root 'backend/native/Optimizer.Host/Optimizer.Host.csproj') -c Release -r win-x64 --self-contained true -o (Join-Path $root 'backend/bin/optimizer') -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'Release helper build failed'}
& $DotNetPath publish (Join-Path $root 'tools/validation/ProtectedSessions/ProtectedSessions.csproj') -c Release -o (Join-Path $root 'tools/validation/ProtectedSessions/bin/publish') -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'GPU fixture build failed'}
$suite=if($Mode){'--'+$Mode}else{'--game-sessions'}
$previousRuntimeRoot=$env:DOTNET_ROOT_X64
try{
    $env:DOTNET_ROOT_X64=Split-Path (Get-Command $DotNetPath -ErrorAction Stop).Source -Parent
    & $DotNetPath run --project (Join-Path $root 'tools/validation/ClientBoundary/ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -- $root $suite
    if($LASTEXITCODE -ne 0){throw ('Game-session client checks failed: '+$suite)}
}
finally{$env:DOTNET_ROOT_X64=$previousRuntimeRoot}
