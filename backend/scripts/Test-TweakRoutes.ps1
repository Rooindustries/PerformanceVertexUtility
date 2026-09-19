param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$work=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-tweak-routes-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
$wrapper=Join-Path $PSScriptRoot 'Invoke-WindowsTweaks.ps1'
$router=Join-Path $PSScriptRoot 'Invoke-RooIndustriesCapability.ps1'
$capability='system-optimizations.windows-settings'
function Assert([bool]$condition,[string]$name){if(-not $condition){throw $name};Write-Host ('PASS '+$name)}
function Read-Json($lines){($lines -join [Environment]::NewLine)|ConvertFrom-Json}
function Save($path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
try {
    $fixture=Join-Path $work 'fixture.json'
    $null=& $wrapper -Action CreateFixture -FixturePath $fixture -ConfirmApply -DotNetPath $DotNetPath
    $catalog=Read-Json (& $router -CapabilityId $capability -Action preview)
    Assert ($catalog.status -eq 'completed' -and $catalog.evidence.data.catalog.settings.Count -eq 12) 'Capability preview exposes the executable catalog'
    $preview=Join-Path $work 'preview.json';$request=Join-Path $work 'request.json'
    Save $request @{schemaVersion=1;repoRoot=$root;fixturePath=$fixture;profileId='route-test';presetId='explorer-details';outputPath=$preview}
    $planned=Read-Json (& $router -CapabilityId $capability -Action preview -RequestPath $request)
    Assert ($planned.status -eq 'completed' -and (Test-Path $preview)) 'Capability request creates a reviewed profile plan'
    $hash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash
    Save $request @{schemaVersion=1;repoRoot=$root;fixturePath=$fixture;previewPath=$preview;reviewHash=$hash;confirm=$true}
    $without=Read-Json (& $router -CapabilityId $capability -Action apply -RequestPath $request)
    Assert ($without.status -eq 'approval-required') 'A true confirmation in the payload cannot bypass the router approval gate'
    $applied=Read-Json (& $router -CapabilityId $capability -Action apply -RequestPath $request -ConfirmApply)
    Assert ($applied.status -eq 'completed' -and $applied.changed -and $applied.evidence.data.state.profiles.Count -eq 1) 'Capability apply dispatches the real shared planner against its isolated file fixture'
    $replayed=Read-Json (& $router -CapabilityId $capability -Action apply -RequestPath $request -ConfirmApply)
    Assert ($replayed.status -eq 'completed' -and -not $replayed.changed -and $replayed.evidence.data.replayed) 'Capability retry reports that it did not write settings again'
    $empty=Join-Path $work 'empty.json';[IO.File]::WriteAllText($empty,'[]')
    $restore=Join-Path $work 'restore.json'
    $null=& $wrapper -Action Preview -FixturePath $fixture -ProfileId 'route-test' -SelectionsPath $empty -OutputPath $restore -DotNetPath $DotNetPath
    $restored=Read-Json (& $wrapper -Action Restore -FixturePath $fixture -PreviewPath $restore -ReviewHash (Get-FileHash $restore).Hash -ConfirmApply -DotNetPath $DotNetPath)
    Assert ($restored.status -eq 'completed' -and $restored.data.state.profiles.Count -eq 0) 'Explicit empty selection restores the profile through the public wrapper'
    $raw=[IO.File]::ReadAllText($fixture)|ConvertFrom-Json
    Assert (@($raw.keys.PSObject.Properties).Count -eq 0) 'Public restore removes the fixture-created setting keys'
} finally {Remove-Item -LiteralPath $work -Recurse -Force}
