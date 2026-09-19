param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& $DotNetPath run --project (Join-Path $root 'tools/validation/Tweaks/Tweaks.csproj') --configuration Release -p:UseSharedCompilation=false -- $root
if($LASTEXITCODE -ne 0){throw 'Tweak engine checks failed'}
& (Join-Path $PSScriptRoot 'Test-TweakRoutes.ps1') -DotNetPath $DotNetPath
