$script:RooProcessProductName = 'Roo Industries Optimization Suite'
$script:RooAllowedPriorityClasses = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal')

function Get-RooUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function Resolve-RooPath {
    param(
        [string]$Path,
        [string]$DefaultPath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath($DefaultPath)
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Read-RooJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Ensure-RooDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 24
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooArray $prop.Value)
}

function Get-RooPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) { return $DefaultValue }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $DefaultValue }
    if ($null -eq $prop.Value) { return $DefaultValue }
    return $prop.Value
}

function Get-RooNormalizedProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    if ($n.EndsWith('.exe')) {
        return $n.Substring(0, $n.Length - 4)
    }
    return $n
}

function Test-RooProcessNameEquals {
    param(
        [string]$Left,
        [string]$Right
    )
    return (Get-RooNormalizedProcessName $Left) -eq (Get-RooNormalizedProcessName $Right)
}

function Test-RooAnyNameMatch {
    param(
        [string]$ProcessName,
        [object[]]$Names
    )
    foreach ($name in @(Get-RooArray $Names)) {
        if (Test-RooProcessNameEquals $ProcessName ([string]$name)) { return $true }
    }
    return $false
}

function Test-RooAnyWildcardMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($pattern in @(Get-RooArray $Patterns)) {
        if ($Value -like [string]$pattern) { return $true }
    }
    return $false
}

function Test-RooProcessMatch {
    param(
        [object]$Process,
        [object]$Match
    )
    if ($null -eq $Process -or $null -eq $Match) { return $false }

    $matched = $false
    $hasPositiveSelector = $false
    $processName = [string]$Process.name
    $processPath = [string]$Process.executablePath
    $commandLine = [string]$Process.commandLine
    $category = [string]$Process.category

    $names = @()
    $names += Get-RooPropertyArray $Match 'names'
    $names += Get-RooPropertyArray $Match 'processNames'
    if ($names.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyNameMatch $processName $names) { $matched = $true }
    }

    $namePatterns = Get-RooPropertyArray $Match 'namePatterns'
    if ($namePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $processName $namePatterns) { $matched = $true }
    }

    $pathPatterns = Get-RooPropertyArray $Match 'pathPatterns'
    if ($pathPatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $processPath $pathPatterns) { $matched = $true }
    }

    $commandLinePatterns = Get-RooPropertyArray $Match 'commandLinePatterns'
    if ($commandLinePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $commandLine $commandLinePatterns) { $matched = $true }
    }

    $categories = Get-RooPropertyArray $Match 'processCategories'
    if ($categories.Count -gt 0) {
        $hasPositiveSelector = $true
        foreach ($candidate in $categories) {
            if ($category -eq [string]$candidate) { $matched = $true }
        }
    }

    if (-not $hasPositiveSelector -or -not $matched) { return $false }

    $excludeNames = Get-RooPropertyArray $Match 'excludeProcessNames'
    if ($excludeNames.Count -gt 0 -and (Test-RooAnyNameMatch $processName $excludeNames)) { return $false }

    $excludeNamePatterns = Get-RooPropertyArray $Match 'excludeNamePatterns'
    if ($excludeNamePatterns.Count -gt 0 -and (Test-RooAnyWildcardMatch $processName $excludeNamePatterns)) { return $false }

    $excludeCategories = Get-RooPropertyArray $Match 'excludeProcessCategories'
    foreach ($candidate in $excludeCategories) {
        if ($category -eq [string]$candidate) { return $false }
    }

    return $true
}

