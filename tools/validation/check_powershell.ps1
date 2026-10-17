$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$settings = @{
    IncludeRules = @('PSUseCompatibleSyntax')
    Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
}

function Get-PowerShellFailures([string]$Path, [string]$Relative, [switch]$Analyze) {
    $latin1 = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    if (-not $latin1.StartsWith([string][char]0xEF + [char]0xBB + [char]0xBF) -and $latin1 -match '[^\x00-\x7F]') {
        '{0}:1: PS51Encoding: Non-ASCII content needs a UTF-8 byte order mark for Windows PowerShell 5.1.' -f $Relative
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        '{0}:{1}: {2}' -f $Relative, $parseError.Extent.StartLineNumber, $parseError.Message
    }
    if ($Analyze) {
        foreach ($finding in @(Invoke-ScriptAnalyzer -Path $Path -Settings $settings -IncludeSuppressed)) {
            '{0}:{1}: {2}: {3}' -f $Relative, $finding.Line, $finding.RuleName, $finding.Message
        }
        foreach ($index in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IndexExpressionAst] -and $node.NullConditional }, $true)) {
            '{0}:{1}: PS51Syntax: Null-conditional indexing requires PowerShell 7.' -f $Relative, $index.Extent.StartLineNumber
        }
    }
}

function Test-PowerShellControls {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('powershell-check-' + [Guid]::NewGuid().ToString('N'))
    $cases = @(
        @{ File = 'parse-error.ps1'; Source = 'function {'; Analyze = $false; Expected = 'parse-error.ps1:1: *' },
        @{ File = 'syntax-error.ps1'; Source = '$a = $null ?? ''x'''; Analyze = $true; Expected = 'syntax-error.ps1:1: PSUseCompatibleSyntax: *' },
        @{ File = 'index-error.ps1'; Source = '$a = ${value}?[0]'; Analyze = $true; Expected = 'index-error.ps1:1: PS51Syntax: *' },
        @{ File = 'encoding-error.ps1'; Source = "Write-Output 'caf$([char]0xE9)'"; Analyze = $false; Expected = 'encoding-error.ps1:1: PS51Encoding: *' },
        @{ File = 'suppressed-error.ps1'; Source = "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleSyntax','')]`nparam()`n`$a = `$null ?? 'x'"; Analyze = $true; Expected = 'suppressed-error.ps1:3: PSUseCompatibleSyntax: *' }
    )
    [void][IO.Directory]::CreateDirectory($temporary)
    try {
        foreach ($case in $cases) {
            $path = Join-Path $temporary $case.File
            [IO.File]::WriteAllText($path, $case.Source, [Text.UTF8Encoding]::new($false))
            $observed = @(Get-PowerShellFailures -Path $path -Relative $case.File -Analyze:$case.Analyze)
            if (-not @($observed | Where-Object { $_ -like $case.Expected }).Count) {
                "Negative control failed: $($case.File) did not produce $($case.Expected)"
            }
        }
    } finally {
        [IO.Directory]::Delete($temporary, $true)
    }
}

$failures = [Collections.Generic.List[string]]::new()
$parsed = 0
$analyzed = 0
try {
    try {
        Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
    } catch {
        throw 'PSScriptAnalyzer 1.25.0 is required. Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force'
    }
    $listed = @(& git -C $root ls-files -z -- '*.ps1' '*.psm1' '*.psd1') -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while collecting PowerShell sources.' }
    $files = @($listed.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))
    if (-not $files.Count) { throw 'git ls-files returned no PowerShell sources.' }
    foreach ($relative in $files) {
        $parsed++
        $analyzed++
        try {
            Get-PowerShellFailures -Path (Join-Path $root $relative) -Relative $relative -Analyze | ForEach-Object { $failures.Add($_) }
        } catch {
            $failures.Add(('{0}:1: PowerShell analysis failed: {1}' -f $relative, $_.Exception.Message))
        }
    }
    Test-PowerShellControls | ForEach-Object { $failures.Add($_) }
} catch {
    $failures.Add($_.Exception.Message)
}
foreach ($failure in $failures) { Write-Output $failure }
Write-Output ('PowerShell check: {0} files parsed, {1} analyzed, {2} failures' -f $parsed, $analyzed, $failures.Count)
if ($failures.Count) { exit 1 }
exit 0
