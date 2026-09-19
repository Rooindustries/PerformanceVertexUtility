param([string]$DotNetPath=$env:ROO_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& (Join-Path $root 'backend/scripts/Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){throw 'Session package build failed'}
& $DotNetPath publish (Join-Path $root 'tools/validation/ProtectedSessions/ProtectedSessions.csproj') -c Release -o (Join-Path $root 'tools/validation/ProtectedSessions/bin/publish') -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'GPU fixture build failed'}
& $DotNetPath run --project (Join-Path $root 'tools/validation/ClientBoundary/ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -- $root --game-sessions
if($LASTEXITCODE -ne 0){throw 'Game-session client checks failed'}
