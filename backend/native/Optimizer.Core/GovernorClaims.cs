#nullable enable
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

internal static class GovernorClaims
{
    private sealed record Check(string Field, JsonElement? Original, JsonElement? Proposed);
    private sealed record Claim(string Feature, int ProcessId, long? Created, string? ExecutablePath, string? ImageName, string[] Fields, Check[]? Checks = null);

    private static readonly (string Field, string Key)[] Originals =
        [("cpuPriority", "originalPriorityClass"), ("affinity", "originalAffinityMask"), ("ioPriority", "originalIoPriority"), ("gpuPriority", "originalGpuPriority")];

    private static readonly Dictionary<string, string> Labels = new(StringComparer.Ordinal)
    {
        ["cpuPriority"] = "CPU priority", ["affinity"] = "CPU affinity", ["cpuSets"] = "Preferred CPUs", ["ioPriority"] = "I/O priority",
        ["gpuPriority"] = "GPU priority", ["memoryPriority"] = "Memory priority", ["executionQoS"] = "Power mode", ["priorityBoost"] = "Priority boost",
    };

    public static void RequireUnclaimed(SavedProcessRule rule, string dataRoot, string? repoRoot) => RequireUnclaimed([rule], dataRoot, repoRoot);

    public static void RequireUnclaimed(IReadOnlyCollection<SavedProcessRule> rules, string dataRoot, string? repoRoot)
    {
        if (rules.Count == 0) return;
        var claims = new List<Claim>();
        ApplyOnce(dataRoot, claims);
        CpuSelection(dataRoot, claims);
        BackgroundPriorities(dataRoot, claims);
        if (!string.IsNullOrWhiteSpace(repoRoot))
        {
            var state = Path.Combine(repoRoot, "backend", "state");
            Sessions(dataRoot, Path.Combine(state, "game-tune-sessions"), "Game priority", claims);
            Sessions(dataRoot, Path.Combine(state, "process-governor-sessions"), "Background limits", claims);
        }
        Dictionary<int, SnapshotProcess>? running = null;
        foreach (var rule in rules)
        {
            var fields = ProcessPolicyStore.Fields(rule).ToHashSet(StringComparer.Ordinal);
            var relevant = claims.Where(claim => claim.Fields.Any(fields.Contains) && Matches(rule, claim)).ToArray();
            if (relevant.Length == 0) continue;
            running ??= ProcessSnapshot.Take();
            foreach (var claim in relevant.Where(claim => Running(claim, running)))
            {
                var held = Held(claim, fields);
                if (held.Count == 0) continue;
                var shared = ProcessTarget.ControlNames.Where(held.Contains).Select(field => Labels[field]).ToArray();
                throw new InvalidOperationException("Undo the " + claim.Feature + " change on " + FileName(claim) + " (or close " + FileName(claim) + ") first, or save this rule without " + string.Join(", ", shared) + ".");
            }
        }
    }

    private static HashSet<string> Held(Claim claim, HashSet<string> fields)
    {
        var held = claim.Fields.Where(fields.Contains).ToHashSet(StringComparer.Ordinal);
        if (claim.Checks is null || held.Count == 0) return held;
        var checks = claim.Checks.Where(check => held.Contains(check.Field)).ToArray();
        var live = Live(claim, checks.Select(check => check.Field).ToArray());
        if (live is null) return [];
        return checks.Where(check =>
        {
            if (check.Original is not { } original || !Restorable(check.Field, original)) return false;
            if (!live.TryGetValue(check.Field, out var value) || value is not { } current) return true;
            if (claim.Feature != "Background limits") return Same(check.Field, current, original) != true;
            return check.Proposed is not { } proposed || Same(check.Field, current, proposed) != false;
        }).Select(check => check.Field).ToHashSet(StringComparer.Ordinal);
    }

