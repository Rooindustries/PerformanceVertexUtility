param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$hole = [string][char]0
$pathPiece = [string][char]1
$self = [string][char]2
$block = [string][char]3
$facts = [Collections.Generic.List[object]]::new()

function Add-Fact($Node, [string]$Kind, [string]$Name, $Arguments = $null, [hashtable]$Extra = @{}) {
    $fact = [ordered]@{ file = $script:file; line = $Node.Extent.StartLineNumber + $script:offset; text = $Node.Extent.StartScriptPosition.Line; kind = $Kind; name = $Name; args = $Arguments }
    foreach ($key in $Extra.Keys) { $fact[$key] = $Extra[$key] }
    $facts.Add([pscustomobject]$fact)
}

function Join-Pieces([string[]]$Left, [string[]]$Right) {
    if ($Left.Count * $Right.Count -gt 16) { return $hole }
    foreach ($a in $Left) { foreach ($b in $Right) { $a + $b } }
}

function Get-Values($Node, [int]$Depth = 0) {
    if ($null -eq $Node -or $Depth -gt 12) { return $hole }
    if ($Node -is [string]) { return $Node }
    if ($script:memo.ContainsKey($Node)) { return $script:memo[$Node] }
    $result = @(Get-NodeValues $Node $Depth)
    $script:memo[$Node] = $result
    return $result
}

