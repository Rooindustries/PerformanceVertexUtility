param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if([string]::IsNullOrWhiteSpace($DotNetPath)){$candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-firmware-page-cli-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){throw "The CLI fixture requires the Windows .NET Framework C# compiler: $compiler"}
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+(Join-Path $fixture 'SCEWIN64.exe')) (Join-Path $root 'tools\validation\fixtures\FirmwareHelperFixture.cs')
    if($LASTEXITCODE -ne 0){throw 'Could not compile the file-only firmware fixture'}
    [IO.File]::WriteAllText((Join-Path $fixture 'fixture-authority.txt'),'roo-industries-firmware-cli-fixture/v1')
    & $DotNetPath run --project (Join-Path $root 'tools\validation\AppSweepUi\AppSweepUi.csproj') --configuration Release -- firmware $fixture
    if($LASTEXITCODE -ne 0){throw 'BIOS page checks failed'}
} finally {Remove-Item -LiteralPath $fixture -Recurse -Force}