    private static Dictionary<string, JsonElement?>? Live(Claim claim, string[] names)
    {
        var values = new Dictionary<string, JsonElement?>(StringComparer.Ordinal);
        ProcessTarget target;
        try { target = new ProcessTarget(claim.ProcessId, readControls: names.Contains("gpuPriority") ? new[] { "gpuPriority" } : null); }
        catch (Exception)
        {
            try { target = new ProcessTarget(claim.ProcessId); }
            catch (Exception) { return Exited(claim.ProcessId) ? null : values; }
        }
        using (target)
        {
            try
            {
                if (claim.Created is { } created && target.Identity().CreationTimeFileTimeUtc != created.ToString(CultureInfo.InvariantCulture)) return null;
            }
            catch (Exception) { return Exited(claim.ProcessId) ? null : values; }
            foreach (var name in names)
            {
                try
                {
                    var read = target.Read(name);
                    values[name] = read.Known && read.Error is null && read.Value is { ValueKind: not (JsonValueKind.Null or JsonValueKind.Undefined) } value ? value : null;
                }
                catch (Exception) { values[name] = null; }
            }
        }
        return values;
    }

    private static bool Exited(int processId)
    {
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(processId);
            return process.HasExited;
        }
        catch (ArgumentException) { return true; }
        catch (Exception) { return false; }
    }

    private static bool Restorable(string field, JsonElement original) => field switch
    {
        "cpuPriority" => original.ValueKind == JsonValueKind.String && PriorityNames.Contains(original.GetString(), StringComparer.OrdinalIgnoreCase),
        "affinity" => original.ValueKind == JsonValueKind.Number ? original.TryGetInt64(out var mask) && mask > 0
            : original.ValueKind == JsonValueKind.String && long.TryParse(original.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var text) && text > 0,
        "ioPriority" => original.ValueKind == JsonValueKind.String && Level(original, IoNames) is not null,
        "gpuPriority" => original.ValueKind == JsonValueKind.String && Level(original, GpuNames) is not null,
        _ => false,
    };

    private static readonly string[] PriorityNames = ["Idle", "BelowNormal", "Normal", "AboveNormal", "High"];
    private static readonly string[] IoNames = ["VeryLow", "Low", "Normal"];
    private static readonly string[] GpuNames = ["Idle", "BelowNormal", "Normal", "AboveNormal", "High", "Realtime"];

    private static bool? Same(string field, JsonElement live, JsonElement recorded)
    {
        switch (field)
        {
            case "cpuPriority":
                return live.ValueKind == JsonValueKind.String && recorded.ValueKind == JsonValueKind.String
                    ? string.Equals(live.GetString(), recorded.GetString(), StringComparison.OrdinalIgnoreCase) : null;
            case "affinity":
                if (Text(live, "mask") is not { } mask) return null;
                ulong current;
                try { current = ProcessTarget.ParseMask(mask); }
                catch (Exception) { return null; }
                if (recorded.ValueKind == JsonValueKind.Number && recorded.TryGetInt64(out var number)) return current == unchecked((ulong)number);
                if (recorded.ValueKind == JsonValueKind.String && long.TryParse(recorded.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)) return current == unchecked((ulong)parsed);
                return null;
            case "ioPriority":
                return Level(live, null) is { } io && Level(recorded, IoNames) is { } wantedIo ? io == wantedIo : null;
            case "gpuPriority":
                return Level(live, null) is { } gpu && Level(recorded, GpuNames) is { } wantedGpu ? gpu == wantedGpu : null;
            default:
                return null;
        }
    }

    private static int? Level(JsonElement value, string[]? names)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
        if (names is null || value.ValueKind != JsonValueKind.String) return null;
        var text = value.GetString();
        if (string.Equals(text, "Idle", StringComparison.OrdinalIgnoreCase) && names[0] == "VeryLow") return 0;
        var index = Array.FindIndex(names, name => string.Equals(name, text, StringComparison.OrdinalIgnoreCase));
        return index >= 0 ? index : null;
    }

    private static void ApplyOnce(string dataRoot, List<Claim> claims)
    {
        foreach (var path in Journals(dataRoot, "process-*"))
        {
            using var document = Read(path, dataRoot);
            if (document is null) continue;
            var root = document.RootElement;
            if (Text(root, "status") is "restored" or "expired") continue;
            var applying = Text(root, "status") == "applying";
            var fields = Items(root, "changes").Where(change => Text(change, "status") is "applyIntent" or "applied" or "restoreIntent" || applying && Text(change, "status") == "pending")
                .Select(change => Field(Text(change, "name"))).OfType<string>().Distinct().ToArray();
            if (fields.Length > 0 && Identity(Child(Child(root, "preview"), "identity"), "Apply once", fields) is { } claim) claims.Add(claim);
        }
    }

    private static void CpuSelection(string dataRoot, List<Claim> claims)
    {
        foreach (var path in Journals(dataRoot, "cpu-*"))
        {
            using var document = Read(path, dataRoot);
            if (document is null) continue;
            var root = document.RootElement;
            if (Text(root, "kind") != "cpu-set-journal" || Text(root, "status") is not ("apply-intent" or "applied" or "restore-intent" or "needs-reconciliation")) continue;
            if (Identity(Child(Child(root, "preview"), "identity"), "CPU selection", ["cpuSets"]) is { } claim) claims.Add(claim);
        }
    }

    private static void BackgroundPriorities(string dataRoot, List<Claim> claims)
    {
        var pointer = Path.Combine(dataRoot, "settings", "process-profile-recovery.json");
        if (!File.Exists(pointer)) return;
        using var recovery = Read(pointer, dataRoot);
        if (recovery is null) return;
        var path = Text(recovery.RootElement, "path");
        var id = Text(recovery.RootElement, "id");
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(id) || !Path.IsPathFullyQualified(path) || !File.Exists(path)) return;
        using var backup = Read(path, dataRoot);
        if (backup is null) return;
        var root = backup.RootElement;
        if (Text(root, "actionId") != "performance.applyProfile" || Text(root, "backupId") != id || Child(root, "dryRun")?.ValueKind != JsonValueKind.False) return;
        foreach (var snapshot in Items(root, "snapshots"))
            if (Snapshot(snapshot, "Background priorities") is { } claim) claims.Add(claim);
    }

    private static void Sessions(string dataRoot, string root, string feature, List<Claim> claims)
    {
        if (!Directory.Exists(root)) return;
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var sessionPath = Path.Combine(directory, "session.json");
            if (!File.Exists(sessionPath)) continue;
            using var session = Read(sessionPath, dataRoot);
            if (session is null) continue;
            var state = session.RootElement;
            if (Child(state, "restorable")?.ValueKind != JsonValueKind.True && Text(state, "status") != "running" && Text(state, "sessionStatus") != "running") continue;
            foreach (var active in Items(state, "activeRestraints"))
                if (Child(active, "snapshot") is { } snapshot && Snapshot(snapshot, feature) is { } claim) claims.Add(claim);
            var backupPath = Path.Combine(directory, "backup.json");
            if (!File.Exists(backupPath) && Text(state, "backupManifestPath") is { } recorded && Path.IsPathFullyQualified(recorded)) backupPath = recorded;
            if (!File.Exists(backupPath)) continue;
            using var backup = Read(backupPath, dataRoot);
            if (backup is null) continue;
            foreach (var snapshot in Items(backup.RootElement, "snapshots"))
                if (Snapshot(snapshot, feature) is { } claim) claims.Add(claim);
        }
    }

    private static Claim? Snapshot(JsonElement snapshot, string feature)
    {
        if (Number(snapshot, "processId") is not { } processId || processId <= 0) return null;
        var checks = new Dictionary<string, Check>(StringComparer.Ordinal);
        foreach (var change in Items(snapshot, "controlChanges").Where(change => Child(change, "blocked")?.ValueKind != JsonValueKind.True))
            if (Field(Text(change, "control")) is { } field) checks[field] = new(field, Original(snapshot, field), Present(Child(change, "proposedValue")));
        if (checks.Count == 0) return null;
        if (feature == "Background priorities" && (Original(snapshot, "cpuPriority") is not { } priority || !Restorable("cpuPriority", priority))) return null;
        var started = Time(Text(snapshot, "processStartTimeUtc"));
        var name = Text(snapshot, "processName");
        if (!string.IsNullOrWhiteSpace(name) && !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name += ".exe";
        return new(feature, processId, started?.ToFileTimeUtc(), Text(snapshot, "executablePath"), name, checks.Keys.ToArray(), checks.Values.ToArray());
    }

    private static JsonElement? Original(JsonElement snapshot, string field) =>
        Originals.FirstOrDefault(pair => pair.Field == field).Key is { } key ? Present(Child(snapshot, key)) : null;

    private static JsonElement? Present(JsonElement? value) =>
        value is { ValueKind: not (JsonValueKind.Null or JsonValueKind.Undefined) } present && !(present.ValueKind == JsonValueKind.String && string.IsNullOrWhiteSpace(present.GetString())) ? present.Clone() : null;

    private static Claim? Identity(JsonElement? identity, string feature, string[] fields)
    {
        if (identity is not { } value || Number(value, "processId") is not { } processId || processId <= 0) return null;
        long? created = long.TryParse(Text(value, "creationTimeFileTimeUtc"), NumberStyles.None, CultureInfo.InvariantCulture, out var time) ? time : null;
        return new(feature, processId, created, Text(value, "executablePath"), null, fields);
    }

    private static bool Matches(SavedProcessRule rule, Claim claim)
    {
        if (rule.MatchMode != "filename" && !string.IsNullOrWhiteSpace(claim.ExecutablePath)) return ProcessPolicyStore.Matches(rule, claim.ExecutablePath);
        return string.Equals(Path.GetFileName(rule.ExecutablePath), FileName(claim), StringComparison.OrdinalIgnoreCase);
    }

    private static bool Running(Claim claim, Dictionary<int, SnapshotProcess> running)
    {
        if (!running.TryGetValue(claim.ProcessId, out var live)) return false;
        if (claim.Created is { } created)
            return long.TryParse(live.CreationTimeFileTimeUtc, NumberStyles.None, CultureInfo.InvariantCulture, out var actual) && actual == created;
        return string.Equals(live.ImageName, FileName(claim), StringComparison.OrdinalIgnoreCase);
    }

    private static string FileName(Claim claim) => string.IsNullOrWhiteSpace(claim.ExecutablePath) ? claim.ImageName ?? "this app" : Path.GetFileName(claim.ExecutablePath);

    private static string? Field(string? control) => control switch
    {
        "priorityClass" => "cpuPriority",
        "affinityMask" => "affinity",
        { } name when ProcessTarget.ControlNames.Contains(name) => name,
        _ => null,
    };

    private static IEnumerable<string> Journals(string dataRoot, string pattern)
    {
        var operations = Path.Combine(dataRoot, "operations");
        if (!Directory.Exists(operations)) return [];
        return Directory.EnumerateDirectories(operations, pattern).Select(directory => Path.Combine(directory, "journal.json")).Where(File.Exists).ToArray();
    }

    private static JsonDocument? Read(string path, string dataRoot)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: true);
                return JsonDocument.Parse(reader.ReadToEnd());
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return null; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
            {
                if (attempt < 20) { Thread.Sleep(50); continue; }
                GovernorLog.Write(Path.Combine(dataRoot, "process-rules"), "Skipped an unreadable record while checking other features before a rule change: " + path + " (" + error.Message + ")");
                return null;
            }
        }
    }

    private static JsonElement? Child(JsonElement? element, string name) =>
        element is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(name, out var child) ? child : null;

    private static string? Text(JsonElement element, string name) => Child(element, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    private static int? Number(JsonElement element, string name) => Child(element, name) switch
    {
        { ValueKind: JsonValueKind.Number } value when value.TryGetInt32(out var number) => number,
        { ValueKind: JsonValueKind.String } value when int.TryParse(value.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, out var number) => number,
        _ => null,
    };

    private static IEnumerable<JsonElement> Items(JsonElement element, string name) => Child(element, name) switch
    {
        { ValueKind: JsonValueKind.Array } value => value.EnumerateArray().ToArray(),
        { ValueKind: JsonValueKind.Object } value => new[] { value },
        _ => Array.Empty<JsonElement>(),
    };

    private static DateTime? Time(string? text) =>
        DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var time) && time.Year >= 1601 ? time : null;
}
