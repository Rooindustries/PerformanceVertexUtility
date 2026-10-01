param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateSet('All','Fallback')][string]$Scenario='All',[string]$EvidencePath)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-tool-cli-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){throw "The CLI fixture requires the Windows .NET Framework C# compiler: $compiler"}
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+(Join-Path $fixture 'SCEWIN64.exe')) (Join-Path $root 'tools\validation\fixtures\FirmwareHelperFixture.cs')
    if($LASTEXITCODE -ne 0){throw 'Could not compile the file-only firmware fixture'}
    & $compiler /nologo /target:winexe /platform:x64 ('/out:'+(Join-Path $fixture 'IntegrityProbe.exe')) (Join-Path $root 'tools\validation\fixtures\IntegrityProbe.cs')
    if($LASTEXITCODE -ne 0){throw 'Could not compile the token integrity probe'}
    [IO.File]::WriteAllText((Join-Path $fixture 'fixture-authority.txt'),'roo-industries-firmware-cli-fixture/v1')
    if($Scenario -eq 'Fallback'){$env:ROO_INDUSTRIES_TOOL_LAUNCHER_SCENARIO='fallback'}
    if($EvidencePath){$env:ROO_INDUSTRIES_TOOL_LAUNCHER_EVIDENCE=[IO.Path]::GetFullPath($EvidencePath)}
    & $DotNetPath run --project (Join-Path $root 'tools\validation\ToolLauncher\ToolLauncher.csproj') --configuration Release -- $fixture
    if($LASTEXITCODE -ne 0){throw 'Tool launcher checks failed'}
} finally {Remove-Item Env:ROO_INDUSTRIES_TOOL_LAUNCHER_SCENARIO,Env:ROO_INDUSTRIES_TOOL_LAUNCHER_EVIDENCE -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $fixture -Recurse -Force}
