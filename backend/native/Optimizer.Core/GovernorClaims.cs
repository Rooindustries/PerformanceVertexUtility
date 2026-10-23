#nullable enable
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

internal static class GovernorClaims
{
    private sealed record Check(string Field, JsonElement? Original, JsonElement? Proposed);
    private sealed record Claim(string Feature, int ProcessId, long? Created, string? ExecutablePath, string? ImageName, string[] Fields, Check[]? Checks = null, string? Journal = null);
    private sealed record Doubt(string Feature, string Path, string Reason, string[] Fields);

    private sealed class Evidence(string dataRoot, HashSet<string> wanted)
    {
        public string DataRoot { get; } = dataRoot;
        public List<Claim> Claims { get; } = [];
        public List<Doubt> Doubts { get; } = [];
        public bool Wants(string[] fields) => fields.Any(wanted.Contains);
    }

    private static readonly (string Field, string Key)[] Originals =
        [("cpuPriority", "originalPriorityClass"), ("affinity", "originalAffinityMask"), ("ioPriority", "originalIoPriority"), ("gpuPriority", "originalGpuPriority")];

    private static readonly string[] OriginalFields = Originals.Select(pair => pair.Field).ToArray();
    private static readonly string[] CpuFields = ["cpuSets"];

    private static readonly Dictionary<string, string> Labels = new(StringComparer.Ordinal)
    {
        ["cpuPriority"] = "CPU priority", ["affinity"] = "CPU affinity", ["cpuSets"] = "Preferred CPUs", ["ioPriority"] = "I/O priority",
        ["gpuPriority"] = "GPU priority", ["memoryPriority"] = "Memory priority", ["executionQoS"] = "Power mode", ["priorityBoost"] = "Priority boost",
    };

    public static void RequireUnclaimed(SavedProcessRule rule, string dataRoot, string? repoRoot) => RequireUnclaimed([rule], dataRoot, repoRoot);

    public static void RequireUnclaimed(IReadOnlyCollection<SavedProcessRule> rules, string dataRoot, string? repoRoot)
    {
        if (rules.Count == 0) return;
        var fieldsByRule = rules.Select(rule => ProcessPolicyStore.Fields(rule).ToHashSet(StringComparer.Ordinal)).ToArray();
        var evidence = Collect(new Evidence(dataRoot, fieldsByRule.SelectMany(fields => fields).ToHashSet(StringComparer.Ordinal)), Journals(dataRoot, "process-*"), repoRoot);
        Dictionary<int, SnapshotProcess>? running = null;
        var owners = new Dictionary<int, string?>();
        foreach (var (rule, fields) in rules.Zip(fieldsByRule))
        {
            var relevant = evidence.Claims.Where(claim => claim.Fields.Any(fields.Contains) && Matches(rule, claim)).ToArray();
            if (relevant.Length > 0)
            {
                running ??= ProcessSnapshot.Take();
                foreach (var claim in relevant.Where(claim => Running(claim, running) && !OtherAccount(claim, rule.Owner.UserSid, owners)))
                {
                    var held = Held(claim, fields);
                    if (held.Count == 0) continue;
                    var shared = ProcessTarget.ControlNames.Where(held.Contains).Select(field => Labels[field]).ToArray();
                    throw new InvalidOperationException("Undo the " + claim.Feature + " change on " + FileName(claim) + " (or close " + FileName(claim) + ") first, or save this rule without " + string.Join(", ", shared) + ".");
                }
            }
            if (evidence.Doubts.FirstOrDefault(doubt => doubt.Fields.Any(fields.Contains)) is { } unread) throw Unreadable(unread, fields, dataRoot);
        }
    }

    public static string[]? OwnChange(RunningProcess identity, string field, JsonElement current, string dataRoot, string? repoRoot, string journalPath)
    {
        var claims = Overlapping(identity, field, dataRoot, repoRoot, journalPath, out var doubted);
        var holders = claims.Where(claim => claim.Journal is { } path && Sets(path, field, current)).Select(claim => claim.Journal!).ToArray();
        if (holders.Length > 0 || doubted || claims.Any(claim => claim.Journal is null && Sets(claim, field, current))) return holders;
        return null;
    }

