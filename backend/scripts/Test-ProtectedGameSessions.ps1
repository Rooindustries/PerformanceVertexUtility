param([string]$DotNetPath='', [switch]$HardwareGpu)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& (Join-Path $PSScriptRoot 'Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){throw 'Native session package build failed'}
$bin=Join-Path $root 'tools\validation\ProtectedSessions\bin\publish'
& $DotNetPath publish (Join-Path $root 'tools\validation\ProtectedSessions\ProtectedSessions.csproj') -c Release -o $bin -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'Protected-session validation build failed'}
$arguments=@((Join-Path $bin 'RooLaunchPolicyProbe.dll'),$root,$DotNetPath)
if($HardwareGpu){$arguments+='--hardware-gpu'}
& $DotNetPath @arguments
if($LASTEXITCODE -ne 0){throw 'Protected-session validation failed'}