function Get-RooProtectedCatalogMatch {
    param(
        [object]$Process,
        [object]$ProtectedCatalog
    )
    foreach ($item in @(Get-RooPropertyArray $ProtectedCatalog 'protectedProcesses')) {
        $match = [pscustomobject]@{
            names = @(Get-RooPropertyArray $item 'names')
            namePatterns = @(Get-RooPropertyArray $item 'namePatterns')
            pathPatterns = @(Get-RooPropertyArray $item 'pathPatterns')
            processCategories = @(Get-RooPropertyArray $item 'processCategories')
        }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Get-RooProtectedCompanionMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($item in @(Get-RooPropertyArray $Profile 'protectedCompanions')) {
        $match = [pscustomobject]@{
            names = @(Get-RooPropertyArray $item 'names')
            processNames = @([string](Get-RooPropertyValue $item 'name' ''))
        }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Get-RooTargetGameMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string]$TargetGameProcessName
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        if (Test-RooProcessNameEquals ([string]$Process.name) $TargetGameProcessName) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue (Get-RooPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @('TARGET_GAME_PARAMETER')
            }
        }
    }

    $foregroundGame = Get-RooPropertyValue $Profile 'foregroundGame' $null
    if ($foregroundGame) {
        $match = [pscustomobject]@{ processNames = @(Get-RooPropertyArray $foregroundGame 'processNames') }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooPropertyArray $foregroundGame 'reasonCodes')
            }
        }
    }

    foreach ($game in @(Get-RooPropertyArray $Profile 'targetGames')) {
        $match = [pscustomobject]@{ processNames = @(Get-RooPropertyArray $game 'processNames') }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue (Get-RooPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooPropertyArray $game 'reasonCodes')
            }
        }
    }

    return [pscustomobject]@{ matched = $false; ruleId = $null; reasonCodes = @() }
}

function Get-RooRuleMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string[]]$ActionTypes
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'rules')) {
        $enabled = [bool](Get-RooPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $action = Get-RooPropertyValue $rule 'action' $null
        $actionType = [string](Get-RooPropertyValue $action 'actionType' '')
        if ($ActionTypes.Count -gt 0 -and $actionType -notin $ActionTypes) { continue }
        if (Test-RooProcessMatch $Process (Get-RooPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooSafeCandidateMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'safeCandidates')) {
        if (Test-RooProcessMatch $Process (Get-RooPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Test-RooProtectedPreviewName {
    param(
        [object]$Process,
        [object]$Profile
    )
    return Test-RooAnyNameMatch ([string]$Process.name) @(Get-RooPropertyArray $Profile 'protectedPreviewProcessNames')
}

function Add-RooReasonCode {
    param(
        [System.Collections.Generic.List[string]]$ReasonCodes,
        [object]$Values
    )
    foreach ($value in @(Get-RooArray $Values)) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $ReasonCodes.Contains($text)) {
            $ReasonCodes.Add($text) | Out-Null
        }
    }
}

function Get-RooProcessClassificationInfo {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog,
        [string]$TargetGameProcessName
    )
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    $classification = 'unknown'
    $matchedRuleId = $null
    $matchedProtectedItemId = $null
    $matchedProfileItemId = $null
    $profileMatched = $false
    $sessionProfileMatched = $false
    $blocked = $false
    $protected = $false
    $risk = [string](Get-RooPropertyValue $Process 'risk' 'low')

    $companionMatch = Get-RooProtectedCompanionMatch $Process $Profile
    if ($companionMatch.matched) {
        $classification = 'protectedCompanion'
        $matchedProfileItemId = [string](Get-RooPropertyValue $companionMatch.item 'itemId' '')
        $profileMatched = $true
        $sessionProfileMatched = $true
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $companionMatch.item 'reasonCodes')
    } else {
        $protectedMatch = Get-RooProtectedCatalogMatch $Process $ProtectedCatalog
        if ($protectedMatch.matched) {
            $catalogClassification = [string](Get-RooPropertyValue $protectedMatch.item 'classification' 'protected')
            if ($catalogClassification -eq 'protectedCompanion') {
                $classification = 'protectedCompanion'
            } else {
                $classification = 'protected'
            }
            $matchedProtectedItemId = [string](Get-RooPropertyValue $protectedMatch.item 'itemId' '')
            $sessionProfileMatched = Test-RooProtectedPreviewName $Process $Profile
            $blocked = $true
            $protected = $true
            $risk = 'protected'
            Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $protectedMatch.item 'reasonCodes')
        } else {
            $targetMatch = Get-RooTargetGameMatch $Process $Profile $TargetGameProcessName
            if ($targetMatch.matched) {
                $classification = 'gameTarget'
                $matchedRuleId = [string]$targetMatch.ruleId
                $profileMatched = $true
                $sessionProfileMatched = $true
                $risk = 'medium'
                Add-RooReasonCode $reasonCodes $targetMatch.reasonCodes
                Add-RooReasonCode $reasonCodes @('GAME_TARGET')
            } else {
                $demotionMatch = Get-RooRuleMatch $Process $Profile @('setPriority')
                if ($demotionMatch.matched) {
                    $rulePriority = [string](Get-RooPropertyValue (Get-RooPropertyValue $demotionMatch.rule 'action' $null) 'priorityClass' '')
                    if ($rulePriority -eq 'BelowNormal' -or $rulePriority -eq 'Idle') {
                        $classification = 'demotionCandidate'
                        $matchedRuleId = [string](Get-RooPropertyValue $demotionMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooPropertyValue $demotionMatch.rule 'risk' 'low')
                        Add-RooReasonCode $reasonCodes @('BACKGROUND_DEMOTION_CANDIDATE')
                    }
                }

                if ($classification -eq 'unknown') {
                    $safeMatch = Get-RooSafeCandidateMatch $Process $Profile
                    if ($safeMatch.matched) {
                        $classification = 'safeCandidate'
                        $matchedRuleId = [string](Get-RooPropertyValue $safeMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooPropertyValue $safeMatch.rule 'risk' 'low')
                        Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $safeMatch.rule 'reasonCodes')
                    }
                }

                if ($classification -eq 'unknown' -and [string](Get-RooPropertyValue $Process 'protection' '') -eq 'protected') {
                    $classification = 'protected'
                    $blocked = $true
                    $protected = $true
                    $risk = 'protected'
                    Add-RooReasonCode $reasonCodes @('INVENTORY_PROTECTED')
                }
            }
        }
    }

    if ($reasonCodes.Count -eq 0) {
        Add-RooReasonCode $reasonCodes @('NO_PROFILE_MATCH')
    }

    $canChangePriority = [bool](Get-RooPropertyValue $Process 'canChangePriority' $false)
    if ($protected -or $blocked) { $canChangePriority = $false }

    return [pscustomobject]@{
        classification = $classification
        reasonCodes = @($reasonCodes.ToArray())
        matchedRuleId = $matchedRuleId
        matchedProtectedItemId = $matchedProtectedItemId
        matchedProfileItemId = $matchedProfileItemId
        profileMatched = $profileMatched
        sessionProfileMatched = $sessionProfileMatched
        blocked = $blocked
        protected = $protected
        risk = $risk
        canChangePriority = $canChangePriority
    }
}

