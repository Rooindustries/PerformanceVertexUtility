param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$PublishedVersion,[Parameter(Mandatory)][string]$AlphaVersion,[Parameter(Mandatory)][string]$PublishedApp)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'Build-ShippedAlpha' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Initialize-HarnessBuildFolders $Source
$env:ROO_HARNESS_NONCE=$nonce

$copy=Join-Path $OutRoot 'src'
if(Test-Path $copy){throw 'Alpha source already exists; allocate a fresh frame.'}
New-HarnessDirectory $copy 'build-source'|Out-Null
$differences=@()
foreach($file in Get-ChildItem -LiteralPath $Source -File -Recurse){
 $relative=$file.FullName.Substring($Source.Length).TrimStart('\')
 if($relative -match '(^|\\)(obj|bin|artifacts|\.git)(\\|$)' -or $relative -eq 'source-verification.json'){continue}
 $destination=Join-Path $copy $relative
 [IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
 Copy-Item -LiteralPath $file.FullName -Destination $destination
}
$relative='docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
$project=Join-Path $copy $relative
$text=[IO.File]::ReadAllText($project)
if([regex]::Matches($text,'<Version>'+[regex]::Escape($PublishedVersion)+'</Version>').Count -ne 1){throw 'Expected exactly one published Version element.'}
[IO.File]::WriteAllText($project,$text.Replace('<Version>'+$PublishedVersion+'</Version>','<Version>'+$AlphaVersion+'</Version>'),[Text.UTF8Encoding]::new($false))
foreach($file in Get-ChildItem -LiteralPath $Source -File -Recurse){
 $name=$file.FullName.Substring($Source.Length).TrimStart('\')
 if($name -match '(^|\\)(obj|bin|artifacts|\.git)(\\|$)' -or $name -eq 'source-verification.json'){continue}
 if((Get-FileHash $file.FullName).Hash -cne (Get-FileHash (Join-Path $copy $name)).Hash){$differences+=$name}
}
$expectedFiles=@(Get-ChildItem $Source -File -Recurse|Where-Object {$_.FullName.Substring($Source.Length) -notmatch '(^|\\)(obj|bin|artifacts|\.git)(\\|$)' -and $_.Name -ne 'source-verification.json'}).Count
if(@(Get-ChildItem $copy -File -Recurse).Count -ne $expectedFiles){throw 'Alpha whole-tree file set differs.'}
if([IO.File]::ReadAllText($project).Replace('<Version>'+$AlphaVersion+'</Version>','<Version>'+$PublishedVersion+'</Version>') -cne $text){throw 'Alpha csproj differs beyond the one Version line.'}
if($differences.Count -ne 1 -or $differences[0] -ne $relative){throw 'Alpha product tree differs beyond Version.'}
Write-HarnessResult $OutRoot 'alpha-source-binding.json' @{differences=$differences;beforeVersion=$PublishedVersion;afterVersion=$AlphaVersion;source=$Source;copy=$copy}|Out-Null
New-HarnessDirectory (Join-Path $OutRoot 'release') 'release-output'|Out-Null
New-HarnessDirectory (Join-Path $OutRoot 'probe') 'probe-output'|Out-Null
Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $copy 'tools\scripts\Build-Release.ps1')+'" -OutputRoot "'+(Join-Path $OutRoot 'release')+'"') 'build-alpha'|Out-Null
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
Invoke-HarnessProcess $dotnet ('publish "'+(Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj')+'" -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o "'+(Join-Path $OutRoot 'probe')+'"') 'build-alpha-probe'|Out-Null
$app=Join-Path $OutRoot ('release\work-'+$AlphaVersion+'\stage\app\RooIndustries.OptimizationSuite.App.dll')
$feedOutput=Get-HarnessOutputPath $OutRoot 'embedded-feed.json'
Invoke-HarnessProcess (Join-Path $OutRoot 'probe\UpdateProbe.exe') ('--embedded-feed "'+$app+'" "'+$feedOutput+'"') 'embedded-feed'|Out-Null
$feedRecord=Get-Content -Raw $feedOutput|ConvertFrom-Json;if($feedRecord.nonce -cne $nonce){throw 'Embedded feed result nonce differs.'};Register-HarnessFile $feedOutput 'probe-result'|Out-Null;$actual=$feedRecord.data.feed
$expected='url='+([IO.File]::ReadAllText((Join-Path $Source 'tools\release\update-feed.txt')).Trim())
if($actual -cne $expected){throw 'Built alpha does not embed the committed production feed.'}

$publishedOutput=Get-HarnessOutputPath $OutRoot 'published-resources.json';$alphaOutput=Get-HarnessOutputPath $OutRoot 'alpha-resources.json'
Invoke-HarnessProcess (Join-Path $OutRoot 'probe\UpdateProbe.exe') ('--resources "'+$PublishedApp+'" "'+$publishedOutput+'"') 'resources'|Out-Null
Invoke-HarnessProcess (Join-Path $OutRoot 'probe\UpdateProbe.exe') ('--resources "'+$app+'" "'+$alphaOutput+'"') 'resources'|Out-Null
$p=Get-Content -Raw $publishedOutput|ConvertFrom-Json;$a=Get-Content -Raw $alphaOutput|ConvertFrom-Json;if($p.nonce -cne $nonce -or $a.nonce -cne $nonce){throw 'Resource output nonce differs.'};Register-HarnessFile $publishedOutput 'probe-result'|Out-Null;Register-HarnessFile $alphaOutput 'probe-result'|Out-Null;$published=$p.data;$alpha=$a.data
$resourceDifferences=@(Compare-Object @($published|ForEach-Object {$_.name+':'+$_.sha256}) @($alpha|ForEach-Object {$_.name+':'+$_.sha256}))
Write-HarnessResult $OutRoot 'resource-comparison.json' @{differences=$resourceDifferences;versionOnly=($resourceDifferences.Count -eq 0)}|Out-Null
if($resourceDifferences.Count){throw 'Alpha embedded resources differ from the published app; see resource-comparison.json.'}

Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