    public static (string[] Journals, ReleasedClaim[] Released) SetBack(RunningProcess identity, string field, JsonElement current, JsonElement desired, string dataRoot, string? repoRoot, string journalPath)
    {
        var claims = Overlapping(identity, field, dataRoot, repoRoot, journalPath, out _);
        var journals = claims.Where(claim => claim.Journal is { } path && StartsFrom(path, field, current, desired)).Select(claim => claim.Journal!).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var released = claims.Where(claim => claim.Journal is null && claim.Checks is not null)
            .SelectMany(claim => claim.Checks!.Where(check => check.Field == field && check.Original is { } original && Same(field, desired, original) == true &&
                (check.Proposed is not { } proposed || Same(field, current, proposed) == true)).Select(check => new ReleasedClaim(claim.Feature, check.Original!.Value)))
            .DistinctBy(claim => claim.Feature + "\n" + claim.Original.GetRawText()).ToArray();
        return (journals, released);
    }

    private static Claim[] Overlapping(RunningProcess identity, string field, string dataRoot, string? repoRoot, string journalPath, out bool doubted)
    {
        var self = Path.GetFullPath(journalPath);
        var journals = Journals(dataRoot, "process-*").Concat(SessionJournals(dataRoot)).Where(path => !string.Equals(Path.GetFullPath(path), self, StringComparison.OrdinalIgnoreCase));
        var evidence = Collect(new Evidence(dataRoot, ProcessTarget.ControlNames.ToHashSet(StringComparer.Ordinal)), journals, repoRoot);
        doubted = evidence.Doubts.Any(doubt => doubt.Fields.Contains(field));
        return evidence.Claims.Where(claim => claim.Fields.Contains(field) && SameInstance(claim, identity)).ToArray();
    }

    private static bool Sets(Claim claim, string field, JsonElement current) =>
        claim.Checks?.FirstOrDefault(check => check.Field == field)?.Proposed is not { } proposed || Same(field, current, proposed) != false;

    private static bool Sets(string journal, string field, JsonElement current) => OperationFiles.Read<ProcessControlJournal>(journal).Changes
        .Any(change => change.Name == field && change.Status is "applyIntent" or "applied" or "restoreIntent" && ProcessTarget.Equivalent(field, current, change.Desired));

    private static bool StartsFrom(string journal, string field, JsonElement current, JsonElement desired) => OperationFiles.Read<ProcessControlJournal>(journal).Changes
        .Any(change => change.Name == field && change.Status is "applyIntent" or "applied" or "restoreIntent" && ProcessTarget.Equivalent(field, current, change.Desired) && ProcessTarget.Equivalent(field, desired, change.Original));

    private static Evidence Collect(Evidence evidence, IEnumerable<string> journals, string? repoRoot)
    {
        ApplyOnce(evidence, journals);
        CpuSelection(evidence);
        BackgroundPriorities(evidence);
        if (!string.IsNullOrWhiteSpace(repoRoot))
        {
            var state = Path.Combine(repoRoot, "backend", "state");
            Sessions(Path.Combine(state, "game-tune-sessions"), "Game priority", evidence);
            Sessions(Path.Combine(state, "process-governor-sessions"), "Background limits", evidence);
        }
        return evidence;
    }

    private static bool SameInstance(Claim claim, RunningProcess identity) => claim.ProcessId == identity.ProcessId && (claim.Created is { } created
        ? created.ToString(CultureInfo.InvariantCulture) == identity.CreationTimeFileTimeUtc
        : string.Equals(FileName(claim), Path.GetFileName(identity.ExecutablePath), StringComparison.OrdinalIgnoreCase));

    private static bool OtherAccount(Claim claim, string account, Dictionary<int, string?> owners)
    {
        if (!owners.TryGetValue(claim.ProcessId, out var owner))
        {
            try { owner = ProcessSnapshot.UserSid(claim.ProcessId); }
            catch (Exception) { owner = null; }
            owners[claim.ProcessId] = owner;
        }
        return owner is not null && !string.Equals(owner, account, StringComparison.OrdinalIgnoreCase);
    }