function Get-NodeValues($Node, [int]$Depth) {
    switch ($Node.GetType().Name) {
        'PipelineAst' { if ($Node.PipelineElements.Count -eq 1) { return Get-Values $Node.PipelineElements[0] ($Depth + 1) } }
        'CommandExpressionAst' { return Get-Values $Node.Expression ($Depth + 1) }
        'ParenExpressionAst' { return Get-Values $Node.Pipeline ($Depth + 1) }
        'SubExpressionAst' { if ($Node.SubExpression.Statements.Count -eq 1) { return Get-Values $Node.SubExpression.Statements[0] ($Depth + 1) } }
        'ConvertExpressionAst' { if ($Node.Type.TypeName.Name -eq 'scriptblock') { return $block }; return Get-Values $Node.Child ($Depth + 1) }
        'ScriptBlockExpressionAst' { return $block }
        'StringConstantExpressionAst' { return $Node.Value }
        'ExpandableStringExpressionAst' {
            $value = $Node.Value
            [string[]]$out = @('')
            $at = 0
            foreach ($nested in $Node.NestedExpressions) {
                $index = $value.IndexOf($nested.Extent.Text, $at, [StringComparison]::Ordinal)
                if ($index -lt 0) { return $hole }
                $out = @(Join-Pieces $out @($value.Substring($at, $index - $at)))
                $out = @(Join-Pieces $out @(Get-Values $nested ($Depth + 1)))
                $at = $index + $nested.Extent.Text.Length
            }
            return Join-Pieces $out @($value.Substring($at))
        }
        'BinaryExpressionAst' { if ($Node.Operator -eq 'Plus') { return Join-Pieces @(Get-Values $Node.Left ($Depth + 1)) @(Get-Values $Node.Right ($Depth + 1)) } }
        'VariableExpressionAst' {
            if ($Node.VariablePath.DriveName -eq 'function') { return $Node.VariablePath.UserPath.Substring(9) }
            $name = $Node.VariablePath.UserPath -replace '^(script|global|local|private):'
            if ($name -eq 'PSScriptRoot') { return $pathPiece }
            if ($name -eq 'PSCommandPath') { return $self }
            $declared = $null
            for ($scope = $Node.Parent; $null -ne $scope -and $null -eq $declared; $scope = $scope.Parent) {
                $list = if ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $scope.Parameters) { $scope.Parameters } elseif ($scope -is [System.Management.Automation.Language.ScriptBlockAst] -and $scope.ParamBlock) { $scope.ParamBlock.Parameters } else { $null }
                if ($null -ne $list) { foreach ($parameter in $list) { if ($parameter.Name.VariablePath.UserPath -eq $name) { $declared = $parameter; break } } }
            }
            if (($null -eq $declared -and -not $script:assigned.ContainsKey($name)) -or $script:resolving.Contains($name)) { return $hole }
            [void]$script:resolving.Add($name)
            try {
                $owner = if ($declared) { $declared.Parent } else { $null }
                if ($owner -is [System.Management.Automation.Language.ParamBlockAst]) { $owner = $owner.Parent }
                $local = @(if ($script:assigned.ContainsKey($name)) { $script:assigned[$name] | Where-Object { $null -eq $owner -or ($_ -isnot [string] -and $owner.Extent.StartOffset -le $_.Extent.StartOffset -and $_.Extent.EndOffset -le $owner.Extent.EndOffset) } })
                $sources = @(if ($declared) { $script:parameterValues[$declared] }) + $local
                $all = @(foreach ($value in $sources) { Get-Values $value ($Depth + 1) })
                if ($all.Count -gt 16) { return $hole }
                return $all
            } finally { [void]$script:resolving.Remove($name) }
        }
        'MemberExpressionAst' {
            $text = $Node.Extent.Text
            if ($text -match '^\$MyInvocation\.MyCommand\.(Path|Definition)$') { return $self }
            if ($Node.Static -and $text -match '^\[(System\.)?Environment\]::SystemDirectory$') { return $pathPiece }
            if ($Node.Member.Value -in 'Source', 'Path', 'Definition' -and $Node.Expression -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $inner = $Node.Expression.Pipeline.PipelineElements
                if ($inner.Count -eq 1 -and $inner[0] -is [System.Management.Automation.Language.CommandAst] -and $inner[0].GetCommandName() -eq 'Get-Command' -and $inner[0].CommandElements.Count -ge 2) { return Get-Values $inner[0].CommandElements[1] ($Depth + 1) }
            }
        }
        'InvokeMemberExpressionAst' {
            if (-not $Node.Static -and $Node.Member.Value -eq 'GetNewClosure') { return Get-Values $Node.Expression ($Depth + 1) }
            if ($Node.Static -and $Node.Member.Value -eq 'Create' -and $Node.Expression.Extent.Text -match '^\[(System\.Management\.Automation\.)?scriptblock\]$') { return $block }
            if ($Node.Static -and $Node.Expression.TypeName.FullName -match '^(System\.)?IO\.Path$') {
                switch ($Node.Member.Value) {
                    'Combine' { return Join-Path-Values $Node.Arguments ($Depth + 1) }
                    'Join' { return Join-Path-Values $Node.Arguments ($Depth + 1) }
                    'GetFullPath' { return Get-Path-Values $Node.Arguments[0] ($Depth + 1) }
                    'GetTempPath' { return $pathPiece }
                    'GetDirectoryName' { return $pathPiece }
                }
            }
            if ($Node.Static -and $Node.Expression.TypeName.FullName -match '^(System\.)?Environment$' -and $Node.Member.Value -eq 'GetFolderPath') { return $pathPiece }
        }
        'CommandAst' {
            $name = $Node.GetCommandName()
            if ($name -eq 'Join-Path') {
                if ($Node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -notin 'Path', 'ChildPath', 'AdditionalChildPath' }) { return $hole }
                return Join-Path-Values @($Node.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] }) ($Depth + 1)
            }
            if ($name -in 'Get-Command', 'Resolve-Path' -and $Node.CommandElements.Count -eq 2) { return Get-Values $Node.CommandElements[1] ($Depth + 1) }
            if ($name -and $request.passthrough -contains $name.ToLowerInvariant() -and $Node.CommandElements.Count -eq 2) { return Get-Values $Node.CommandElements[1] ($Depth + 1) }
        }
    }
    return $hole
}

function Get-Path-Values($Node, [int]$Depth) {
    foreach ($value in @(Get-Values $Node $Depth)) { $value.Replace($hole, $pathPiece) }
}

