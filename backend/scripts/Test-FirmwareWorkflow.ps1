param([string]$DotNetPath=$env:ROO_DOTNET_EXE)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('roo-firmware-cli-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){throw "The CLI fixture requires the Windows .NET Framework C# compiler: $compiler"}
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+(Join-Path $fixture 'SCEWIN64.exe')) (Join-Path $root 'tools\validation\fixtures\FirmwareHelperFixture.cs')
    if($LASTEXITCODE -ne 0){throw 'Could not compile the file-only firmware fixture'}
    [IO.File]::WriteAllText((Join-Path $fixture 'fixture-authority.txt'),'roo-firmware-cli-fixture/v1')
    & $DotNetPath run --project (Join-Path $root 'tools\validation\OptimizerCore\OptimizerCore.csproj') --configuration Release -- --firmware
    if($LASTEXITCODE -ne 0){throw 'Firmware state checks failed'}
    & $DotNetPath run --project (Join-Path $root 'tools\validation\OptimizerCore\OptimizerCore.csproj') --configuration Release -- --firmware-provider $fixture
    if($LASTEXITCODE -ne 0){throw 'Firmware CLI adapter checks failed'}
} finally {Remove-Item -LiteralPath $fixture -Recurse -Force}