    private static InvalidOperationException Unreadable(Doubt doubt, HashSet<string> fields, string dataRoot)
    {
        var labels = ProcessTarget.ControlNames.Where(name => doubt.Fields.Contains(name) && fields.Contains(name)).Select(name => Labels[name]);
        var reason = doubt.Reason.Trim();
        GovernorLog.Write(Path.Combine(dataRoot, "process-rules"), "Refused a rule change because " + doubt.Path + " could not be read (" + reason + ").");
        return new InvalidOperationException("The app could not read " + doubt.Path + " (" + reason + "), so it cannot tell whether " + doubt.Feature + " still changes " + string.Join(", ", labels) +
            ". Wait for it to finish or undo the " + doubt.Feature + " change in the app. If that file is damaged or its app is gone, delete it, then try again.");
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
            if (!live.TryGetValue(check.Field, out var value) || value is not { } current) return true;
            if (claim.Feature == "Background limits") return check.Proposed is not { } proposed || Same(check.Field, current, proposed) != false;
            return check.Original is not { } original || !Restorable(check.Field, original) || Same(check.Field, current, original) != true;
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
            case "memoryPriority":
                return Level(live, null) is { } memory && Level(recorded, null) is { } wantedMemory ? memory == wantedMemory : null;
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

    private static void ApplyOnce(Evidence evidence, IEnumerable<string> journals)
    {
        if (!evidence.Wants(ProcessTarget.ControlNames)) return;
        foreach (var path in journals)
        {
            using var document = Open(path, "Apply once", ProcessTarget.ControlNames, evidence);
            if (document is null) continue;
            var root = document.RootElement;
            var status = Text(root, "status");
            if (status is "restored" or "expired") continue;
            if (status is not ("applying" or "applied" or "needsReconciliation") || Child(root, "changes") is not { ValueKind: JsonValueKind.Array })
            {
                evidence.Doubts.Add(new("Apply once", path, "it is not a complete Apply once record", ProcessTarget.ControlNames));
                continue;
            }
            var applying = status == "applying";
            var fields = new List<string>();
            foreach (var change in Items(root, "changes").Where(change => Text(change, "status") is "applyIntent" or "applied" or "restoreIntent" || applying && Text(change, "status") == "pending"))
            {
                if (Field(Text(change, "name")) is { } field) fields.Add(field);
                else evidence.Doubts.Add(new("Apply once", path, "it changes a setting this app does not know", ProcessTarget.ControlNames));
            }
            var changed = fields.Distinct().ToArray();
            if (changed.Length == 0) continue;
            if (Identity(Child(Child(root, "preview"), "identity"), "Apply once", changed) is { } claim) evidence.Claims.Add(claim with { Journal = path });
            else evidence.Doubts.Add(new("Apply once", path, "it does not say which process it changed", changed));
        }
    }

    private static void CpuSelection(Evidence evidence)
    {
        if (!evidence.Wants(CpuFields)) return;
        foreach (var path in Journals(evidence.DataRoot, "cpu-*"))
        {
            using var document = Open(path, "CPU selection", CpuFields, evidence);
            if (document is null) continue;
            var root = document.RootElement;
            var status = Text(root, "status");
            if (Text(root, "kind") != "cpu-set-journal" || status is not ("apply-intent" or "applied" or "restore-intent" or "needs-reconciliation" or "restored"))
            {
                evidence.Doubts.Add(new("CPU selection", path, "it is not a complete CPU selection record", CpuFields));
                continue;
            }
            if (status == "restored") continue;
            if (Identity(Child(Child(root, "preview"), "identity"), "CPU selection", CpuFields) is { } claim) evidence.Claims.Add(claim);
            else evidence.Doubts.Add(new("CPU selection", path, "it does not say which process it changed", CpuFields));
        }
    }

    private static void BackgroundPriorities(Evidence evidence)
    {
        if (!evidence.Wants(OriginalFields)) return;
        var pointer = Path.Combine(evidence.DataRoot, "settings", "process-profile-recovery.json");
        if (!File.Exists(pointer)) return;
        using var recovery = Open(pointer, "Background priorities", OriginalFields, evidence);
        if (recovery is null) return;
        var path = Text(recovery.RootElement, "path");
        var id = Text(recovery.RootElement, "id");
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(id) || !Path.IsPathFullyQualified(path) || !File.Exists(path)) return;
        using var backup = Open(path, "Background priorities", OriginalFields, evidence);
        if (backup is null) return;
        var root = backup.RootElement;
        if (Text(root, "actionId") != "performance.applyProfile" || Text(root, "backupId") != id || Child(root, "dryRun")?.ValueKind != JsonValueKind.False) return;
        foreach (var snapshot in Items(root, "snapshots")) Snapshot(snapshot, "Background priorities", path, evidence);
    }

