param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'))
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
$body='[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding;& '+"'"+$Script.Replace("'","''")+"'"
$start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
$child=[Diagnostics.Process]::Start($start)
try {
    $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(600000)){$child.Kill();throw 'The private script check timed out.'}
    $text=$output.Result+"`n"+$errors.Result
    [IO.File]::WriteAllText((Join-Path $OutDir 'native.log'),$text,[Text.UTF8Encoding]::new($false));Write-Output $text
    $checks=@($text -split '\r?\n'|Where-Object {$_ -match '^(PASS|FAIL) '}|ForEach-Object {[pscustomobject]@{passed=$_.StartsWith('PASS ');check=$_.Substring(5)}})
    $passed=$child.ExitCode -eq 0 -and $checks.Count -gt 0 -and @($checks|Where-Object {-not $_.passed}).Count -eq 0 -and $text -notmatch '(?m)^(SKIP|NOT RUN|FATAL) '
    [pscustomobject]@{passed=$passed;checks=$checks;exit=$child.ExitCode;script=$Script}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
} finally {$child.Dispose()}
exit [int](-not $passed)
