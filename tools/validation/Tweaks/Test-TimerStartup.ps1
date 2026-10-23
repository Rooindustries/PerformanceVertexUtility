param(
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Timer startup validation requires Windows.' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Split-Path $root -Parent
if (-not $DotNetPath) {
    $candidate = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    $DotNetPath = if (Test-Path -LiteralPath $candidate) { $candidate } else { (Get-Command dotnet.exe -ErrorAction Stop).Source }
}
if (Test-Path -LiteralPath $OutRoot) { throw 'The timer startup evidence directory must be new.' }
[void][IO.Directory]::CreateDirectory($OutRoot)
$build = Join-Path $OutRoot 'host'
$succeeded = $false
try {
    & $DotNetPath publish (Join-Path $root 'tools\validation\Tweaks\Tweaks.csproj') --configuration Release --runtime win-x64 --self-contained true -p:TimerStartupFixture=true -p:GovernorTestHooks=true -p:UseSharedCompilation=false --output $build 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'publish.log')
    if ($LASTEXITCODE -ne 0) { throw 'The timer startup fixture host did not publish.' }
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & (Join-Path ([Environment]::SystemDirectory) 'icacls.exe') $build '/grant:r' ('*' + $userSid + ':(OI)(CI)(RX)') '/T' 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'host-access.log')
    if ($LASTEXITCODE -ne 0) { throw 'The fixture host could not be made readable by its normal-user task.' }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & (Join-Path $build 'Optimizer.Host.exe') $root --timer-startup-fixture (Join-Path $OutRoot 'proof') 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'checks.log')
        $fixtureExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($fixtureExit -ne 0) { throw 'Timer startup checks failed.' }
    $succeeded = $true
} finally {
    if ($succeeded -and (Test-Path -LiteralPath $build)) { [IO.Directory]::Delete($build, $true) }
    if (-not $succeeded) { Write-Output ('Timer startup proof and fixture host retained at ' + $OutRoot) }
}