    private static void Sessions(string root, string feature, Evidence evidence)
    {
        if (!evidence.Wants(OriginalFields) || !Directory.Exists(root)) return;
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var sessionPath = Path.Combine(directory, "session.json");
            if (!File.Exists(sessionPath)) continue;
            using var session = Open(sessionPath, feature, OriginalFields, evidence);
            if (session is null) continue;
            var state = session.RootElement;
            var restorable = Child(state, "restorable")?.ValueKind;
            if (restorable is not (JsonValueKind.True or JsonValueKind.False) && Text(state, "status") is null && Text(state, "sessionStatus") is null)
            {
                evidence.Doubts.Add(new(feature, sessionPath, "it does not say whether the session is still active", OriginalFields));
                continue;
            }
            if (restorable != JsonValueKind.True && Text(state, "status") != "running" && Text(state, "sessionStatus") != "running") continue;
            foreach (var active in Items(state, "activeRestraints"))
            {
                if (Child(active, "snapshot") is { ValueKind: JsonValueKind.Object } snapshot) Snapshot(snapshot, feature, sessionPath, evidence);
                else evidence.Doubts.Add(new(feature, sessionPath, "an active restraint lists no process snapshot", OriginalFields));
            }
            var backupPath = Path.Combine(directory, "backup.json");
            if (!File.Exists(backupPath) && Text(state, "backupManifestPath") is { } recorded && Path.IsPathFullyQualified(recorded)) backupPath = recorded;
            if (!File.Exists(backupPath)) continue;
            using var backup = Open(backupPath, feature, OriginalFields, evidence);
            if (backup is null) continue;
            foreach (var snapshot in Items(backup.RootElement, "snapshots")) Snapshot(snapshot, feature, backupPath, evidence);
        }
    }

    private static void Snapshot(JsonElement snapshot, string feature, string path, Evidence evidence)
    {
        if (snapshot.ValueKind != JsonValueKind.Object)
        {
            evidence.Doubts.Add(new(feature, path, "it lists something that is not a process snapshot", OriginalFields));
            return;
        }
        var checks = new Dictionary<string, Check>(StringComparer.Ordinal);
        if (Child(snapshot, "controlChanges") is { ValueKind: JsonValueKind.Array or JsonValueKind.Object })
        {
            foreach (var change in Items(snapshot, "controlChanges").Where(change => Child(change, "blocked")?.ValueKind != JsonValueKind.True))
                if (Field(Text(change, "control")) is { } field) checks[field] = new(field, Original(snapshot, field), Present(Child(change, "proposedValue")));
        }
        else
        {
            foreach (var field in OriginalFields)
                if (Original(snapshot, field) is { } original) checks[field] = new(field, original, null);
        }
        if (checks.Count == 0) return;
        var executablePath = Text(snapshot, "executablePath");
        var name = Text(snapshot, "processName");
        if (Number(snapshot, "processId") is not { } processId || processId <= 0 || string.IsNullOrWhiteSpace(executablePath) && string.IsNullOrWhiteSpace(name))
        {
            evidence.Doubts.Add(new(feature, path, "it does not say which process it changed", checks.Keys.ToArray()));
            return;
        }
        var started = Time(Text(snapshot, "processStartTimeUtc"));
        if (!string.IsNullOrWhiteSpace(name) && !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name += ".exe";
        evidence.Claims.Add(new(feature, processId, started?.ToFileTimeUtc(), executablePath, name, checks.Keys.ToArray(), checks.Values.ToArray()));
    }

    private static JsonElement? Original(JsonElement snapshot, string field) =>
        (field == "memoryPriority" ? "originalMemoryPriority" : Originals.FirstOrDefault(pair => pair.Field == field).Key) is { } key ? Present(Child(snapshot, key)) : null;

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

    private static IEnumerable<string> SessionJournals(string dataRoot)
    {
        var operations = Path.Combine(dataRoot, "operations");
        if (!Directory.Exists(operations)) return [];
        var paths = new List<string>();
        foreach (var directory in Directory.EnumerateDirectories(operations, "game-session-*"))
        {
            var session = Path.Combine(directory, "session");
            paths.Add(Path.Combine(session, "launcher-journal.json"));
            var games = Path.Combine(session, "games");
            if (Directory.Exists(games)) paths.AddRange(Directory.EnumerateDirectories(games).SelectMany(Directory.EnumerateDirectories).Select(field => Path.Combine(field, "journal.json")));
        }
        return paths.Where(File.Exists).ToArray();
    }

    private static JsonDocument? Open(string path, string feature, string[] fields, Evidence evidence)
    {
        var document = Read(path, feature, fields, evidence);
        if (document is null || document.RootElement.ValueKind == JsonValueKind.Object) return document;
        document.Dispose();
        evidence.Doubts.Add(new(feature, path, "it does not hold a record this app wrote", fields));
        return null;
    }

    private static JsonDocument? Read(string path, string feature, string[] fields, Evidence evidence)
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
                evidence.Doubts.Add(new(feature, path, error.Message, fields));
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
