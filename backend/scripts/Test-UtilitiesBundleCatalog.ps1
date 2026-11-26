param(
    [string]$CatalogPath,
    [string]$ManifestPath,
    [string]$SamplePath,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$passes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

function Resolve-CallerPath {
    param([string]$Path)

    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        return $Path
    }
}

if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $repoRoot 'backend\catalogs\utilities-bundle-catalog.json' }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $repoRoot 'modules\utilities_manifest.json' }
if ([string]::IsNullOrWhiteSpace($SamplePath)) { $SamplePath = Join-Path $repoRoot 'backend\samples\utilities-bundle-inventory.sample.json' }
$catalogFile = Resolve-CallerPath $CatalogPath
$manifestFile = Resolve-CallerPath $ManifestPath
$sampleFile = Resolve-CallerPath $SamplePath
$archiveFile = ''
if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { $archiveFile = Resolve-CallerPath $ArchivePath }

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
    Write-Host "PASS $Message"
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL $Message"
}

function Add-Check {
    param(
        [bool]$Condition,
        [string]$PassMessage,
        [string]$FailureMessage
    )

    if ($Condition) {
        Add-Pass $PassMessage
    } else {
        Add-Failure $FailureMessage
    }
}

function Has-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if (-not (Has-Property $Object $Name)) { return $Default }
    return $Object.PSObject.Properties[$Name].Value
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label,
        [string]$File
    )

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        Add-Failure "$Label missing: $Path"
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
        Add-Pass "$Label parses as JSON"
        return $json
    } catch {
        Add-Failure "$Label JSON parse failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-OptionalArchivePath {
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        return $archiveFile
    }

    $repoArchive = Join-Path $repoRoot 'vendor\Utilities.zip'
    if (Test-Path -LiteralPath $repoArchive -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($repoArchive)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ARCHIVE)) {
        return Resolve-CallerPath $env:ROO_INDUSTRIES_UTILITIES_ARCHIVE
    }

    return ''
}

function Test-ManifestDecision {
    param(
        [object]$Manifest,
        [string]$Id,
        [string]$ExpectedClass,
        [bool]$ExpectedAutoRun,
        [string]$ExpectedArchivePath
    )

    $tools = @((Get-PropertyValue $Manifest 'tools' @()) | Where-Object { [string](Get-PropertyValue $_ 'id' '') -eq $Id })
    Add-Check ($tools.Count -eq 1) "Utilities manifest contains $Id" "Utilities manifest missing or duplicates $Id"
    if ($tools.Count -ne 1) { return }

    $tool = $tools[0]
    Add-Check ([string](Get-PropertyValue $tool 'executionClass' '') -eq $ExpectedClass) "$Id executionClass is $ExpectedClass" "$Id executionClass expected $ExpectedClass actual $([string](Get-PropertyValue $tool 'executionClass' ''))"
    Add-Check ((Get-PropertyValue $tool 'autoRunAllowed' $null) -eq $ExpectedAutoRun) "$Id autoRunAllowed is $ExpectedAutoRun" "$Id autoRunAllowed expected $ExpectedAutoRun actual $((Get-PropertyValue $tool 'autoRunAllowed' $null))"
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tool 'integrationPlan' ''))) "$Id has integrationPlan" "$Id missing integrationPlan"
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tool 'risk' ''))) "$Id has risk" "$Id missing risk"

    if (-not [string]::IsNullOrWhiteSpace($ExpectedArchivePath)) {
        $archivePaths = @((Get-PropertyValue $tool 'archivePaths' @()) | ForEach-Object { [string]$_ })
        Add-Check ($archivePaths -contains $ExpectedArchivePath) "$Id covers expected archive path" "$Id missing archive path $ExpectedArchivePath"
    }
}

