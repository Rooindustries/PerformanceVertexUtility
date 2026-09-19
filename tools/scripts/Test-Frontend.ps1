param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& $DotNetPath run --project (Join-Path $root 'tools/validation/MemoryDisplay/MemoryDisplay.csproj') --configuration Release
if($LASTEXITCODE -ne 0){throw 'Memory display checks failed'}
& (Join-Path $PSScriptRoot 'Build-Frontend.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){throw 'Frontend build failed'}
