param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$PublishedVersion,[Parameter(Mandatory)][string]$AlphaVersion)
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
foreach($folder in 'backend','docs','tools\release','tools\scripts'){
 foreach($file in Get-ChildItem (Join-Path $Source $folder) -File -Recurse){
  $name=$file.FullName.Substring($Source.Length).TrimStart('\')
  if($name -match '(^|\\)(obj|bin|artifacts)(\\|$)'){continue}
  if((Get-FileHash $file.FullName).Hash -cne (Get-FileHash (Join-Path $copy $name)).Hash){$differences+=$name}
 }
}
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
