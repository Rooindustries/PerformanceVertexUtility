param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$PublishedVersion,[Parameter(Mandatory)][string]$AlphaVersion,[Parameter(Mandatory)][string]$PublishedApp)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$copy=Join-Path $OutRoot 'src'
if(Test-Path $copy){throw 'Alpha source already exists; allocate a fresh frame.'}
[IO.Directory]::CreateDirectory($copy)|Out-Null
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
@{differences=$differences;beforeVersion=$PublishedVersion;afterVersion=$AlphaVersion;source=$Source;copy=$copy}|ConvertTo-Json|Set-Content (Join-Path $OutRoot 'alpha-source-binding.json')
& (Join-Path $copy 'tools\scripts\Build-Release.ps1') -OutputRoot (Join-Path $OutRoot 'release')
if(-not$?){throw 'Alpha build failed.'}
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
& $dotnet publish (Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj') -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o (Join-Path $OutRoot 'probe')
if($LASTEXITCODE){throw 'UpdateProbe build failed.'}
$app=Join-Path $OutRoot ('release\work-'+$AlphaVersion+'\stage\app\RooIndustries.OptimizationSuite.App.dll')
& (Join-Path $OutRoot 'probe\UpdateProbe.exe') --embedded-feed $app (Join-Path $OutRoot 'embedded-feed.json')
if($LASTEXITCODE){throw 'Embedded feed read failed.'}
$actual=(Get-Content -Raw (Join-Path $OutRoot 'embedded-feed.json')|ConvertFrom-Json).feed
$expected='url='+([IO.File]::ReadAllText((Join-Path $Source 'tools\release\update-feed.txt')).Trim())
if($actual -cne $expected){throw 'Built alpha does not embed the committed production feed.'}

& (Join-Path $OutRoot 'probe\UpdateProbe.exe') --resources $PublishedApp (Join-Path $OutRoot 'published-resources.json')
if($LASTEXITCODE){throw 'Published resource read failed.'}
& (Join-Path $OutRoot 'probe\UpdateProbe.exe') --resources $app (Join-Path $OutRoot 'alpha-resources.json')
if($LASTEXITCODE){throw 'Alpha resource read failed.'}
$published=Get-Content -Raw (Join-Path $OutRoot 'published-resources.json')|ConvertFrom-Json
$alpha=Get-Content -Raw (Join-Path $OutRoot 'alpha-resources.json')|ConvertFrom-Json
$resourceDifferences=@(Compare-Object @($published|ForEach-Object {$_.name+':'+$_.sha256}) @($alpha|ForEach-Object {$_.name+':'+$_.sha256}))
@{differences=$resourceDifferences;versionOnly=($resourceDifferences.Count -eq 0)}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutRoot 'resource-comparison.json')
if($resourceDifferences.Count){throw 'Alpha embedded resources differ from the published app; see resource-comparison.json.'}
