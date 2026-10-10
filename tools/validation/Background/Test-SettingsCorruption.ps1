param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$ServiceProbe)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Assert-NoUnownedAppProcess
$directory=Join-Path $OutRoot 'settings-corruption';[IO.Directory]::CreateDirectory($directory)|Out-Null
& (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe') ([IO.Path]::ChangeExtension($ServiceProbe,'.dll')) --settings-corruption (Join-Path $directory 'result.json') *> (Join-Path $directory 'probe.log')
if($LASTEXITCODE){throw 'Settings corruption recovery failed'}
