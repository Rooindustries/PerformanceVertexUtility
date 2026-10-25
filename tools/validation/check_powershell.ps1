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
        $parameters = @(if ($ast.ParamBlock) { $ast.ParamBlock.Parameters })
        $advanced = @($ast.ParamBlock.Attributes) + @($parameters | ForEach-Object { $_.Attributes }) | Where-Object { $_ -is [System.Management.Automation.Language.AttributeBaseAst] -and $_.TypeName.GetReflectionAttributeType() -in @([System.Management.Automation.CmdletBindingAttribute], [System.Management.Automation.ParameterAttribute]) }
        foreach ($parameter in @(if ($advanced) { $parameters | Where-Object { $_.DefaultValue } })) {
            $value = $parameter.DefaultValue
            while ($value -is [System.Management.Automation.Language.ParenExpressionAst] -and @($value.Pipeline.PipelineElements).Count -eq 1 -and $value.Pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $value = $value.Pipeline.PipelineElements[0].Expression }
            if ($value -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $location = $parameter.DefaultValue.Find({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.IsVariable -and ($node.VariablePath.UserPath -replace '^\w+:') -in @('PSScriptRoot', 'PSCommandPath', 'MyInvocation') }, $true)
            if ($location) {
                '{0}:{1}: PS51ScriptRoot: Windows PowerShell 5.1 leaves ${2} empty in an advanced script''s parameter default when run with -File; set the default in the script body.' -f $Relative, $parameter.Extent.StartLineNumber, $location.VariablePath.UserPath
            }
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
        @{ File = 'script-root-default.ps1'; Source = "param(`n[string]`$Tool = (Join-Path `$PSScriptRoot 'tool.ps1'),`n[Parameter(Mandatory = `$true)][string]`$Out)"; Analyze = $true; Expected = 'script-root-default.ps1:2: PS51ScriptRoot: * $PSScriptRoot *' },
        @{ File = 'script-root-string-default.ps1'; Source = "[CmdletBinding()]param([string]`$Out = `"`${PSScriptRoot}\out`")"; Analyze = $true; Expected = 'script-root-string-default.ps1:1: PS51ScriptRoot: * $PSScriptRoot *' },
        @{ File = 'command-path-default.ps1'; Source = "param([System.Management.Automation.Parameter()][string]`$Self = `$PSCommandPath)"; Analyze = $true; Expected = 'command-path-default.ps1:1: PS51ScriptRoot: * $PSCommandPath *' },
        @{ File = 'bare-parameter-default.ps1'; Source = "param([Parameter][string]`$Out, [string]`$Tool = (Join-Path `$PSScriptRoot 'tool.ps1'))"; Analyze = $true; Expected = 'bare-parameter-default.ps1:1: PS51ScriptRoot: * $PSScriptRoot *' },
        @{ File = 'scoped-default.ps1'; Source = "[CmdletBinding()]param([string]`$Tool = (Join-Path `$script:PSScriptRoot 'tool.ps1'))"; Analyze = $true; Expected = 'scoped-default.ps1:1: PS51ScriptRoot: * $script:PSScriptRoot *' },
        @{ File = 'invocation-default.ps1'; Source = "[CmdletBinding(SupportsShouldProcess)]param([string]`$Self = `$MyInvocation.MyCommand.Path)"; Analyze = $true; Expected = 'invocation-default.ps1:1: PS51ScriptRoot: * $MyInvocation *' },
        @{ File = 'invoked-block-default.ps1'; Source = "[CmdletBinding()]param([string]`$Root = (& { `$PSScriptRoot }))"; Analyze = $true; Expected = 'invoked-block-default.ps1:1: PS51ScriptRoot: * $PSScriptRoot *' },
        @{ File = 'deferred-block-default.ps1'; Source = "[CmdletBinding()]param([scriptblock]`$Root = { `$PSScriptRoot }, [scriptblock]`$Self = ({ `$PSCommandPath }))"; Analyze = $true; Expected = $null },
        @{ File = 'script-root-plain.ps1'; Source = "param([ValidateNotNullOrEmpty()][string]`$Tool = (Join-Path `$PSScriptRoot 'tool.ps1'))"; Analyze = $true; Expected = $null },
        @{ File = 'script-root-body.ps1'; Source = "param([string]`$Tool, [Parameter(Mandatory = `$true)][string]`$Out)`nif (-not `$Tool) { `$Tool = Join-Path `$PSScriptRoot 'tool.ps1' }`nfunction Use-Tool { [CmdletBinding()] param([string]`$Path = (Join-Path `$PSScriptRoot 'tool.ps1')) `$Path }"; Analyze = $true; Expected = $null },
        @{ File = 'suppressed-error.ps1'; Source = "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleSyntax','')]`nparam()`n`$a = `$null ?? 'x'"; Analyze = $true; Expected = 'suppressed-error.ps1:3: PSUseCompatibleSyntax: *' }
    )
    [void][IO.Directory]::CreateDirectory($temporary)
    try {
        foreach ($case in $cases) {
            $path = Join-Path $temporary $case.File
            [IO.File]::WriteAllText($path, $case.Source, [Text.UTF8Encoding]::new($false))
            $observed = @(Get-PowerShellFailures -Path $path -Relative $case.File -Analyze:$case.Analyze)
            if ($null -eq $case.Expected) {
                if ($observed.Count) { "Negative control failed: $($case.File) produced $($observed -join '; ')" }
            } elseif (-not @($observed | Where-Object { $_ -like $case.Expected }).Count) {
                "Negative control failed: $($case.File) did not produce $($case.Expected)"
            }
        }
    } finally {
        [IO.Directory]::Delete($temporary, $true)
    }
}

