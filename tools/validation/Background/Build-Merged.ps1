param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$FeedUrl=$env:ROO_TEST_UPDATE_FEED)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($FeedUrl)){throw 'FeedUrl is required; pass -FeedUrl or set ROO_TEST_UPDATE_FEED.'}
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$failures=@()
foreach($file in @(Get-ChildItem (Join-Path $Source 'backend\scripts') -Filter '*.ps1')+@(Get-ChildItem (Join-Path $Source 'tools\validation\Background') -Filter '*.ps1')) {
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    foreach($error in $errors){$failures+=@{file=$file.Name;line=$error.Extent.StartLineNumber;message=$error.Message}}
}
ConvertTo-Json -InputObject @($failures) -Depth 8|Set-Content (Join-Path $OutRoot 'parse-errors.json')
if($failures.Count){throw ($failures|ConvertTo-Json -Depth 8 -Compress)}
& (Join-Path $Source 'tools\validation\Background\Test-BackgroundPlacement.ps1') -Source $Source -OutputPath (Join-Path $OutRoot 'topology-cases.json')
$clock=[Diagnostics.Stopwatch]::StartNew()
& (Join-Path $Source 'tools\scripts\Build-Release.ps1') -OutputRoot (Join-Path $OutRoot 'release') -UpdateFeedUrl $FeedUrl *> (Join-Path $OutRoot 'build.log')
$exit=$LASTEXITCODE
$files=@(Get-ChildItem (Join-Path $OutRoot 'release') -Filter '*setup.exe'|ForEach-Object {@{path=$_.FullName;size=$_.Length;sha256=(Get-FileHash $_.FullName).Hash}})
@{elapsedSeconds=$clock.Elapsed.TotalSeconds;exitCode=$exit;installers=$files;machine=$env:COMPUTERNAME;feed=$FeedUrl}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutRoot 'build-result.json')
if($exit -ne 0 -or $files.Count -ne 1){throw 'Release build did not produce one installer'}