function Get-RooRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'rules')) {
        if ([string](Get-RooPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function New-RooIssue {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Severity = 'warning',
        [string]$Source = 'performance.profile',
        [string]$Target = $null,
        [bool]$Blocking = $false,
        [string]$RecommendedAction = $null,
        [object]$Details = $null
    )
    return [pscustomobject]@{
        code = $Code
        message = $Message
        severity = $Severity
        source = $Source
        target = $Target
        blocking = $Blocking
        recommendedAction = $RecommendedAction
        details = $Details
    }
}

function New-RooLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooUtcStamp
        level = $Level
        message = $Message
    }
}

function New-RooActionResult {
    param(
        [string]$ResultId,
        [string]$Status,
        [string]$Summary,
        [object[]]$ChangedItems = @(),
        [object[]]$SkippedItems = @(),
        [object[]]$Artifacts = @()
    )
    return [pscustomobject]@{
        resultId = $ResultId
        status = $Status
        startedAtUtc = $null
        completedAtUtc = Get-RooUtcStamp
        summary = $Summary
        changedItems = @(Get-RooArray $ChangedItems)
        skippedItems = @(Get-RooArray $SkippedItems)
        metricsBefore = $null
        metricsAfter = $null
        artifacts = @(Get-RooArray $Artifacts)
    }
}

function New-RooActionEnvelope {
    param(
        [string]$ActionId,
        [bool]$DryRun,
        [string]$Risk = 'medium',
        [bool]$RequiresElevation = $false,
        [string]$Status = 'preview',
        [object[]]$Preview = @(),
        [object]$Backup = $null,
        [object]$Result = $null,
        [object[]]$Warnings = @(),
        [object[]]$Errors = @(),
        [object[]]$Logs = @(),
        [string]$CorrelationId = $null
    )
    return [pscustomobject]@{
        actionId = $ActionId
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $CorrelationId
        dryRun = $DryRun
        risk = $Risk
        requiresElevation = $RequiresElevation
        status = $Status
        preview = @(Get-RooArray $Preview)
        backup = $Backup
        result = $Result
        warnings = @(Get-RooArray $Warnings)
        errors = @(Get-RooArray $Errors)
        logs = @(Get-RooArray $Logs)
    }
}

function Test-RooPriorityAllowed {
    param([string]$PriorityClass)
    return $script:RooAllowedPriorityClasses -contains $PriorityClass
}