function Get-GovernorGateFixtureFailures([string]$Root, [string[]]$Files) {
    $real = 'backend/scripts/GovernorOwnership.Common.ps1'
    $fixture = 'tools/validation/Background/RestoreSimulation.Common.ps1'
    $trees = @{}
    foreach ($relative in $Files) {
        $tokens = $null
        $parseErrors = $null
        $trees[$relative] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$parseErrors)
    }
    $enter = $trees[$real].Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enter-RooIndustriesGovernorGate' }, $true)
    $release = $trees[$real].Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Exit-RooIndustriesGovernorGate' }, $true)
    if ($null -eq $enter -or $null -eq $release) { return "${real}:1: GovernorGateFixture: the real Enter-RooIndustriesGovernorGate or Exit-RooIndustriesGovernorGate is missing." }
    $returned = @($enter.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] -and $node.Pipeline.Extent.Text -match '^\$\w+$' -and $node.Pipeline.Extent.Text -ne '$null' }, $true) | ForEach-Object { $_.Pipeline.Extent.Text.Substring(1) })
    $constructed = @($enter.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $returned -contains $node.Left.VariablePath.UserPath }, $true) |
        ForEach-Object { $_.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and $node.Member.Extent.Text -eq 'new' -and $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) } |
        ForEach-Object { $_.Expression.TypeName.FullName -as [type] } | Select-Object -Unique)
    if ($constructed.Count -ne 1) { return "${real}:$($enter.Extent.StartLineNumber): GovernorGateFixture: could not find the one type the real governor gate returns." }
    $gateType = $constructed[0]
    $called = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in @($Files | Where-Object { $_ -like 'backend/scripts/*' })) {
        $gates = @($trees[$relative].FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $null -ne $node.Right.Find({ param($inner) $inner -is [System.Management.Automation.Language.CommandAst] -and $inner.GetCommandName() -eq 'Enter-RooIndustriesGovernorGate' }, $true) }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        if ($relative -eq $real) { $gates += @($release.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        foreach ($member in $trees[$relative].FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $gates -contains $node.Expression.VariablePath.UserPath }, $true)) {
            [void]$called.Add($member.Member.Extent.Text)
        }
    }
    foreach ($relative in $Files) {
        if ($relative -eq $real) { continue }
        foreach ($fake in $trees[$relative].FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enter-RooIndustriesGovernorGate' }, $true)) {
            $builds = $fake.Body.Find({ param($node) ($node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-FixtureGovernorGate') -or ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and $node.Member.Extent.Text -eq 'new' -and $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and ($node.Expression.TypeName.FullName -as [type]) -eq $gateType) }, $true)
            if ($null -eq $builds) { '{0}:{1}: GovernorGateFixture: a fake Enter-RooIndustriesGovernorGate must return a {2} like the real gate; build it with New-FixtureGovernorGate.' -f $relative, $fake.Extent.StartLineNumber, $gateType.FullName }
        }
    }
    $builder = if ($trees.ContainsKey($fixture)) { $trees[$fixture].Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-FixtureGovernorGate' }, $true) } else { $null }
    if ($null -eq $builder) { return "${fixture}:1: GovernorGateFixture: New-FixtureGovernorGate is missing." }
    $shell = [powershell]::Create()
    try {
        $null = $shell.AddScript($builder.Extent.Text + "`n" + $release.Extent.Text + "`n" + @'
$script:Released = 0
$script:Disposed = 0
$script:Held = $true
$gate = New-FixtureGovernorGate
$counted = @($gate.PSObject.Methods | Where-Object { $_.MemberType -eq 'ScriptMethod' } | ForEach-Object { $_.Name })
$failure = $null
try { Exit-RooIndustriesGovernorGate $gate } catch { $failure = $_.Exception.Message }
[pscustomobject]@{ type = $gate.GetType(); counted = $counted; failure = $failure; balanced = $script:Released -eq 1 -and $script:Disposed -eq 1 -and -not $script:Held }
'@)
        $observed = @($shell.Invoke())
    } finally {
        $shell.Dispose()
    }
    if ($observed.Count -ne 1) { return "${fixture}:$($builder.Extent.StartLineNumber): GovernorGateFixture: New-FixtureGovernorGate did not run." }
    $observed = $observed[0]
    if ($observed.type -ne $gateType) { '{0}:{1}: GovernorGateFixture: New-FixtureGovernorGate returns {2}, but the real gate is {3}.' -f $fixture, $builder.Extent.StartLineNumber, $observed.type, $gateType.FullName }
    foreach ($name in $called) {
        if ($observed.counted -notcontains $name) { '{0}:{1}: GovernorGateFixture: the backend calls {2} on the governor gate, but the fake gate does not count it.' -f $fixture, $builder.Extent.StartLineNumber, $name }
    }
    if ($observed.failure -or -not $observed.balanced) { '{0}:{1}: GovernorGateFixture: the real Exit-RooIndustriesGovernorGate did not release and dispose the fake gate exactly once. {2}' -f $fixture, $builder.Extent.StartLineNumber, $observed.failure }
}

function Test-GovernorGateFixtureControls {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('governor-gate-check-' + [Guid]::NewGuid().ToString('N'))
    $copied = @('backend/scripts/GovernorOwnership.Common.ps1', 'tools/validation/Background/RestoreSimulation.Common.ps1')
    $cases = @(
        @{ File = 'backend/scripts/Caller.ps1'; Source = 'function Invoke-Caller { $gate = Enter-RooIndustriesGovernorGate; try {} finally { $gate.Close() } }'; Expected = '*the backend calls Close on the governor gate*' },
        @{ File = 'tools/validation/Fake.ps1'; Source = 'function Enter-RooIndustriesGovernorGate { return [pscustomobject]@{} }'; Expected = 'tools/validation/Fake.ps1:1: GovernorGateFixture: *' }
    )
    try {
        foreach ($relative in @($copied + @($cases | ForEach-Object { $_.File }))) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Join-Path $temporary $relative))) }
        foreach ($relative in $copied) { [IO.File]::Copy((Join-Path $root $relative), (Join-Path $temporary $relative)) }
        foreach ($case in $cases) {
            [IO.File]::WriteAllText((Join-Path $temporary $case.File), $case.Source, [Text.UTF8Encoding]::new($false))
            $observed = @(Get-GovernorGateFixtureFailures -Root $temporary -Files @($copied + $case.File))
            if (-not @($observed | Where-Object { $_ -like $case.Expected }).Count) {
                "Negative control failed: $($case.File) did not produce $($case.Expected)"
            }
        }
    } finally {
        if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
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
    Get-GovernorGateFixtureFailures -Root $root -Files $files | ForEach-Object { $failures.Add($_) }
    Test-GovernorGateFixtureControls | ForEach-Object { $failures.Add($_) }
} catch {
    $failures.Add($_.Exception.Message)
}
foreach ($failure in $failures) { Write-Output $failure }
Write-Output ('PowerShell check: {0} files parsed, {1} analyzed, {2} failures' -f $parsed, $analyzed, $failures.Count)
if ($failures.Count) { exit 1 }
exit 0
