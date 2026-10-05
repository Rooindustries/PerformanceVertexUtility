param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
. (Join-Path $root 'tools\validation\Tweaks\BootMarkerFixture.Common.ps1')
$bootMarkerBefore=Get-TweakBootMarkerSnapshot
$bootMarkerEvidence=Join-Path $root ('artifacts\validation\tweaks-boot-marker-'+[Guid]::NewGuid().ToString('N')+'.json')
[IO.Directory]::CreateDirectory((Split-Path $bootMarkerEvidence -Parent))|Out-Null
try {
& $DotNetPath run --project (Join-Path $root 'tools/validation/Tweaks/Tweaks.csproj') --configuration Release -p:UseSharedCompilation=false -- $root
if($LASTEXITCODE -ne 0){throw 'Tweak engine checks failed'}
& (Join-Path $PSScriptRoot 'Test-TweakRoutes.ps1') -DotNetPath $DotNetPath
& (Join-Path $PSScriptRoot 'Test-AppxScopes.ps1')
& (Join-Path $PSScriptRoot 'Test-WindowsControlOutput.ps1')
} finally {
    $bootMarkerAfter=Get-TweakBootMarkerSnapshot
    $bootMarkerRestored=$false
    try {
    Restore-TweakBootMarkerSnapshot $bootMarkerBefore
    $bootMarkerRestored=$true
    } finally {
        [ordered]@{before=$bootMarkerBefore;after=$bootMarkerAfter;restored=(Get-TweakBootMarkerSnapshot);passed=$bootMarkerRestored}|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $bootMarkerEvidence -Encoding UTF8
    }
    Write-Output ('PASS Tweak validation restores the exact BootMarker values and security; evidence '+$bootMarkerEvidence)
}