function Test-CatalogTool {
    param(
        [object[]]$Entries,
        [string]$ToolId,
        [int]$MinimumCount,
        [string]$ExpectedClass
    )

    $matches = @($Entries | Where-Object { [string](Get-PropertyValue $_ 'toolId' '') -eq $ToolId })
    Add-Check ($matches.Count -ge $MinimumCount) "Catalog covers $ToolId with $($matches.Count) entry/entries" "Catalog expected at least $MinimumCount entry/entries for $ToolId, found $($matches.Count)"
    $badClassMatches = @($matches | Where-Object { [string](Get-PropertyValue $_ 'executionClass' '') -ne $ExpectedClass })
    Add-Check ($badClassMatches.Count -eq 0) "Catalog $ToolId entries use executionClass $ExpectedClass" "Catalog $ToolId executionClass mismatch at $((@($badClassMatches | ForEach-Object { [string](Get-PropertyValue $_ 'archivePath' '') })) -join ', ')"
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

public static class RooIndustriesBundleJson
{
    static readonly Regex UtcTime = new Regex(@"^([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt ]([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?([Zz]|[+-]00:00)\z", RegexOptions.CultureInvariant);

    public static object Field(object node, string name)
    {
        Dictionary<string, object> obj = node as Dictionary<string, object>;
        object value;
        if (obj != null && obj.TryGetValue(name, out value)) return value;
        return null;
    }

    public static string Label(object entry)
    {
        string path = Field(entry, "archivePath") as string;
        if (path != null && path.Length > 1 && path[0] == '"') return Unquote(path);
        return Canonical(entry);
    }

    public static string[] DifferentFields(object expected, object actual)
    {
        Dictionary<string, object> e = expected as Dictionary<string, object>;
        Dictionary<string, object> a = actual as Dictionary<string, object>;
        if (e == null || a == null) return new string[] { "<whole value>" };
        SortedSet<string> names = new SortedSet<string>(e.Keys, StringComparer.Ordinal);
        names.UnionWith(a.Keys);
        List<string> different = new List<string>();
        foreach (string name in names)
        {
            object ev;
            object av;
            if (!e.TryGetValue(name, out ev) || !a.TryGetValue(name, out av) || Canonical(ev) != Canonical(av)) different.Add(Quote(name));
        }
        return different.ToArray();
    }

    public static string[] HeaderProblems(object record, object generated, string entriesField)
    {
        Dictionary<string, object> r = (Dictionary<string, object>)record;
        Dictionary<string, object> g = (Dictionary<string, object>)generated;
        SortedSet<string> names = new SortedSet<string>(r.Keys, StringComparer.Ordinal);
        names.UnionWith(g.Keys);
        names.Remove("catalogEntries");
        names.Remove(entriesField);
        List<string> problems = new List<string>();
        foreach (string name in names)
        {
            object rv;
            object gv;
            bool inRecord = r.TryGetValue(name, out rv);
            bool inGenerated = g.TryGetValue(name, out gv);
            if (name == "generatedAtUtc")
            {
                if (!inRecord || !IsUtcTime(rv)) problems.Add(Quote(name) + " (not a UTC time)");
            }
            else if (!inRecord) problems.Add(Quote(name) + " (missing)");
            else if (!inGenerated) problems.Add(Quote(name) + " (unexpected)");
            else if (Canonical(gv) != Canonical(rv)) problems.Add(Quote(name) + " (different)");
        }
        if (entriesField != "catalogEntries" && r.ContainsKey("catalogEntries")) problems.Add(Quote("catalogEntries") + " (unexpected)");
        return problems.ToArray();
    }

    public static bool IsUtcTime(object node)
    {
        string quoted = node as string;
        if (quoted == null || quoted.Length < 2 || quoted[0] != '"') return false;
        Match match = UtcTime.Match(Unquote(quoted));
        DateTime parsed;
        return match.Success && DateTime.TryParseExact(match.Groups[1].Value + "T" + match.Groups[2].Value, "yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed);
    }

    public static object Parse(string text)
    {
        int position = 0;
        object node = ReadValue(text, ref position);
        SkipSpace(text, ref position);
        if (position != text.Length) throw new FormatException("more JSON follows the first value at offset " + position);
        return node;
    }

    public static string Canonical(object node)
    {
        StringBuilder builder = new StringBuilder();
        Write(builder, node);
        return builder.ToString();
    }

    public static string Quote(string value)
    {
        StringBuilder builder = new StringBuilder("\"");
        foreach (char c in value)
        {
            if (c >= 0x20 && c <= 0x7e && c != '"' && c != '\\') builder.Append(c);
            else builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
        }
        return builder.Append('"').ToString();
    }

    public static string Unquote(string quoted)
    {
        int position = 0;
        return ReadString(quoted, ref position);
    }

    static void Write(StringBuilder builder, object node)
    {
        Dictionary<string, object> obj = node as Dictionary<string, object>;
        if (obj != null)
        {
            List<string> names = new List<string>(obj.Keys);
            names.Sort(StringComparer.Ordinal);
            builder.Append('{');
            for (int i = 0; i < names.Count; i++)
            {
                if (i > 0) builder.Append(',');
                builder.Append(Quote(names[i])).Append(':');
                Write(builder, obj[names[i]]);
            }
            builder.Append('}');
            return;
        }
        List<object> list = node as List<object>;
        if (list != null)
        {
            builder.Append('[');
            for (int i = 0; i < list.Count; i++)
            {
                if (i > 0) builder.Append(',');
                Write(builder, list[i]);
            }
            builder.Append(']');
            return;
        }
        builder.Append((string)node);
    }

    static void SkipSpace(string text, ref int position)
    {
        while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++;
    }

    static bool Take(string text, ref int position, char expected)
    {
        SkipSpace(text, ref position);
        if (position < text.Length && text[position] == expected)
        {
            position++;
            return true;
        }
        return false;
    }

    static bool IsDigit(string text, int position)
    {
        return position < text.Length && text[position] >= '0' && text[position] <= '9';
    }

    static object ReadValue(string text, ref int position)
    {
        SkipSpace(text, ref position);
        if (position >= text.Length) throw new FormatException("the JSON ends early");
        char c = text[position];
        if (c == '{')
        {
            position++;
            Dictionary<string, object> obj = new Dictionary<string, object>(StringComparer.Ordinal);
            if (Take(text, ref position, '}')) return obj;
            do
            {
                SkipSpace(text, ref position);
                if (position >= text.Length || text[position] != '"') throw new FormatException("a member name is expected at offset " + position);
                string name = ReadString(text, ref position);
                if (!Take(text, ref position, ':')) throw new FormatException("a colon is expected after " + Quote(name));
                if (obj.ContainsKey(name)) throw new FormatException("the member name " + Quote(name) + " appears twice");
                obj.Add(name, ReadValue(text, ref position));
            } while (Take(text, ref position, ','));
            if (!Take(text, ref position, '}')) throw new FormatException("an object is not closed at offset " + position);
            return obj;
        }
        if (c == '[')
        {
            position++;
            List<object> list = new List<object>();
            if (Take(text, ref position, ']')) return list;
            do
            {
                list.Add(ReadValue(text, ref position));
            } while (Take(text, ref position, ','));
            if (!Take(text, ref position, ']')) throw new FormatException("a list is not closed at offset " + position);
            return list;
        }
        if (c == '"') return Quote(ReadString(text, ref position));
        if (c == '-' || (c >= '0' && c <= '9')) return ReadNumber(text, ref position);
        foreach (string literal in new string[] { "true", "false", "null" })
        {
            if (string.CompareOrdinal(text, position, literal, 0, literal.Length) == 0)
            {
                position += literal.Length;
                return literal;
            }
        }
        throw new FormatException("unexpected character at offset " + position);
    }

    static string ReadString(string text, ref int position)
    {
        StringBuilder builder = new StringBuilder();
        int start = position;
        position++;
        while (true)
        {
            if (position >= text.Length) throw new FormatException("a string starting at offset " + start + " is not closed");
            char c = text[position++];
            if (c == '"') return builder.ToString();
            if (c < 0x20) throw new FormatException("a control character is inside the string at offset " + start);
            if (c != '\\')
            {
                builder.Append(c);
                continue;
            }
            char escape = position < text.Length ? text[position++] : '\0';
            int code;
            switch (escape)
            {
                case '"': builder.Append('"'); break;
                case '\\': builder.Append('\\'); break;
                case '/': builder.Append('/'); break;
                case 'b': builder.Append('\b'); break;
                case 'f': builder.Append('\f'); break;
                case 'n': builder.Append('\n'); break;
                case 'r': builder.Append('\r'); break;
                case 't': builder.Append('\t'); break;
                case 'u':
                    if (position + 4 > text.Length || !int.TryParse(text.Substring(position, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code)) throw new FormatException("an escape in the string at offset " + start + " is not valid");
                    builder.Append((char)code);
                    position += 4;
                    break;
                default: throw new FormatException("an escape in the string at offset " + start + " is not valid");
            }
        }
    }

    static string ReadNumber(string text, ref int position)
    {
        int start = position;
        bool negative = text[position] == '-';
        if (negative) position++;
        int integerStart = position;
        if (position < text.Length && text[position] == '0') position++;
        else if (IsDigit(text, position)) while (IsDigit(text, position)) position++;
        else throw new FormatException("a number at offset " + start + " is not valid");
        string digits = text.Substring(integerStart, position - integerStart);
        decimal exponent = 0;
        if (position < text.Length && text[position] == '.')
        {
            position++;
            int fractionStart = position;
            while (IsDigit(text, position)) position++;
            if (position == fractionStart) throw new FormatException("a number at offset " + start + " is not valid");
            digits += text.Substring(fractionStart, position - fractionStart);
            exponent -= position - fractionStart;
        }
        if (position < text.Length && (text[position] == 'e' || text[position] == 'E'))
        {
            position++;
            int exponentStart = position;
            if (position < text.Length && (text[position] == '+' || text[position] == '-')) position++;
            int exponentDigits = position;
            while (IsDigit(text, position)) position++;
            if (position == exponentDigits) throw new FormatException("a number at offset " + start + " is not valid");
            exponent += decimal.Parse(text.Substring(exponentStart, position - exponentStart), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        }
        digits = digits.TrimStart('0');
        if (digits.Length == 0) return "0";
        string significant = digits.TrimEnd('0');
        exponent += digits.Length - significant.Length;
        return (negative ? "-" : "") + significant + "e" + exponent.ToString(CultureInfo.InvariantCulture);
    }
}
'@

function Test-IsJsonObject {
    param([object]$Node)

    return ($Node -is [System.Collections.Generic.Dictionary[string,object]])
}

function Test-RecordHeader {
    param(
        [string]$Label,
        [object]$Record,
        [string]$EntriesField,
        [object]$Generated
    )

    $problems = [RooIndustriesBundleJson]::HeaderProblems($Record, $Generated, $EntriesField)
    Add-Check ($problems.Length -eq 0) "$Label header fields match the live archive" "$Label header fields differ from the live archive: $($problems -join ', ')"
}

function Test-RecordEntries {
    param(
        [string]$Label,
        [object]$Record,
        [string]$EntriesField,
        [object]$GeneratedEntries,
        [bool]$Complete
    )

    $recordEntries = [RooIndustriesBundleJson]::Field($Record, $EntriesField)
    if (-not ($recordEntries -is [System.Collections.Generic.List[object]])) {
        Add-Failure "$Label $EntriesField is not a list, so it cannot match the live archive"
        return
    }

    $available = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    $generatedByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $generatedKeys = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $GeneratedEntries) {
        $key = [RooIndustriesBundleJson]::Canonical($entry)
        $generatedKeys.Add($key)
        if ($available.ContainsKey($key)) { $available[$key]++ } else { $available[$key] = 1 }
        $generatedByPath[[RooIndustriesBundleJson]::Label($entry)] = $entry
    }

    $unmatched = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $recordEntries) {
        $key = [RooIndustriesBundleJson]::Canonical($entry)
        if ($available.ContainsKey($key) -and $available[$key] -gt 0) {
            $available[$key]--
            continue
        }
        $path = [RooIndustriesBundleJson]::Label($entry)
        if ($generatedByPath.ContainsKey($path)) {
            $fields = [RooIndustriesBundleJson]::DifferentFields($generatedByPath[$path], $entry)
            $reason = if ($fields.Length -eq 0) { 'repeated' } else { "different: $($fields -join ', ')" }
            $unmatched.Add("$path ($reason)") | Out-Null
        } else {
            $unmatched.Add("$path (not in the live archive)") | Out-Null
        }
    }

    $missing = New-Object System.Collections.Generic.List[string]
    if ($Complete) {
        for ($i = 0; $i -lt $generatedKeys.Count; $i++) {
            if ($available[$generatedKeys[$i]] -gt 0) {
                $available[$generatedKeys[$i]]--
                $missing.Add([RooIndustriesBundleJson]::Label($GeneratedEntries[$i])) | Out-Null
            }
        }
    }

    $problems = @()
    if ($unmatched.Count -gt 0) { $problems += "recorded entries that do not match: $($unmatched -join '; ')" }
    if ($missing.Count -gt 0) { $problems += "live entries not recorded exactly once: $($missing -join '; ')" }
    Add-Check ($problems.Count -eq 0) "$Label $($recordEntries.Count) $EntriesField match the live archive" "$Label $EntriesField differ from the live archive: $($problems -join ' | ')"
}

function Test-RecordMatchesArchive {
    param(
        [string]$ResolvedArchivePath,
        [object]$ParsedCatalog
    )

    if ([string]::IsNullOrWhiteSpace($ResolvedArchivePath) -or -not (Test-Path -LiteralPath $ResolvedArchivePath -PathType Leaf)) {
        if ($null -ne $ParsedCatalog) { Add-Pass 'Live Utilities.zip comparison skipped because no archive path was available' }
        return
    }

    try {
        $generated = [RooIndustriesBundleJson]::Parse(((& (Join-Path $PSScriptRoot 'Get-UtilitiesBundleInventory.ps1') -ArchivePath $ResolvedArchivePath) -join "`n"))
    } catch {
        Add-Failure "Could not read the live archive: $($_.Exception.Message)"
        return
    }

    foreach ($record in @(
        @{ Label = 'Catalog'; Path = $catalogFile; EntriesField = 'catalogEntries'; Complete = $true },
        @{ Label = 'Utilities sample'; Path = $sampleFile; EntriesField = 'sampleCatalogEntries'; Complete = $false }
    )) {
        try {
            $document = [RooIndustriesBundleJson]::Parse([System.IO.File]::ReadAllText($record.Path))
        } catch {
            Add-Failure "$($record.Label) cannot be compared with the live archive: $($_.Exception.GetBaseException().Message)"
            continue
        }
        if (-not (Test-IsJsonObject $document)) {
            Add-Failure "$($record.Label) is not a JSON object, so it cannot match the live archive"
            continue
        }
        Test-RecordHeader $record.Label $document $record.EntriesField $generated
        Test-RecordEntries $record.Label $document $record.EntriesField ([RooIndustriesBundleJson]::Field($generated, 'catalogEntries')) $record.Complete
    }
}

$stateBefore = Get-StateEntryCount
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before utilities catalog validation' "backend/state is not empty before utilities catalog validation: $stateBefore item(s)"

$catalog = Read-JsonFile $CatalogPath 'Utilities bundle catalog' $catalogFile
$manifest = Read-JsonFile $ManifestPath 'Utilities manifest' $manifestFile
$sample = Read-JsonFile $SamplePath 'Utilities bundle inventory sample' $sampleFile

if ($null -ne $catalog) {
    $entries = @((Get-PropertyValue $catalog 'catalogEntries' @()))
    $requiredEntryFields = @(
        'archivePath',
        'normalizedId',
        'toolId',
        'displayName',
        'category',
        'risk',
        'productRole',
        'executionClass',
        'allowedExecutionMode',
        'hardwareGates',
        'restoreBackupRequirement',
        'integrationPlan'
    )
    $allowedExecutionClasses = @('native-replacement', 'manual-launcher', 'read-only-detector', 'controlled-reversible-executor', 'dangerous-manual-only', 'excluded')

    Add-Check ([string](Get-PropertyValue $catalog 'sourceArchive' '') -eq 'vendor\Utilities.zip') 'Catalog sourceArchive is repo-relative' 'Catalog sourceArchive is not repo-relative'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'archiveMetadataOnly' $false) -eq $true) 'Catalog boundary is archive metadata only' 'Catalog boundary does not state metadata-only inventory'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'utilityExecutionAllowed' $true) -eq $false) 'Catalog forbids utility execution' 'Catalog does not forbid utility execution'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'fullExtractionAllowed' $true) -eq $false) 'Catalog forbids full extraction' 'Catalog does not forbid full extraction'
    Add-Check ([uint64](Get-PropertyValue $catalog 'sourceArchiveSizeBytes' 0) -eq [uint64]3734508425) 'Catalog records expected Utilities.zip size' 'Catalog source archive size drifted from captured Utilities.zip'
    Add-Check ([int](Get-PropertyValue $catalog 'entryCount' 0) -eq 770) 'Catalog records 770 archive entries' "Catalog entryCount expected 770 actual $([int](Get-PropertyValue $catalog 'entryCount' 0))"
    Add-Check ([int](Get-PropertyValue $catalog 'executableScriptCount' 0) -eq 55) 'Catalog records 55 executable/script entries' "Catalog executableScriptCount expected 55 actual $([int](Get-PropertyValue $catalog 'executableScriptCount' 0))"
    Add-Check ([int](Get-PropertyValue $catalog 'catalogedEntryCount' 0) -eq $entries.Count) 'Catalog catalogedEntryCount matches entries array' 'Catalog catalogedEntryCount does not match entries array'
    Add-Check ($entries.Count -gt 55) 'Catalog includes executable/script plus config/payload metadata entries' 'Catalog only covers executable/script entries'

    $missingFieldHits = New-Object System.Collections.Generic.List[string]
    $invalidExecutionClassHits = New-Object System.Collections.Generic.List[string]
    $autoRunRiskHits = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $path = [string](Get-PropertyValue $entry 'archivePath' '')
        foreach ($field in $requiredEntryFields) {
            $value = Get-PropertyValue $entry $field $null
            $hasValue = $null -ne $value
            if ($value -is [string]) { $hasValue = -not [string]::IsNullOrWhiteSpace($value) }
            if ($field -eq 'hardwareGates') { $hasValue = @($value).Count -gt 0 }
            if (-not $hasValue) {
                $missingFieldHits.Add("$path missing $field") | Out-Null
            }
        }

        $executionClass = [string](Get-PropertyValue $entry 'executionClass' '')
        if ($allowedExecutionClasses -notcontains $executionClass) {
            $invalidExecutionClassHits.Add("$path invalid executionClass $executionClass") | Out-Null
        }
        if ([string](Get-PropertyValue $entry 'risk' '') -in @('high', 'critical')) {
            $mode = [string](Get-PropertyValue $entry 'allowedExecutionMode' '')
            if ($mode -in @('auto-run', 'automatic', 'silent-auto-run')) {
                $autoRunRiskHits.Add("$path allowedExecutionMode=$mode") | Out-Null
            }
        }
    }

    Add-Check ($missingFieldHits.Count -eq 0) "All $($entries.Count) catalog entries carry required fields" "Catalog entries missing required fields: $($missingFieldHits -join '; ')"
    Add-Check ($invalidExecutionClassHits.Count -eq 0) "All $($entries.Count) catalog entries use allowed executionClass values" "Catalog entries with invalid executionClass values: $($invalidExecutionClassHits -join '; ')"
    Add-Check ($autoRunRiskHits.Count -eq 0) 'No high-risk or critical catalog entry is auto-runnable' "High-risk or critical entries appear auto-runnable: $($autoRunRiskHits -join '; ')"

    Test-CatalogTool $entries 'afftool-intpolicy' 3 'read-only-detector'
    Test-CatalogTool $entries 'msi-util-v3' 1 'read-only-detector'
    Test-CatalogTool $entries 'inspectre' 1 'read-only-detector'
    Test-CatalogTool $entries 'unparkcpu' 1 'native-replacement'
    Test-CatalogTool $entries 'latencymon' 1 'read-only-detector'
    Test-CatalogTool $entries 'msi-kombustor' 1 'dangerous-manual-only'
    Test-CatalogTool $entries 'scewin' 1 'dangerous-manual-only'
    Test-CatalogTool $entries 'driver-booster' 1 'excluded'
    Test-CatalogTool $entries 'amd-graphics-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'amd-chipset-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-chipset-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'nvidia-59579-no-app' 1 'manual-launcher'
    Test-CatalogTool $entries 'nvidia-59579-with-app' 1 'manual-launcher'
    Test-CatalogTool $entries 'realtek-network-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'directx-runtime' 1 'manual-launcher'
    Test-CatalogTool $entries 'vcredist-runtime' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-proset-setupbd' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-proset-prounstl' 1 'dangerous-manual-only'
}

