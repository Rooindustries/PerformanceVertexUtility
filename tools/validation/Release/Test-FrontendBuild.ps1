param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),('build "'+$project+'" -c Release -warnaserror -p:RooIndustriesRelease=true -p:EnableWindowsTargeting=true'))
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
try {
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(600000)){$child.Kill();throw 'The native frontend build timed out'}
    $text=$stdout.Result+"`n"+$stderr.Result
    [IO.File]::WriteAllText((Join-Path $OutDir 'build.log'),$text,[Text.UTF8Encoding]::new($false))
    Write-Output $text
    $passed=$child.ExitCode -eq 0 -and $text.Contains('0 Warning(s)') -and $text.Contains('0 Error(s)')
    [ordered]@{passed=$passed;project=$project;sourceSha256=(Get-FileHash -LiteralPath $project).Hash;exitCode=$child.ExitCode;checks=@(@{passed=$passed;check='The actual WinUI frontend builds on Windows with zero warnings and errors'})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
    if(-not $passed){exit 1}
    'PASS The actual WinUI frontend builds on Windows with zero warnings and errors'
} finally {$child.Dispose()}