function Join-Path-Values($Parts, [int]$Depth) {
    if (-not $Parts -or $Parts.Count -eq 0) { return $hole }
    [string[]]$out = @(Get-Path-Values $Parts[0] $Depth)
    foreach ($part in @($Parts | Select-Object -Skip 1)) { $out = @(Join-Pieces @(Join-Pieces $out @('\')) @(Get-Values $part $Depth)) }
    return $out
}

function Get-CallValues($Parameter, $Root) {
    $owner = $Parameter.Parent
    if ($owner -is [System.Management.Automation.Language.ParamBlockAst]) { $owner = $owner.Parent.Parent }
    if ($owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { return $hole }
    $parameters = @(if ($owner.Parameters) { $owner.Parameters } else { $owner.Body.ParamBlock.Parameters })
    $position = [array]::IndexOf($parameters, $Parameter)
    $name = $Parameter.Name.VariablePath.UserPath
    $calls = @(if ($script:calls.ContainsKey($owner.Name)) { $script:calls[$owner.Name] })
    if (-not $calls.Count) { return $hole }
    foreach ($call in $calls) {
        if (@($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count) { $hole; continue }
        $bound = Get-Bound $call @($name) $position
        if ($null -ne $bound) { $bound }
    }
}

function Get-Items($Node) {
    while ($Node -is [System.Management.Automation.Language.ArrayExpressionAst] -and $Node.SubExpression.Statements.Count -eq 1) { $Node = $Node.SubExpression.Statements[0] }
    while ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1 -and $Node.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.PipelineElements[0].Expression }
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) { return $Node.Elements }
    return , $Node
}

function Get-Single($Node) {
    $values = @(Get-Values $Node)
    if ($values.Count -eq 1) { return $values[0] }
    return $hole
}

function Get-Element($Element) {
    if ($Element -is [System.Management.Automation.Language.CommandParameterAst]) {
        $parameter = [ordered]@{ param = $Element.ParameterName }
        if ($Element.Argument) { $parameter.value = Get-Single $Element.Argument }
        return [pscustomobject]$parameter
    }
    if ($Element -is [System.Management.Automation.Language.VariableExpressionAst] -and $Element.Splatted) { return [pscustomobject]@{ splat = $true } }
    if ($Element -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return [pscustomobject]@{ block = $true } }
    if ($Element -is [System.Management.Automation.Language.ArrayLiteralAst]) { return [pscustomobject]@{ many = @($Element.Elements | ForEach-Object { Get-Single $_ }) } }
    return [pscustomobject]@{ pieces = (Get-Single $Element); values = @(Get-Values $Element) }
}

function Get-Bound($Command, [string[]]$Names, [int]$Position) {
    $elements = $Command.CommandElements
    $positional = 0
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $matched = @($Names | Where-Object { $_.StartsWith($element.ParameterName, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if ($element.Argument) { if ($matched) { return $element.Argument }; continue }
            if ($matched) { return $elements[$index + 1] }
            if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $index++ }
            continue
        }
        if ($positional -eq $Position) { return $element }
        $positional++
    }
    return $null
}

function Read-Text([string]$Source, $Node) {
    $tokens = $null
    $errors = $null
    $inner = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { Add-Fact $Node 'unreadable' ('PowerShell cannot read the script text this runs: ' + $errors[0].Message); return }
    $saved = $script:offset
    $script:offset = $Node.Extent.StartLineNumber - 1 + $saved
    try { Read-Ast $inner $true } finally { $script:offset = $saved }
}

function Read-Literal($Node, [string]$What) {
    $values = @(Get-Values $Node)
    if ($values.Count -eq 1 -and $values[0].IndexOfAny([char[]](0, 1, 2, 3)) -lt 0) { return $values[0] }
    Add-Fact $Node 'unreadable' "the $What is built from values the check cannot read"
    return $null
}

function Read-Command($Node) {
    $name = $Node.GetCommandName()
    $arguments = @($Node.CommandElements | Select-Object -Skip 1 | ForEach-Object { Get-Element $_ })
    $operator = [string]$Node.InvocationOperator
    if (-not $name) {
        $first = $Node.CommandElements[0]
        if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return }
        foreach ($value in @(Get-Values $first)) {
            if ([string]::Equals($value, $block, [StringComparison]::Ordinal) -or [string]::Equals($value, $self, [StringComparison]::Ordinal)) { continue }
            Add-Fact $Node 'command' '' $arguments @{ pieces = $value; operator = $operator }
        }
        return
    }
    switch -regex ($name) {
        '^(Invoke-Expression|iex)$' {
            $source = Get-Bound $Node @('Command') 0
            if ($source -and ($text = Read-Literal $source 'script text')) { Read-Text $text $Node }
            if (-not $source) { Add-Fact $Node 'unreadable' 'Invoke-Expression runs text the check cannot read' }
            return
        }
        '^Add-Type$' {
            $source = Get-Bound $Node @('TypeDefinition', 'MemberDefinition') 0
            $member = $Node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and 'MemberDefinition'.StartsWith($_.ParameterName, [StringComparison]::OrdinalIgnoreCase) }
            if ($source -and ($text = Read-Literal $source 'C# source')) {
                $line = $source.Extent.StartLineNumber + $(if ($source.Extent.Text.StartsWith('@')) { 1 } else { 0 })
                if ($member) {
                    $typeName = Read-Literal (Get-Bound $Node @('Name') -1) 'type name'
                    $space = if (Get-Bound $Node @('Namespace') -1) { Read-Literal (Get-Bound $Node @('Namespace') -1) 'namespace' } else { 'Microsoft.PowerShell.Commands.AddType.AutoGeneratedTypes' }
                    $usings = @('System', 'System.Runtime.InteropServices') + @(if ($using = Get-Bound $Node @('UsingNamespace') -1) { if ($using -is [System.Management.Automation.Language.ArrayLiteralAst]) { $using.Elements | ForEach-Object { Get-Single $_ } } else { Get-Values $using } })
                    $text = (($usings | ForEach-Object { "using $_;" }) -join ' ') + " namespace $space { public class $typeName { " + $(if ($source.Extent.Text.StartsWith('@')) { "`n" } else { '' }) + $text + "`n} }"
                    if ($source.Extent.Text.StartsWith('@')) { $line-- }
                }
                $facts.Add([pscustomobject]@{ file = $script:file; line = $line + $script:offset; text = ''; kind = 'csharp'; name = $text; args = $null })
            }
            return
        }
        '^Start-Process$' {
            $program = Get-Bound $Node @('FilePath') 0
            $list = Get-Bound $Node @('ArgumentList') 1
            $argumentsOut = @(if ($null -ne $list) { Get-Items $list | ForEach-Object { [pscustomobject]@{ line = (Get-Single $_) } } })
            foreach ($value in @(Get-Values $program)) { Add-Fact $Node 'command' '' $argumentsOut @{ pieces = $value; operator = 'Start-Process' } }
            return
        }
        '^(ForEach-Object|%|foreach)$' {
            $member = Get-Bound $Node @('MemberName') 0
            if ($member -and $member -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                if ($text = Read-Literal $member 'member name') { Add-Fact $Node 'method' ('.' + $text.ToLowerInvariant()) $null }
                return
            }
        }
        '^New-ScheduledTaskAction$' {
            $program = Get-Bound $Node @('Execute') 0
            $list = Get-Bound $Node @('Argument') 1
            $argumentsOut = @(if ($null -ne $list) { [pscustomobject]@{ line = (Get-Single $list) } })
            foreach ($value in @(Get-Values $program)) { Add-Fact $Node 'command' '' $argumentsOut @{ pieces = $value; operator = 'New-ScheduledTaskAction' } }
            return
        }
        '^New-Object$' {
            $com = Get-Bound $Node @('ComObject') -1
            if ($com) { if ($progid = Read-Literal $com 'COM class') { Add-Fact $Node 'call' ('com:' + $progid) @() }; return }
            $type = Get-Bound $Node @('TypeName') 0
            if ($type -and ($typeName = Read-Literal $type 'type name')) { Add-Fact $Node 'call' ((Resolve-TypeName $typeName) + '..ctor') @() }
            return
        }
    }
    Add-Fact $Node 'command' $name $arguments @{ operator = $operator }
}

function Read-Start($Node, $Info) {
    while ($Info -is [System.Management.Automation.Language.PipelineAst] -and $Info.PipelineElements.Count -eq 1) { $Info = $Info.PipelineElements[0] }
    while ($Info -is [System.Management.Automation.Language.CommandExpressionAst]) { $Info = $Info.Expression }
    if ($Info -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $Info.VariablePath.UserPath -match ':') { Add-Fact $Node 'unreadable' 'the program this starts comes from start settings the check cannot read'; return }
    $name = $Info.VariablePath.UserPath
    $programs = @(if ($script:assigned.ContainsKey("$name.FileName")) { $script:assigned["$name.FileName"] | ForEach-Object { Get-Values $_ } })
    $created = @(if ($script:assigned.ContainsKey($name)) { $script:assigned[$name] })
    $made = @()
    foreach ($origin in $created) {
        $origin = if ($origin -is [System.Management.Automation.Language.PipelineAst] -and $origin.PipelineElements.Count -eq 1) { $origin.PipelineElements[0] } else { $origin }
        $origin = if ($origin -is [System.Management.Automation.Language.CommandExpressionAst]) { $origin.Expression } else { $origin }
        if (-not ($origin -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $origin.Static -and $origin.Member.Value -eq 'new' -and $origin.Expression.TypeName.FullName -match '^(System\.)?Diagnostics\.ProcessStartInfo$')) { Add-Fact $Node 'unreadable' 'the program this starts comes from start settings the check cannot read'; return }
        if ($origin.Arguments -and $origin.Arguments.Count) { $programs += @(Get-Values $origin.Arguments[0]) }
        if ($origin.Arguments -and $origin.Arguments.Count -gt 1) { $made += , $origin.Arguments[1] }
    }
    $lines = @(if ($script:assigned.ContainsKey("$name.Arguments")) { $script:assigned["$name.Arguments"] }) + $made
    if (-not $lines.Count) { $lines = @($null) }
    if (-not $programs.Count) { $programs = @($hole) }
    foreach ($program in $programs) {
        foreach ($line in $lines) {
            $elements = @(if ($null -ne $line) { Get-Arguments $line })
            Add-Fact $Node 'command' '' $elements @{ pieces = $program; operator = 'Process.Start' }
        }
    }
}

function Get-Arguments($Node) {
    while ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { $Node = $Node.PipelineElements[0] }
    while ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression }
    if ($Node -is [System.Management.Automation.Language.CommandAst] -and $request.joiners -contains [string]$Node.GetCommandName() -and $Node.CommandElements.Count -eq 2) {
        $list = $Node.CommandElements[1]
        while ($list -is [System.Management.Automation.Language.ArrayExpressionAst] -and $list.SubExpression.Statements.Count -eq 1) { $list = $list.SubExpression.Statements[0].PipelineElements[0].Expression }
        if ($list -is [System.Management.Automation.Language.ArrayLiteralAst]) { return [pscustomobject]@{ many = @($list.Elements | ForEach-Object { Get-Single $_ }) } }
    }
    return [pscustomobject]@{ line = (Get-Single $Node) }
}

function Resolve-TypeName([string]$Name) {
    $type = $Name -as [type]
    if ($type) { return $type.FullName -replace '`\d+', '' -replace '\[.*$', '' }
    return ($Name -replace '\[.*$', '')
}

function Read-Ast($Ast, [bool]$Nested) {
    foreach ($node in $Ast.FindAll({ $true }, $true)) {
        switch ($node.GetType().Name) {
            'CommandAst' { Read-Command $node }
            'InvokeMemberExpressionAst' {
                $given = @(if ($node.Arguments) { $node.Arguments })
                $arguments = @(for ($index = 0; $index -lt $given.Count; $index++) {
                    $argument = $given[$index]
                    if ($argument -is [System.Management.Automation.Language.ConstantExpressionAst]) { [pscustomobject]@{ i = $index; value = $argument.Value } }
                    elseif ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $argument.VariablePath.UserPath -in 'true', 'false') { [pscustomobject]@{ i = $index; value = ($argument.VariablePath.UserPath -eq 'true') } }
                    elseif ($argument -is [System.Management.Automation.Language.MemberExpressionAst] -and $argument.Static -and $argument.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [pscustomobject]@{ i = $index; value = $argument.Member.Value } }
                    else { [pscustomobject]@{ i = $index } }
                })
                if ($node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { Add-Fact $node 'unreadable' 'a member named by an expression cannot be classified'; continue }
                $member = $node.Member.Value
                if (-not $node.Static -and $member -eq 'Start' -and -not $node.Arguments -and $node.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $key = ($node.Expression.VariablePath.UserPath -replace '^(script|global|local|private):') + '.StartInfo'
                    if ($script:assigned.ContainsKey($key)) { foreach ($info in $script:assigned[$key]) { Read-Start $node $info }; continue }
                }
                if (-not $node.Static) { Add-Fact $node 'method' ('.' + $member.ToLowerInvariant()) $arguments; continue }
                if ($node.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $key = $node.Expression.VariablePath.UserPath -replace '^(script|global|local|private):'
                    $sources = @(if ($script:assigned.ContainsKey($key)) { $script:assigned[$key] })
                    $types = @($sources | ForEach-Object { if ($_ -is [System.Management.Automation.Language.PipelineAst] -and $_.PipelineElements.Count -eq 1) { $_.PipelineElements[0] } else { $_ } } | Where-Object { $_ -is [System.Management.Automation.Language.CommandExpressionAst] -and $_.Expression -is [System.Management.Automation.Language.TypeExpressionAst] } | ForEach-Object { $_.Expression.TypeName.FullName })
                    if ($sources.Count -and $types.Count -eq $sources.Count) {
                        foreach ($typeName in $types) { Add-Fact $node 'call' ((Resolve-TypeName $typeName) + '.' + $(if ($member -eq 'new') { '.ctor' } else { $member })) $arguments }
                        continue
                    }
                    if ($sources.Count -and -not @($sources | Where-Object { -not ($_ -is [System.Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and $_.PipelineElements[0].GetCommandName() -eq 'Add-Type') }).Count) { continue }
                }
                if ($node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { Add-Fact $node 'unreadable' 'a static call on a value names no type the check can classify'; continue }
                $type = Resolve-TypeName $node.Expression.TypeName.FullName
                if ($type -eq 'System.Diagnostics.Process' -and $member -eq 'Start') {
                    $given = @(if ($node.Arguments) { $node.Arguments })
                    if ($given.Count -ge 2) { foreach ($value in @(Get-Values $given[0])) { Add-Fact $node 'command' '' @([pscustomobject]@{ line = (Get-Single $given[1]) }) @{ pieces = $value; operator = 'Process.Start' } } }
                    elseif ($given.Count -eq 1) { Read-Start $node $given[0] }
                    else { Add-Fact $node 'unreadable' 'the program this starts comes from start settings the check cannot read' }
                    continue
                }
                if ($type -eq 'System.Management.Automation.ScriptBlock' -and $member -eq 'Create') {
                    if ($node.Arguments.Count -eq 1 -and ($text = Read-Literal $node.Arguments[0] 'script text')) { Read-Text $text $node }
                    continue
                }
                Add-Fact $node 'call' ($type + '.' + $(if ($member -eq 'new') { '.ctor' } else { $member })) $arguments
            }
        }
    }
}

$functions = @{}
$aliases = @{}
function Add-Definitions([string]$File, $Tree) {
    $functions[$File] = @($Tree.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $aliases[$File] = @($Tree.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -in 'Set-Alias', 'New-Alias', 'sal', 'nal' }, $true) | ForEach-Object { $bound = Get-Bound $_ @('Name') 0; if ($bound -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $bound.Value } else { '*' } })
}
foreach ($definition in @($request.definitions)) {
    $tokens = $null
    $errors = $null
    Add-Definitions $definition ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $request.root $definition), [ref]$tokens, [ref]$errors))
}
$items = @($request.files | ForEach-Object { [pscustomobject]@{ file = $_; source = $null; line = 1 } }) + @($request.texts)
foreach ($item in $items) {
    $script:file = $item.file
    $script:offset = $item.line - 1
    $tokens = $null
    $errors = $null
    $ast = if ($null -eq $item.source) { [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $request.root $item.file), [ref]$tokens, [ref]$errors) } else { [System.Management.Automation.Language.Parser]::ParseInput($item.source, [ref]$tokens, [ref]$errors) }
    if ($errors.Count) {
        $facts.Add([pscustomobject]@{ file = $item.file; line = $errors[0].Extent.StartLineNumber + $script:offset; text = $errors[0].Extent.StartScriptPosition.Line; kind = 'unreadable'; name = 'PowerShell cannot read this: ' + $errors[0].Message; args = $null })
        continue
    }
    if ($null -eq $item.source) { Add-Definitions $item.file $ast }
    $script:memo = [Collections.Generic.Dictionary[object, object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $script:calls = @{}
    foreach ($call in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $called = $call.GetCommandName()
        if ($called) { if (-not $script:calls.ContainsKey($called)) { $script:calls[$called] = [Collections.Generic.List[object]]::new() }; $script:calls[$called].Add($call) }
    }
    $script:assigned = @{}
    $script:parameterValues = [Collections.Generic.Dictionary[object, object]]::new()
    $script:resolving = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -or $args[0] -is [System.Management.Automation.Language.ParameterAst] -or $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $target = $null
        $value = $null
        if ($node -is [System.Management.Automation.Language.ParameterAst]) {
            $script:parameterValues[$node] = @(if ($node.StaticType -eq [scriptblock]) { $block } else { Get-CallValues $node $ast })
            continue
        } elseif ($node -is [System.Management.Automation.Language.ForEachStatementAst]) {
            $target = $node.Variable
        } else {
            $target = $node.Left
            while ($target -is [System.Management.Automation.Language.ConvertExpressionAst] -or $target -is [System.Management.Automation.Language.AttributedExpressionAst]) { $target = $target.Child }
            if ($node.Operator -eq 'Equals') { $value = $node.Right }
            if ($target -is [System.Management.Automation.Language.MemberExpressionAst] -and $target.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $target.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $key = ($target.Expression.VariablePath.UserPath -replace '^(script|global|local|private):') + '.' + $target.Member.Value
                if (-not $script:assigned.ContainsKey($key)) { $script:assigned[$key] = [Collections.Generic.List[object]]::new() }
                $script:assigned[$key].Add($(if ($null -eq $value) { $hole } else { $value }))
                continue
            }
        }
        if ($node -is [System.Management.Automation.Language.ForEachStatementAst]) { $value = if ($node.Condition -is [System.Management.Automation.Language.PipelineAst] -and $node.Condition.PipelineElements.Count -eq 1 -and $node.Condition.PipelineElements[0].Expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { $node.Condition.PipelineElements[0].Expression.Elements } else { $hole } }
        elseif ($null -eq $value) { $value = $hole }
        foreach ($variable in @($target) + @(if ($target -is [System.Management.Automation.Language.ArrayLiteralAst]) { $target.Elements })) {
            if ($variable -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $key = $variable.VariablePath.UserPath -replace '^(script|global|local|private):'
            if (-not $script:assigned.ContainsKey($key)) { $script:assigned[$key] = [Collections.Generic.List[object]]::new() }
            foreach ($each in @(if ($target -is [System.Management.Automation.Language.ArrayLiteralAst]) { $hole } else { $value })) { $script:assigned[$key].Add($each) }
        }
    }
    Read-Ast $ast $false
}
[pscustomobject]@{ facts = $facts; functions = $functions; aliases = $aliases } | ConvertTo-Json -Depth 8 -Compress