Test-RecordMatchesArchive (Get-OptionalArchivePath) $catalog

if ($null -ne $manifest) {
    $allowedManifestClasses = @('native-replacement', 'manual-launcher', 'read-only-detector', 'controlled-reversible-executor', 'dangerous-manual-only', 'excluded')
    foreach ($tool in @((Get-PropertyValue $manifest 'tools' @()))) {
        $id = [string](Get-PropertyValue $tool 'id' '<missing>')
        $class = [string](Get-PropertyValue $tool 'executionClass' '')
        Add-Check ($allowedManifestClasses -contains $class) "Manifest $id uses allowed executionClass" "Manifest $id has invalid executionClass $class"
        Add-Check (@((Get-PropertyValue $tool 'archivePaths' @())).Count -gt 0) "Manifest $id has archive path coverage" "Manifest $id missing archivePaths"
        if ($class -in @('dangerous-manual-only', 'excluded')) {
            Add-Check ((Get-PropertyValue $tool 'autoRunAllowed' $null) -eq $false) "Manifest $id cannot auto-run" "Manifest $id is dangerous/excluded but autoRunAllowed is not false"
        }
    }

    Test-ManifestDecision $manifest 'afftool-intpolicy' 'read-only-detector' $false 'Utilities/AffTool/intPolicy_x64.exe'
    Test-ManifestDecision $manifest 'msi-util-v3' 'read-only-detector' $false 'Utilities/Stock Only (otherwise not necessary)/MSI_util_v3.exe'
    Test-ManifestDecision $manifest 'inspectre' 'read-only-detector' $false 'Utilities/Stock Only (otherwise not necessary)/InSpectre.exe'
    Test-ManifestDecision $manifest 'unparkcpu' 'native-replacement' $false 'Utilities/Stock Only (otherwise not necessary)/UnparkCpu.exe'
    Test-ManifestDecision $manifest 'latencymon' 'read-only-detector' $false 'Utilities/LatencyMon.exe'
    Test-ManifestDecision $manifest 'msi-kombustor' 'dangerous-manual-only' $false 'Utilities/MSI_Kombustor4_Setup_v4.1.36_x64.exe'
    Test-ManifestDecision $manifest 'scewin' 'dangerous-manual-only' $false 'Utilities/DL_SCEWIN.exe'
    Test-ManifestDecision $manifest 'driver-booster' 'excluded' $false 'Utilities/Drivers/driver_booster_setup.exe'
    Test-ManifestDecision $manifest 'amd-graphics-26-2-2' 'manual-launcher' $false 'Utilities/Drivers/Graphics/AMD 26.2.2.exe'
    Test-ManifestDecision $manifest 'amd-chipset-8-02-18-557' 'manual-launcher' $false 'Utilities/Drivers/Chipset/AMD CHIPSET 8.02.18.557.exe'
    Test-ManifestDecision $manifest 'intel-chipset' 'manual-launcher' $false 'Utilities/Drivers/Chipset/Intel Chipset.exe'
    Test-ManifestDecision $manifest 'nvidia-59579-no-app' 'manual-launcher' $false 'Utilities/Drivers/Graphics/NVIDIA_595.79_NO_Nvidia_App.exe'
    Test-ManifestDecision $manifest 'nvidia-59579-with-app' 'manual-launcher' $false 'Utilities/Drivers/Graphics/NVIDIA_595.79_With_Nvidia_App.exe'
    Test-ManifestDecision $manifest 'intel-network' 'manual-launcher' $false 'Utilities/Drivers/Network/Intel Network/SetupBD.exe'
    Test-ManifestDecision $manifest 'realtek-network' 'manual-launcher' $false 'Utilities/Drivers/Network/Realtek Network/Install_PCIE_Win11_11027_20_0920_DMAROFF_11282025.exe'
    Test-ManifestDecision $manifest 'intel-proset-setupbd' 'manual-launcher' $false 'Utilities/Drivers/Network/Intel Network/SetupBD.exe'
    Test-ManifestDecision $manifest 'intel-proset-prounstl' 'dangerous-manual-only' $false 'Utilities/Drivers/Network/Intel Network/PRO1000/Winx64/NDIS65/PROUnstl.exe'
    Test-ManifestDecision $manifest 'directx-runtime' 'manual-launcher' $false 'Utilities/Prerequisites/DX/DXSETUP.exe'
    Test-ManifestDecision $manifest 'vcredist-runtime' 'manual-launcher' $false 'Utilities/Prerequisites/VCRedist/install_all.bat'
}

if ($null -ne $sample) {
    $sampleText = Get-Content -LiteralPath $sampleFile -Raw
    Add-Check ($sampleText -notmatch 'C:\\Users\\') 'Utilities sample contains no private absolute user paths' 'Utilities sample contains a private absolute user path'
    Add-Check ([string](Get-PropertyValue $sample 'sourceArchive' '') -eq 'vendor\Utilities.zip') 'Utilities sample sourceArchive is repo-relative' 'Utilities sample sourceArchive is not repo-relative'
    Add-Check ([int](Get-PropertyValue $sample 'entryCount' 0) -eq 770) 'Utilities sample entryCount matches captured archive' 'Utilities sample entryCount mismatch'
    Add-Check ([int](Get-PropertyValue $sample 'executableScriptCount' 0) -eq 55) 'Utilities sample executableScriptCount matches captured archive' 'Utilities sample executableScriptCount mismatch'
}

$stateAfter = Get-StateEntryCount
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after utilities catalog validation' "backend/state is not empty after utilities catalog validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Utilities bundle catalog validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Utilities bundle catalog validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
