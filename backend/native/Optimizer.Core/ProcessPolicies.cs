#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public sealed record SavedProcessRule
{
    public required int SchemaVersion { get; init; }
    public required string RuleId { get; init; }
    public string Revision { get; init; } = "";
    public required OperationOwner Owner { get; init; }
    public required string Name { get; init; }
    public required bool Enabled { get; init; }
    public required string MatchMode { get; init; }
    public required string ExecutablePath { get; init; }
    public required string? ExecutableHash { get; init; }
    public required Dictionary<string, JsonElement> Controls { get; init; }
    public required CpuSelection? CpuSelection { get; init; }
    public string? AffinityTopologyHash { get; init; }
}

public sealed class PolicyInstance
{
    public required string RuleId { get; init; }
    public required string RuleHash { get; init; }
    public required RunningProcess Process { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required string JournalPath { get; init; }
    public required string Status { get; set; }
    public string? Error { get; set; }
    public string? Field { get; init; }
    public string? ErrorKind { get; set; }
}

public sealed class PolicyHostState
{
    public required int SchemaVersion { get; init; }
    public required OperationOwner Owner { get; init; }
    public required string Status { get; set; }
    public required RunningProcess? Host { get; set; }
    public required List<PolicyInstance> Instances { get; init; }
    public required List<string> Errors { get; set; }
    public List<PolicyIssue> Issues { get; set; } = [];
    public required DateTime UpdatedAtUtc { get; set; }
}

public sealed record PolicyIssue(string RuleId, int? ProcessId, string? ExecutablePath, string Message)
{
    public string Kind { get; init; } = "error";
    public string? Field { get; init; }
}

public sealed record PolicyDiagnostics(int Instances, int Watched, int Retries, int Gates, int RuleChecks, int Hashes, long ProcessOpens, long HashAttempts, long OwnerLookups);
public sealed record PolicyHeartbeat(RunningProcess Host, long Tick, long ProgressTick, string? BootId, DateTime AtUtc, PolicyDiagnostics? Diagnostics);
public sealed record PolicyWorkerStatus(PolicyHostState? State, bool? HostRunning, string? Error);
public sealed record PolicyStopRequest(OperationOwner Owner, RunningProcess Host);
public sealed record GovernorSettings([property: JsonRequired] int SchemaVersion, [property: JsonRequired] bool Paused);
public sealed record PolicySummary(bool Secured, string? SecurityProblem, bool Paused, int Rules, int EnabledRules, string? RulesError, string[]? UnreadableRules = null);

public static class GovernorLog
{
    public const long Limit = 256 * 1024;

    public static void Write(string policyRoot, string message)
    {
        try
        {
            if (!Directory.Exists(policyRoot)) return;
            var path = Path.Combine(policyRoot, "logs", "governor.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var file = new FileInfo(path);
            if (file.Exists && file.Length > Limit) File.Move(path, path + ".1", true);
            File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

public sealed class ProcessPolicyStore
{
    public static readonly string[] LaunchFields = ["cpuPriority", "ioPriority", "memoryPriority"];
    private static readonly TimeSpan RulesLockWait = TimeSpan.FromSeconds(45);
    private const long ClockSkew = 1000;
    private const int SharingViolation = unchecked((int)0x80070020), LockViolation = unchecked((int)0x80070021);
    public string Root { get; }
    public string RulesDirectory => Path.Combine(Root, "rules");
    public string StatePath => Path.Combine(Root, "host.json");
    public string HeartbeatPath => Path.Combine(Root, "heartbeat.json");
    public string StopPath => Path.Combine(Root, "stop.request");
    public string SettingsPath => Path.Combine(Root, "governor.json");

    public ProcessPolicyStore(string root)
    {
        Root = Path.GetFullPath(root);
#if GOVERNOR_TEST_HOOKS
        ProcessPolicyHost.ClockRoot = Root;
#endif
    }

    public static string DefaultRoot => Path.Combine(BrandCompatibility.LocalDataRoot, "process-rules");

    public bool Secure()
    {
        DataFolder.EnsureFor(Root);
        return PolicyRootSecurity.Secure(Root);
    }

    public bool Paused()
    {
        if (!File.Exists(SettingsPath)) return false;
        var settings = OperationFiles.Read<GovernorSettings>(SettingsPath);
        if (settings.SchemaVersion != 1) throw new InvalidDataException("Unsupported governor settings version.");
        return settings.Paused;
    }

    public void SetPaused(bool paused, string? repoRoot = null)
    {
        Secure();
        using var rootLease = PolicyRootLease.Acquire(Root);
        using var lease = LockRules();
        using var gate = paused ? null : Gate();
        if (!paused)
        {
            var enabled = ReadRules().Where(pair => pair.Rule.Enabled).Select(pair => pair.Rule).ToArray();
            foreach (var rule in enabled) RequireNoGameSession(rule);
            GovernorClaims.RequireUnclaimed(enabled, Path.GetDirectoryName(Root)!, repoRoot);
        }
        if (rootLease.Moved) throw new UnauthorizedAccessException("The saved rules folder moved while it was changed.");
        OperationFiles.Write(SettingsPath, new GovernorSettings(1, paused));
    }

    public PolicySummary Summary(bool deep = true)
    {
        string? problem;
        try { problem = PolicyRootSecurity.Problem(Root, deep); }
        catch (Exception error) { problem = error.Message; }
        var paused = false;
        (SavedProcessRule Rule, string Hash)[] rules = [];
        string? rulesError = null;
        var unreadable = new List<string>();
        try { paused = Paused(); }
        catch (Exception error) { rulesError = error.Message; }
        try { rules = ReadRules(null, unreadable); }
        catch (Exception error) { rulesError ??= error.Message; }
        return new(problem is null, problem, paused, rules.Length, rules.Count(pair => pair.Rule.Enabled), rulesError, unreadable.ToArray());
    }

    public static string RootFor(string? path)
    {
        for (var directory = path is null ? null : Path.GetDirectoryName(Path.GetFullPath(path)); directory is not null; directory = Path.GetDirectoryName(directory))
            if (string.Equals(Path.GetFileName(directory), "operations", StringComparison.OrdinalIgnoreCase))
                return Path.Combine(Path.GetDirectoryName(directory)!, "process-rules");
        return DefaultRoot;
    }

    public static IEnumerable<string> Fields(SavedProcessRule rule)
    {
        var fields = rule.Controls.Keys.Concat(rule.CpuSelection is null ? [] : new[] { "cpuSets" }).ToHashSet(StringComparer.Ordinal);
        return ProcessTarget.ControlNames.Where(fields.Contains);
    }

    public string[] OwnedControls(string executablePath)
    {
        if (!Directory.Exists(Root)) return [];
        var owned = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var (rule, _) in ReadRules().Where(pair => pair.Rule.Enabled && Matches(pair.Rule, executablePath))) owned.UnionWith(Fields(rule));
        return owned.ToArray();
    }

    public string[] OwnedLaunchControls(string gamePath)
    {
        if (!Directory.Exists(Root)) return [];
        var owned = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var (rule, _) in ReadRules().Where(pair => pair.Rule.Enabled))
            foreach (var field in Fields(rule))
                if (LaunchFields.Contains(field) ? SameFileName(rule.ExecutablePath, gamePath) : Matches(rule, gamePath)) owned.Add(field);
        return owned.ToArray();
    }

    public string[] OwnedControls(RunningProcess identity)
    {
        if (!Directory.Exists(Root)) return [];
        var owned = new SortedSet<string>(OwnedControls(identity.ExecutablePath), StringComparer.Ordinal);
        if (File.Exists(StatePath))
            foreach (var instance in OperationFiles.Read<PolicyHostState>(StatePath).Instances.Where(instance => instance.Status is "applying" or "active" or "conflict" &&
                instance.Process.ProcessId == identity.ProcessId && instance.Process.CreationTimeFileTimeUtc == identity.CreationTimeFileTimeUtc))
                owned.UnionWith(instance.Field is { } field ? new[] { field } : OperationFiles.Read<ProcessControlPreview>(OperationPath(instance.PreviewPath, "preview.json")).Desired.Keys.ToArray());
        return owned.ToArray();
    }

    public string OperationPath(string path, string file)
    {
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full)!;
        if (!string.Equals(Path.GetFileName(full), file, StringComparison.Ordinal) || !Guid.TryParseExact(Path.GetFileName(directory), "N", out _) ||
            !string.Equals(Path.GetDirectoryName(directory), Path.Combine(Root, "operations"), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("A governor record points outside its protected operations folder.");
        return full;
    }

    public void ValidateState(PolicyHostState state)
    {
        state.Owner.Verify();
        if (state.SchemaVersion != 1) throw new InvalidDataException("Unsupported policy-host state version.");
        foreach (var instance in state.Instances)
        {
            OperationPath(instance.PreviewPath, "preview.json");
            OperationPath(instance.JournalPath, "journal.json");
            if (!string.Equals(Path.GetDirectoryName(instance.PreviewPath), Path.GetDirectoryName(instance.JournalPath), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("A governor record mixes two operations.");
            if (instance.Field is { } field && !ProcessTarget.ControlNames.Contains(field)) throw new InvalidDataException("A governor record names an unknown process control.");
            if (instance.Status is not ("applying" or "active" or "conflict" or "restored" or "expired")) throw new InvalidDataException("A governor record has an unknown status.");
        }
    }

    public void RequireUnowned(RunningProcess identity, IEnumerable<string> controls) => Refuse(OwnedControls(identity).Intersect(controls).ToArray());

    public void RequireUnowned(string executablePath, IEnumerable<string> controls) => Refuse(OwnedControls(executablePath).Intersect(controls).ToArray());

    public void RequireUnownedRestore(RunningProcess identity, IEnumerable<string> controls)
    {
        if (!Exited(identity)) RequireUnowned(identity, controls);
    }

    public void RequireUnownedLaunch(string gamePath, IEnumerable<string> controls) => Refuse(OwnedLaunchControls(gamePath).Intersect(controls).ToArray());

    private static void Refuse(string[] owned)
    {
        if (owned.Length > 0)
            throw new InvalidOperationException("Managed by the governor: " + string.Join(", ", owned) + ". Turn off or change its rule for this app first, or put its settings back if the rule is already off.");
    }

    public static bool Matches(SavedProcessRule rule, string executablePath) => rule.MatchMode == "filename"
        ? SameFileName(rule.ExecutablePath, executablePath)
        : string.Equals(rule.ExecutablePath, executablePath, StringComparison.OrdinalIgnoreCase);

    private static bool SameFileName(string left, string right) => string.Equals(Path.GetFileName(left), Path.GetFileName(right), StringComparison.OrdinalIgnoreCase);

    public static IDisposable Gate()
    {
        var mutex = new Mutex(false, @"Global\RooIndustriesGovernorGate-" + OperationOwner.Current().UserSid);
        try
        {
            try { if (!mutex.WaitOne(TimeSpan.FromSeconds(30))) throw new TimeoutException("Another rule or game session change is still running. Try again in a moment."); }
            catch (AbandonedMutexException) { }
        }
        catch { mutex.Dispose(); throw; }
        return new GateLease(mutex);
    }

    private sealed class GateLease(Mutex mutex) : IDisposable
    {
        private bool _released;
        public void Dispose()
        {
            if (_released) return;
            _released = true;
            mutex.ReleaseMutex();
            mutex.Dispose();
        }
    }

    public void Save(SavedProcessRule rule, string? repoRoot = null)
    {
        Secure();
        using var rootLease = PolicyRootLease.Acquire(Root);
#if GOVERNOR_TEST_HOOKS
        if (int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_SAVE_PAUSE_MS"), out var pause) && pause > 0) Thread.Sleep(Math.Min(pause, 10000));
#endif
        using var lease = LockRules();
#if GOVERNOR_TEST_HOOKS
        if (int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_LOCKED_PAUSE_MS"), out var held) && held > 0) Thread.Sleep(Math.Min(held, 10000));
#endif
        rule = rule with { Revision = Guid.NewGuid().ToString("N") };
        Validate(rule);
        using var gate = rule.Enabled ? Gate() : null;
        if (rule.Enabled)
        {
            RequireNoGameSession(rule);
            GovernorClaims.RequireUnclaimed(rule, Path.GetDirectoryName(Root)!, repoRoot);
        }
        foreach (var existing in (rule.Enabled ? ReadRules(rule.RuleId) : []).Select(pair => pair.Rule).Where(existing => existing.Enabled))
        {
            var overlaps = SameFileName(existing.ExecutablePath, rule.ExecutablePath) &&
                (existing.MatchMode == "filename" || rule.MatchMode == "filename" || string.Equals(existing.ExecutablePath, rule.ExecutablePath, StringComparison.OrdinalIgnoreCase));
            if (overlaps && (existing.Controls.Keys.Intersect(rule.Controls.Keys).Any() || (existing.CpuSelection is not null && rule.CpuSelection is not null)))
                throw new InvalidDataException("Another enabled rule already owns a matching process control. Edit that rule or disable it first.");
        }
        if (rootLease.Moved) throw new UnauthorizedAccessException("The saved rules folder moved while it was changed.");
        OperationFiles.Write(Path.Combine(RulesDirectory, rule.RuleId + ".json"), rule);
    }

    private FileStream LockRules()
    {
        var clock = Stopwatch.StartNew();
        for (var denied = 0; ; Thread.Sleep(100))
        {
            try { return OperationFiles.Lock(Path.Combine(Root, "rules-write")); }
            catch (IOException error) when (error.HResult is SharingViolation or LockViolation)
            {
                if (clock.Elapsed > RulesLockWait) throw new IOException("Another rule change is still running. Try again in a moment.", error);
                denied = 0;
            }
            catch (UnauthorizedAccessException) when (++denied < 5) { }
        }
    }

    private void RequireNoGameSession(SavedProcessRule rule)
    {
        var operations = Path.Combine(Path.GetDirectoryName(Root)!, "operations");
        if (!Directory.Exists(operations)) return;
        var fields = Fields(rule).ToHashSet(StringComparer.Ordinal);
        foreach (var directory in Directory.EnumerateDirectories(operations, "game-session-*"))
        {
            var session = Path.Combine(directory, "session");
            if (!File.Exists(Path.Combine(session, "session.json"))) continue;
            ProtectedSessionPreview preview;
            try
            {
                var status = new ProtectedSessions(_ => false).Status(session);
                if (status.State is not { } state || status.HostRunning == false && state.Status is "stopped" or "stoppedWithErrors") continue;
                preview = state.Preview;
            }
            catch (Exception error)
            {
                ProtectedSessionPreview? reviewed = null;
                try { reviewed = OperationFiles.Read<ProtectedSessionPreview>(Path.Combine(session, "reviewed-preview.json")); }
                catch (Exception) { }
                if (reviewed is null || Shared(rule, fields, reviewed).Length == 0)
                {
                    GovernorLog.Write(Root, "Skipped a game session that could not be read while checking the rule " + rule.Name + ": " + directory + " (" + error.Message + ")");
                    continue;
                }
                throw new InvalidOperationException("A game session for " + Path.GetFileName(reviewed.GamePath) + " could not be read (" + error.Message + "). Open Games and stop or recover it before saving this rule.", error);
            }
            var shared = Shared(rule, fields, preview);
            if (shared.Length > 0)
                throw new InvalidOperationException("A game session for " + Path.GetFileName(preview.GamePath) + " already controls " + string.Join(", ", shared) +
                    ". Stop that game session first, or save this rule without those settings.");
        }
    }

    private static string[] Shared(SavedProcessRule rule, HashSet<string> fields, ProtectedSessionPreview preview) => preview.Controls.Keys.Where(fields.Contains).Where(field =>
        Matches(rule, preview.Launcher.ExecutablePath) || (LaunchFields.Contains(field) ? SameFileName(rule.ExecutablePath, preview.GamePath) : Matches(rule, preview.GamePath)))
        .Order(StringComparer.Ordinal).ToArray();

    public void Delete(string ruleId)
    {
        Secure();
        using var rootLease = PolicyRootLease.Acquire(Root);
        using var lease = LockRules();
        if (!Guid.TryParseExact(ruleId, "N", out _)) throw new InvalidDataException("Invalid process rule ID.");
        if (rootLease.Moved) throw new UnauthorizedAccessException("The saved rules folder moved while it was changed.");
        File.Delete(Path.Combine(RulesDirectory, ruleId + ".json"));
    }

    public (SavedProcessRule Rule, string Hash)[] ReadRules(string? exceptRuleId = null, List<string>? unreadable = null)
    {
        if (!Directory.Exists(RulesDirectory)) return [];
        var found = new List<(SavedProcessRule Rule, string Hash)>();
        foreach (var path in Directory.GetFiles(RulesDirectory, "*.json").Where(path => Path.GetFileNameWithoutExtension(path) != exceptRuleId).Order(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var (rule, hash) = OperationFiles.ReadHashed<SavedProcessRule>(path);
                Validate(rule);
                if (Path.GetFileNameWithoutExtension(path) != rule.RuleId) throw new InvalidDataException("Process rule filename and identity disagree.");
                found.Add((rule, hash));
            }
            catch (Exception error)
            {
                var named = "The saved rule " + Path.GetFileName(path) + " could not be read: " + error.Message;
                if (unreadable is not null) unreadable.Add(named);
                else if (error is IOException or UnauthorizedAccessException) throw new InvalidDataException(named, error);
                else GovernorLog.Write(Root, "Skipped a damaged saved rule while reading the saved rules. " + named);
            }
        }
        return found.ToArray();
    }

    public PolicyWorkerStatus Status()
    {
        if (!File.Exists(StatePath)) return new(null, false, null);
        var state = OperationFiles.Read<PolicyHostState>(StatePath);
        state.Owner.Verify();
        if (state.SchemaVersion != 1) throw new InvalidDataException("Unsupported policy-host state version.");
        if (state.Host is null) return new(state, false, null);
        try
        {
            using var host = new ProcessTarget(state.Host.ProcessId);
            var identity = host.Identity();
            if (identity.CreationTimeFileTimeUtc != state.Host.CreationTimeFileTimeUtc) return new(state, false, "The previous worker has exited.");
            state.Host.Verify(identity);
            if (host.UserSid() != state.Owner.UserSid) throw new InvalidDataException("The worker belongs to another Windows user.");
            return new(state, true, Stale(state));
        }
        catch (ProcessEndedException) { return new(state, false, "The previous worker has exited."); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { return new(state, false, "The previous worker has exited."); }
        catch (Exception error) { return Exited(state.Host) ? new(state, false, "The previous worker has exited.") : new(state, null, error.Message); }
    }

    private string? Stale(PolicyHostState state)
    {
        PolicyHeartbeat? beat = null;
        try { if (File.Exists(HeartbeatPath)) beat = OperationFiles.Read<PolicyHeartbeat>(HeartbeatPath); }
        catch (Exception) { }
        if (beat is not null && beat.Host == state.Host && beat.BootId == ProcessPolicyHost.BootId())
        {
            var now = ProcessPolicyHost.Monotonic();
            var age = now - beat.Tick;
            var progress = now - beat.ProgressTick;
            if (age >= -ClockSkew && progress >= -ClockSkew)
            {
                if (age > 15000) return "The worker heartbeat is stale; it may be busy or unresponsive.";
                if (progress > 120000) return "The governor has not finished a check for two minutes; it may be stuck.";
                return null;
            }
        }
        return DateTime.UtcNow - state.UpdatedAtUtc > TimeSpan.FromSeconds(15) ? "The worker heartbeat is stale; it may be busy or unresponsive." : null;
    }

    internal static bool Exited(RunningProcess host)
    {
        try
        {
            using var process = Process.GetProcessById(host.ProcessId);
            return process.HasExited || process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture) != host.CreationTimeFileTimeUtc;
        }
        catch (ArgumentException) { return true; }
        catch (InvalidOperationException) { return true; }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    public bool RequestStop()
    {
        var status = Status();
        if (status.HostRunning is null) throw new InvalidOperationException(status.Error);
        if (status.HostRunning == false) return false;
        OperationFiles.Write(StopPath, new PolicyStopRequest(OperationOwner.Current(), status.State!.Host!));
        return true;
    }

    private static void Validate(SavedProcessRule rule)
    {
        rule.Owner.Verify();
        if (rule.SchemaVersion != 1 || !Guid.TryParseExact(rule.RuleId, "N", out _) || !Guid.TryParseExact(rule.Revision, "N", out _) || string.IsNullOrWhiteSpace(rule.Name) ||
            rule.MatchMode is not ("path" or "filename") || !Path.IsPathFullyQualified(rule.ExecutablePath) ||
            string.IsNullOrWhiteSpace(Path.GetFileName(rule.ExecutablePath)) || (rule.ExecutableHash is not null && rule.ExecutableHash.Length != 64) ||
            rule.Controls is null || (rule.Controls.Count == 0 && rule.CpuSelection is null))
            throw new InvalidDataException("The saved process rule is incomplete.");
        if (rule.Controls.ContainsKey("cpuSets")) throw new InvalidDataException("Persistent CPU rules must store a semantic selection, not opaque CPU Set IDs.");
        if (rule.Controls.ContainsKey("affinity") && rule.AffinityTopologyHash is not { Length: 64 })
            throw new InvalidDataException("A persistent hard-affinity rule requires a reviewed topology fingerprint.");
        foreach (var pair in rule.Controls)
        {
            ProcessControlEngine.ValidateValue(pair.Key, pair.Value);
            RequireSavable(pair.Key, pair.Value);
        }
        if (rule.CpuSelection is { } selection) ValidateSelection(selection);
    }

    private static void RequireSavable(string name, JsonElement value)
    {
        switch (name)
        {
            case "cpuPriority" when value.GetString() == "Realtime":
                throw new InvalidDataException("Realtime CPU priority can freeze the PC, so saved rules do not allow it. Choose High or lower.");
            case "gpuPriority" when value.GetInt32() == 5:
                throw new InvalidDataException("Realtime GPU priority can freeze the PC, so saved rules do not allow it. Choose High or lower.");
            case "executionQoS":
                var power = value.Deserialize<PowerThrottling>(OperationFiles.Json) ?? throw new InvalidDataException("Missing QoS state.");
                if (((power.ControlMask | power.StateMask) & ~5u) != 0)
                    throw new InvalidDataException("Power mode can only use the documented execution speed and timer resolution bits.");
                break;
        }
    }

    private static void ValidateSelection(CpuSelection selection)
    {
        var processors = selection.Processors ?? [];
        if (selection.Kind == "windowsDefault")
        {
            if (processors.Length > 0 || selection.Group is not null || selection.Index is not null || selection.OneThreadPerCore)
                throw new InvalidDataException("Windows default cannot be combined with a CPU selector.");
            return;
        }
        if (selection.Kind is not ("all" or "logical" or "performance" or "efficiency" or "core" or "cache" or "numa"))
            throw new InvalidDataException("The saved CPU selection is unknown: " + selection.Kind);
        if (selection.TopologyHash is not { Length: 64 }) throw new InvalidDataException("A saved CPU selection needs a reviewed topology fingerprint.");
        if (selection.Kind == "logical")
        {
            if (processors.Length == 0) throw new InvalidDataException("The saved CPU selection chooses no processors.");
            if (processors.Distinct().Count() != processors.Length) throw new InvalidDataException("The saved CPU selection repeats a processor.");
        }
        else if (processors.Length > 0) throw new InvalidDataException("Explicit processors can only be saved with a logical CPU selection.");
        if ((selection.Kind is "core" or "cache" or "numa") ? selection.Group is null || selection.Index is null : selection.Group is not null || selection.Index is not null)
            throw new InvalidDataException("A core, cache or NUMA selection needs a group and an index, and other selections must not set them.");
    }
}

public sealed class ProcessPolicyHost
{
    public const int TerminalHistory = 50;
    public const string KeepsChanging = "This app keeps changing it back, so Roo Industries stepped back.";
    public const string OtherAccount = "Running under another Windows account, so this rule doesn't control it.";
    public const string ForeignRecord = "This record points at a process of another Windows account, so Roo Industries did not change it.";
    public const string TopologyChanged = "CPU topology changed; review the saved hard-affinity selection.";
    public const string PathUnreadable = "Its program path could not be read, so this rule cannot be applied to it.";
    private const long Recheck = 2000, ReassertWindow = 600000, RuleReadGrace = 10000;
    private readonly ProcessPolicyStore _store;
    private readonly ProcessControlEngine _engine;
    private readonly Func<RunningProcess, bool> _excluded;
    private readonly List<string> _pruned = [];
    private readonly Dictionary<string, (DateTime Written, long Length)> _ruleStamps = new(StringComparer.OrdinalIgnoreCase);
    private (SavedProcessRule Rule, string Hash)[]? _ruleSnapshot;
    private long _rulesFailing = -1;
    private readonly Dictionary<string, Watch> _watched = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Retry> _retries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Gate> _gates = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (string Kind, string Message)?> _ruleChecks = new(StringComparer.Ordinal);
    private readonly Dictionary<(string Path, long Length, DateTime Written), string> _hashes = new();
    private readonly Dictionary<string, string[]> _fields = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string?> _imagePaths = new(StringComparer.Ordinal);
    private int _enabledRules = -1, _unreadableRules;
    private long _processOpens, _hashAttempts, _ownerLookups;
    private readonly Dictionary<string, string> _owners = new(StringComparer.Ordinal);
    private long _progress = Monotonic();
    private PolicyDiagnostics? _diagnostics;
    private PolicyHostState _state;
    private byte[]? _lastSavedState;

    private sealed class Watch
    {
        public required Dictionary<string, JsonElement> Desired { get; init; }
        public long NextCheck { get; set; }
        public int Failures { get; set; }
        public List<long> Reasserts { get; } = [];
    }

    private sealed record Retry(string Kind, string Message, string? Field, long RetryAt, int Attempt, string Identity);
    private sealed record Gate(string? Kind, string? Message, RunningProcess? Identity, string? Topology);

    private static long Now => Monotonic();
    private static long Delay(int attempt) => attempt < 7 ? 1000L << attempt : 300000;
    private static bool Terminal(PolicyInstance instance) => instance.Status is "restored" or "expired";
    private static string Key(RunningProcess process) => process.ProcessId + "|" + process.CreationTimeFileTimeUtc;
    private static string Key(SnapshotProcess process) => process.ProcessId + "|" + process.CreationTimeFileTimeUtc;

    public ProcessPolicyHost(ProcessPolicyStore store, Func<RunningProcess, bool> excluded)
    {
        _store = store;
        _excluded = excluded;
        _engine = new(identity => identity.ProcessId == Environment.ProcessId || excluded(identity));
        try { _state = Load(); }
        catch (Exception error)
        {
            GovernorLog.Write(store.Root, "The governor did not start because its saved state could not be used: " + error.Message);
            throw;
        }
    }

    internal static long Monotonic()
    {
        if (!QueryUnbiasedInterruptTime(out var ticks)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var milliseconds = checked((long)(ticks / 10000));
#if GOVERNOR_TEST_HOOKS
        milliseconds -= ClockDiscount(milliseconds);
#endif
        return milliseconds;
    }

#if GOVERNOR_TEST_HOOKS
    private static readonly object DiscountLock = new();
    private static long _discount, _discountRead = -1;
    internal static string? ClockRoot { get; set; }

    private static long ClockDiscount(long raw)
    {
        lock (DiscountLock)
        {
            if (ClockRoot is not { } root) return 0;
            if (_discountRead >= 0 && raw >= _discountRead && raw - _discountRead < 200) return _discount;
            _discountRead = raw;
            try { _discount = long.TryParse(File.ReadAllText(Path.Combine(root, "clock-discount.request")).Trim(), out var value) && value > 0 ? value : 0; }
            catch (FileNotFoundException) { _discount = 0; }
            catch (DirectoryNotFoundException) { _discount = 0; }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return _discount;
        }
    }
#endif

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryUnbiasedInterruptTime(out ulong unbiasedTime);

    public static string? BootId()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters");
            return key?.GetValue("BootId")?.ToString();
        }
        catch (Exception) { return null; }
    }

    private PolicyHostState Load()
    {
        var state = File.Exists(_store.StatePath) ? OperationFiles.Read<PolicyHostState>(_store.StatePath) : new()
        {
            SchemaVersion = 1, Owner = OperationOwner.Current(), Host = null, Status = "stopped", Instances = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow,
        };
        _store.ValidateState(state);
        return state;
    }

    private bool Idle()
    {
        try
        {
            if (_state.Instances.Any(instance => !Terminal(instance))) return false;
            if (_store.Paused()) return true;
            var unreadable = new List<string>();
            return !_store.ReadRules(null, unreadable).Any(pair => pair.Rule.Enabled) && unreadable.Count == 0;
        }
        catch (Exception) { return false; }
    }

    public PolicyHostState Run(CancellationToken cancellationToken, TimeSpan? duration = null, Action? verifyLocked = null)
    {
        if (duration is null && Idle()) return _state;
        using var rootLease = PolicyRootLease.Acquire(_store.Root);
        verifyLocked?.Invoke();
#if GOVERNOR_TEST_HOOKS
        if (duration is not null && int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_RESTORE_RUN_DELAY_MS"), out var delay) && delay > 0) Thread.Sleep(Math.Min(delay, 10000));
#endif
        using var lease = OperationFiles.Lock(Path.Combine(_store.Root, "worker"));
        if (duration is null) SweepHeartbeatTemporaries();
        _state = Load();
        using (var self = new ProcessTarget(Environment.ProcessId)) _state.Host = self.Identity();
        _state.Status = "running";
        var clock = Stopwatch.StartNew();
        var swept = TimeSpan.MinValue;
        var moved = false;
        var failures = 0;
        var host = _state.Host;
        var bootId = BootId();
        using var heartbeat = duration is null ? new Heartbeat(() => WriteHeartbeat(
            new PolicyHeartbeat(host, Now, Interlocked.Read(ref _progress), bootId, DateTime.UtcNow, _diagnostics))) : null;
        try
        {
            try { Save(); } catch (IOException) { }
            while (!cancellationToken.IsCancellationRequested && (duration is null || clock.Elapsed < duration))
            {
                Progress();
                if (rootLease.Moved) { moved = true; break; }
                if (PausedOrUnreadable() || StopRequested()) break;
                var wait = 500;
                try
                {
                    if (swept == TimeSpan.MinValue || clock.Elapsed - swept > TimeSpan.FromMinutes(10)) { SweepOperations(); swept = clock.Elapsed; }
                    Tick();
                    failures = 0;
                }
                catch (Exception error)
                {
                    failures++;
                    wait = (int)Math.Min(16000, 1000L << Math.Min(failures - 1, 4));
                    _state.Errors = ["A governor check failed and will be retried in " + wait / 1000 + " s: " + error.Message];
                    GovernorLog.Write(_store.Root, _state.Errors[0]);
                    try { Save(); } catch (Exception) { }
                }
                if (_enabledRules == 0 && _unreadableRules == 0 && _state.Instances.All(Terminal)) break;
                cancellationToken.WaitHandle.WaitOne(wait);
            }
        }
        finally
        {
            if (!moved && !rootLease.Moved)
            {
                Stop();
                File.Delete(_store.StopPath);
            }
        }
        return _state;
    }

    private void Progress() => Interlocked.Exchange(ref _progress, Now);

    private void WriteHeartbeat(PolicyHeartbeat beat)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(beat, OperationFiles.Json);
        using var file = new FileStream(_store.HeartbeatPath, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 0);
        var length = (int)Math.Max(json.Length, Math.Min(file.Length, 4096));
        var bytes = new byte[length];
        Array.Fill(bytes, (byte)' ');
        json.CopyTo(bytes, 0);
        file.Write(bytes);
        if (file.Length > length) file.SetLength(length);
    }

    private void SweepHeartbeatTemporaries()
    {
        const string prefix = "heartbeat.json.", suffix = ".tmp";
        try
        {
            foreach (var path in Directory.EnumerateFiles(_store.Root, prefix + "*" + suffix).ToArray())
            {
                var name = Path.GetFileName(path);
                if (name.Length <= prefix.Length + suffix.Length || !Guid.TryParseExact(name[prefix.Length..^suffix.Length], "N", out _)) continue;
                try
                {
                    var file = new FileInfo(path);
                    if (!file.Attributes.HasFlag(FileAttributes.ReparsePoint) && DateTime.UtcNow - file.LastWriteTimeUtc > TimeSpan.FromMinutes(1)) file.Delete();
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private bool PausedOrUnreadable()
    {
        try { return _store.Paused(); }
        catch (Exception error) { _state.Errors = ["Governor settings could not be read: " + error.Message]; return true; }
    }

    private bool StopRequested()
    {
        if (!File.Exists(_store.StopPath)) return false;
        var request = OperationFiles.Read<PolicyStopRequest>(_store.StopPath);
        request.Owner.Verify();
        return request.Host == _state.Host;
    }

    public PolicyHostState Tick()
    {
        Progress();
        _state.Errors = [];
        _state.Issues = [];
        (SavedProcessRule Rule, string Hash)[] rules;
        var unreadable = new List<string>();
        try { rules = ReadRules(unreadable); }
        catch (Exception error)
        {
            if (_rulesFailing < 0) _rulesFailing = Now;
            _state.Errors.Add("Saved rules could not be read: " + error.Message);
            if (Now - _rulesFailing < RuleReadGrace)
            {
                Save();
                return _state;
            }
            var snapshot = ProcessSnapshot.Take();
            foreach (var instance in _state.Instances.Where(instance => !Terminal(instance)).ToList())
                if (Due("restore|" + instance.JournalPath, Key(instance.Process))) Restore(instance, snapshot);
            _state.Status = "configurationError";
            Save();
            return _state;
        }
        _unreadableRules = unreadable.Count;
        if (unreadable.Count == 0) _rulesFailing = -1;
        else
        {
            if (_rulesFailing < 0) _rulesFailing = Now;
            _state.Errors.AddRange(unreadable);
            if (Now - _rulesFailing < RuleReadGrace)
            {
                Save();
                return _state;
            }
        }
#if GOVERNOR_TEST_HOOKS
        var tickPause = Path.Combine(_store.Root, "tick-pause.request");
        if (File.Exists(tickPause) && int.TryParse(File.ReadAllText(tickPause), out var pause) && pause > 0)
        {
            File.Delete(tickPause);
            Thread.Sleep(Math.Min(pause, 60000));
        }
#endif
        var enabled = rules.Where(pair => pair.Rule.Enabled).ToArray();
        var processes = ProcessSnapshot.Take();
        Maintain(enabled, processes);
        CaptureRecords(enabled, processes);
        Forget(processes);
        _enabledRules = enabled.Length;
        _state.Status = "running";
        _diagnostics = new(_state.Instances.Count, _watched.Count, _retries.Count, _gates.Count, _ruleChecks.Count, _hashes.Count, _processOpens, _hashAttempts, _ownerLookups);
        Save();
        return _state;
    }

    private void Maintain((SavedProcessRule Rule, string Hash)[] enabled, Dictionary<int, SnapshotProcess> processes)
    {
        var watched = new List<(PolicyInstance Instance, SnapshotProcess Process)>();
        foreach (var instance in _state.Instances.Where(instance => !Terminal(instance)).ToList())
        {
            Progress();
            if (!processes.TryGetValue(instance.Process.ProcessId, out var running) || running.CreationTimeFileTimeUtc != instance.Process.CreationTimeFileTimeUtc)
            {
                if (instance.Status == "applying" && !File.Exists(instance.JournalPath)) Discard(instance);
                else Finish(instance, "expired");
                continue;
            }
            var owner = enabled.FirstOrDefault(pair => pair.Rule.RuleId == instance.RuleId && pair.Hash == instance.RuleHash).Rule;
            if (owner is not null && instance.Status == "conflict" && instance.ErrorKind == "keepsChanging") continue;
            if (owner is null || instance.Status == "conflict")
            {
                if (Due("restore|" + instance.JournalPath, Key(running))) Restore(instance, processes);
                continue;
            }
            watched.Add((instance, running));
        }
        foreach (var group in watched.GroupBy(pair => Key(pair.Process)))
            Enforce(group.Select(pair => pair.Instance).ToList(), group.First().Process);
    }

    private void Enforce(List<PolicyInstance> instances, SnapshotProcess running)
    {
        var gate = GetGate(running);
        if (gate.Kind == "ended") return;
        if (gate.Kind is "otherAccount" or "excluded" or "protected")
        {
            foreach (var instance in instances) { instance.Status = "conflict"; instance.ErrorKind = "error"; instance.Error = gate.Kind == "otherAccount" ? ForeignRecord : gate.Message; }
            return;
        }
        if (gate.Kind is not null)
        {
            foreach (var instance in instances) { instance.ErrorKind = gate.Kind; instance.Error = gate.Message; }
            return;
        }
        if (!string.Equals(gate.Identity!.ExecutablePath, instances[0].Process.ExecutablePath, StringComparison.OrdinalIgnoreCase))
        {
            foreach (var instance in instances) { instance.Status = "conflict"; instance.ErrorKind = "error"; instance.Error = "The process no longer matches its saved record."; }
            return;
        }
        foreach (var instance in instances.Where(instance => instance.Status == "applying" || !_watched.ContainsKey(instance.JournalPath)).ToList())
            if (Due("reconcile|" + instance.JournalPath, Key(running))) Reconcile(instance);
        var due = instances.Where(instance => instance.Status == "active" && _watched.TryGetValue(instance.JournalPath, out var watch) && Now >= watch.NextCheck).ToList();
        foreach (var part in due.GroupBy(instance => _watched[instance.JournalPath].Desired.ContainsKey("gpuPriority")))
            Observe(part.ToList(), running);
    }

    private void Observe(List<PolicyInstance> instances, SnapshotProcess running)
    {
        var fields = instances.SelectMany(instance => _watched[instance.JournalPath].Desired.Keys).Distinct().ToArray();
        var changed = new List<PolicyInstance>();
        try
        {
            _processOpens++;
            using var target = new ProcessTarget(running.ProcessId, readControls: fields);
            if (target.Identity().CreationTimeFileTimeUtc != running.CreationTimeFileTimeUtc)
            {
                foreach (var instance in instances) Finish(instance, "expired");
                return;
            }
            foreach (var instance in instances)
            {
                var watch = _watched[instance.JournalPath];
                try
                {
                    if (watch.Desired.Any(pair => !ProcessTarget.Equivalent(pair.Key, target.Read(pair.Key).Require(), pair.Value))) changed.Add(instance);
                    else
                    {
                        watch.Failures = 0;
                        instance.ErrorKind = null;
                        instance.Error = null;
                        watch.NextCheck = Now + Recheck;
                    }
                }
                catch (Exception error) when (error is not ProcessEndedException) { Failed(instance, watch, error); }
            }
        }
        catch (ProcessEndedException) { foreach (var instance in instances) Finish(instance, "expired"); return; }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { foreach (var instance in instances) Finish(instance, "expired"); return; }
        catch (Exception error) { foreach (var instance in instances) Failed(instance, _watched[instance.JournalPath], error); return; }
        foreach (var instance in changed) Reassert(instance, running);
    }

    private static void Failed(PolicyInstance instance, Watch watch, Exception error)
    {
        instance.ErrorKind = ProcessFailures.Denied(error) ? "denied" : "error";
        instance.Error = error.Message;
        watch.NextCheck = Now + Delay(watch.Failures);
        watch.Failures++;
    }

    private void Reassert(PolicyInstance instance, SnapshotProcess running)
    {
        var watch = _watched[instance.JournalPath];
        watch.Reasserts.RemoveAll(at => Now - at > ReassertWindow);
        if (watch.Reasserts.Count >= 3)
        {
            instance.Status = "conflict";
            instance.ErrorKind = "keepsChanging";
            instance.Error = KeepsChanging;
            _watched.Remove(instance.JournalPath);
            return;
        }
        try
        {
            var journal = _engine.Reassert(instance.JournalPath, out var wrote);
            if (journal.Status is "restored" or "expired") { Finish(instance, journal.Status); return; }
            if (journal.Status == "applied")
            {
                if (wrote) watch.Reasserts.Add(Now);
                watch.Failures = 0;
                watch.NextCheck = Now + Recheck;
                instance.ErrorKind = null;
                instance.Error = null;
                return;
            }
            if (journal.Changes.Any(change => change.Status is "pending" or "restoreIntent" or "restored")) { Restore(instance); return; }
            var failed = journal.Changes.FirstOrDefault(change => change.Error is not null);
            instance.ErrorKind = failed?.ErrorKind ?? "error";
            instance.Error = failed?.Error ?? "Windows did not accept the requested value.";
            watch.NextCheck = Now + Delay(watch.Failures);
            watch.Failures++;
        }
        catch (InstanceBusyException) { watch.NextCheck = Now; }
        catch (ProcessEndedException) { Finish(instance, "expired"); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { Finish(instance, "expired"); }
        catch (Exception error) { Failed(instance, watch, error); }
    }

    private void Reconcile(PolicyInstance instance)
    {
        try
        {
            if (instance.Status == "applying" && !File.Exists(instance.JournalPath)) { Discard(instance); return; }
            var journal = _engine.Apply(instance.PreviewPath, instance.ReviewHash, instance.JournalPath);
            if (journal.Status is "restored" or "expired") { Finish(instance, journal.Status); return; }
            if (journal.Changes.Any(change => change.Status is "pending" or "restoreIntent" or "restored")) { Restore(instance); return; }
            _watched[instance.JournalPath] = new Watch { Desired = journal.Changes.ToDictionary(change => change.Name, change => change.Desired, StringComparer.Ordinal), NextCheck = Now };
            instance.Status = "active";
            instance.ErrorKind = null;
            instance.Error = null;
            _retries.Remove("reconcile|" + instance.JournalPath);
        }
        catch (InstanceBusyException) { _retries.Remove("reconcile|" + instance.JournalPath); }
        catch (ProcessEndedException) { Finish(instance, "expired"); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { Finish(instance, "expired"); }
        catch (Exception error)
        {
            instance.ErrorKind = ProcessFailures.Denied(error) ? "denied" : "error";
            instance.Error = error.Message;
        }
    }

    private void CaptureRecords((SavedProcessRule Rule, string Hash)[] enabled, Dictionary<int, SnapshotProcess> processes)
    {
        var self = Environment.ProcessId;
        foreach (var (rule, hash) in enabled)
        {
            var image = Path.GetFileName(rule.ExecutablePath);
            foreach (var running in processes.Values.Where(process => process.ProcessId != self && string.Equals(process.ImageName, image, StringComparison.OrdinalIgnoreCase)))
            {
                Progress();
                var gate = GetGate(running);
                if (gate.Kind == "ended") continue;
                var path = gate.Identity?.ExecutablePath ?? ImagePath(running);
                if (rule.MatchMode == "path")
                {
                    if (path is null) { Issue(rule, running, null, "unavailable", PathUnreadable, null); continue; }
                    if (!string.Equals(rule.ExecutablePath, path, StringComparison.OrdinalIgnoreCase)) continue;
                }
                if (gate.Kind is not null) { Issue(rule, running, path, gate.Kind, gate.Message!, null); continue; }
                var identity = gate.Identity!;
                if (RuleProblem(rule, hash, gate) is { } problem) { Issue(rule, running, identity.ExecutablePath, problem.Kind, problem.Message, null); continue; }
                var pending = new List<(string Field, string Key)>();
                foreach (var field in ProcessPolicyStore.Fields(rule))
                {
                    if (Held(identity, field)) continue;
                    if (field == "affinity" && gate.Topology != rule.AffinityTopologyHash) { Issue(rule, running, identity.ExecutablePath, "topology", TopologyChanged, field); continue; }
                    var key = rule.RuleId + "|" + hash + "|" + Key(identity) + "|" + field;
                    if (_retries.TryGetValue(key, out var waiting) && Now < waiting.RetryAt) { Issue(rule, running, identity.ExecutablePath, waiting.Kind, waiting.Message, field); continue; }
                    pending.Add((field, key));
                }
                if (pending.Count > 0) Apply(rule, hash, identity, pending);
            }
        }
    }

    private string? ImagePath(SnapshotProcess running)
    {
        var key = Key(running);
        if (_imagePaths.TryGetValue(key, out var known)) return known;
        var retry = "path|" + key;
        if (_retries.TryGetValue(retry, out var waiting) && Now < waiting.RetryAt) return null;
        var path = ProcessSnapshot.ImagePath(running.ProcessId);
        if (path is null) Fail(retry, "unavailable", PathUnreadable, null, key);
        else
        {
            _imagePaths[key] = path;
            _retries.Remove(retry);
        }
        return path;
    }

    private bool Held(RunningProcess identity, string field) => _state.Instances.Any(instance => !Terminal(instance) &&
        instance.Process.ProcessId == identity.ProcessId && instance.Process.CreationTimeFileTimeUtc == identity.CreationTimeFileTimeUtc && FieldsOf(instance).Contains(field));

    private string[] FieldsOf(PolicyInstance instance)
    {
        if (instance.Field is { } field) return [field];
        if (_fields.TryGetValue(instance.JournalPath, out var known)) return known;
        try { return _fields[instance.JournalPath] = OperationFiles.Read<ProcessControlPreview>(instance.PreviewPath, instance.ReviewHash).Desired.Keys.ToArray(); }
        catch (Exception) { return ProcessTarget.ControlNames; }
    }

    private void Apply(SavedProcessRule rule, string hash, RunningProcess identity, List<(string Field, string Key)> fields)
    {
        var created = new List<(PolicyInstance Instance, string Key)>();
        foreach (var (field, key) in fields)
        {
            try
            {
                var desired = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
                if (field != "cpuSets") desired[field] = rule.Controls[field];
                _processOpens++;
                var preview = _engine.Preview(identity.ProcessId, desired, field == "cpuSets" ? rule.CpuSelection : null);
                identity.Verify(preview.Identity);
                var directory = Path.Combine(_store.Root, "operations", preview.OperationId);
                var previewPath = Path.Combine(directory, "preview.json");
                OperationFiles.Write(previewPath, preview);
                var instance = new PolicyInstance
                {
                    RuleId = rule.RuleId, RuleHash = hash, Process = identity, PreviewPath = previewPath, Field = field,
                    ReviewHash = OperationFiles.HashFile(previewPath), JournalPath = Path.Combine(directory, "journal.json"), Status = "applying",
                };
                _state.Instances.Add(instance);
                created.Add((instance, key));
            }
            catch (ProcessEndedException) { break; }
            catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { break; }
            catch (Exception error) { Rejected(rule, identity, field, key, error); }
        }
        if (created.Count == 0) return;
        try { Save(); }
        catch (Exception error)
        {
            foreach (var (instance, key) in created)
            {
                _state.Instances.Remove(instance);
                _pruned.Add(Path.GetDirectoryName(instance.JournalPath)!);
                Rejected(rule, identity, instance.Field!, key, error);
            }
            return;
        }
        foreach (var (instance, key) in created)
        {
            try
            {
                _processOpens++;
                var applied = _engine.Apply(instance.PreviewPath, instance.ReviewHash, instance.JournalPath);
                if (applied.Status != "applied")
                {
                    var failed = applied.Changes.FirstOrDefault(change => change.Error is not null);
                    Restore(instance);
                    throw new FieldFailure(failed?.Error ?? "Windows did not accept the requested value.", failed?.ErrorKind == "denied");
                }
                instance.Status = "active";
                _watched[instance.JournalPath] = new Watch { Desired = applied.Changes.ToDictionary(change => change.Name, change => change.Desired, StringComparer.Ordinal), NextCheck = Now + Recheck };
                _retries.Remove(key);
            }
            catch (InstanceBusyException) { Discard(instance); }
            catch (ProcessEndedException) { Discard(instance); }
            catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { Discard(instance); }
            catch (Exception error)
            {
                if (instance.Status == "applying") Discard(instance);
                Rejected(rule, identity, instance.Field!, key, error);
            }
        }
    }

    private void Rejected(SavedProcessRule rule, RunningProcess identity, string field, string key, Exception error)
    {
        var kind = error is FieldFailure failure ? (failure.Denied ? "denied" : "error") : ProcessFailures.Denied(error) ? "denied" : "error";
        Fail(key, kind, error.Message, field, Key(identity));
        _state.Issues.Add(new(rule.RuleId, identity.ProcessId, identity.ExecutablePath, error.Message) { Kind = kind, Field = field });
    }

    private sealed class FieldFailure(string message, bool denied) : Exception(message)
    {
        public bool Denied { get; } = denied;
    }

    private (string Kind, string Message)? RuleProblem(SavedProcessRule rule, string hash, Gate gate)
    {
        var key = hash + "|" + Key(gate.Identity!);
        if (_ruleChecks.TryGetValue(key, out var known)) return known;
        var retry = "check|" + key;
        if (_retries.TryGetValue(retry, out var waiting) && Now < waiting.RetryAt) return (waiting.Kind, waiting.Message);
        (string Kind, string Message)? problem = null;
        if (rule.ExecutableHash is not null)
        {
            try
            {
                if (!string.Equals(HashExecutable(gate.Identity!.ExecutablePath), rule.ExecutableHash, StringComparison.OrdinalIgnoreCase))
                    problem = ("exeChanged", "The executable changed and needs review.");
            }
            catch (Exception error)
            {
                Fail(retry, "error", "The program file could not be read to check it: " + error.Message, null, Key(gate.Identity!));
                return ("error", _retries[retry].Message);
            }
        }
        _retries.Remove(retry);
        _ruleChecks[key] = problem;
        return problem;
    }

    private string HashExecutable(string path)
    {
        _hashAttempts++;
        var info = new FileInfo(path);
        var key = (path.ToUpperInvariant(), info.Length, info.LastWriteTimeUtc);
        if (_hashes.TryGetValue(key, out var hash)) return hash;
        if (_hashes.Count >= 64) _hashes.Clear();
        Progress();
        hash = OperationFiles.HashFile(path, Progress);
        Progress();
        return _hashes[key] = hash;
    }

    private Gate GetGate(SnapshotProcess running)
    {
        var key = Key(running);
        if (_gates.TryGetValue(key, out var known)) return known;
        if (_retries.TryGetValue("gate|" + key, out var waiting) && Now < waiting.RetryAt) return new(waiting.Kind, waiting.Message, null, null);
        try
        {
            if (_excluded(new RunningProcess(running.ProcessId, running.CreationTimeFileTimeUtc, running.ImageName)))
                return _gates[key] = new("excluded", "Roo Industries never changes this app because Windows or security software depends on it.", null, null);
            _processOpens++;
            using var target = new ProcessTarget(running.ProcessId);
            var identity = target.Identity();
            if (identity.CreationTimeFileTimeUtc != running.CreationTimeFileTimeUtc) return new("ended", null, null, null);
            if (target.UserSid() != _state.Owner.UserSid) return _gates[key] = new("otherAccount", OtherAccount, identity, null);
            if (_excluded(identity)) return _gates[key] = new("excluded", "Roo Industries never changes this app because Windows or security software depends on it.", identity, null);
            try { target.RequireUnprotected(); }
            catch (InvalidOperationException error) { return _gates[key] = new("protected", error.Message, identity, null); }
            var topology = CpuSelection.Fingerprint(target.Topology());
            _retries.Remove("gate|" + key);
            return _gates[key] = new(null, null, identity, topology);
        }
        catch (ProcessEndedException) { return new("ended", null, null, null); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { return new("ended", null, null, null); }
        catch (Exception error)
        {
            var denied = ProcessFailures.Denied(error);
            if (denied && OwnerSid(running) is { } sid && sid != _state.Owner.UserSid) return _gates[key] = new("otherAccount", OtherAccount, null, null);
            var kind = denied ? "denied" : "error";
            Fail("gate|" + key, kind, error.Message, null, key);
            return new(kind, error.Message, null, null);
        }
    }

    private string? OwnerSid(SnapshotProcess running)
    {
        var key = Key(running);
        if (_owners.TryGetValue(key, out var known)) return known;
        _ownerLookups++;
        var sid = ProcessSnapshot.UserSid(running.ProcessId);
        if (sid is not null) _owners[key] = sid;
        return sid;
    }

    private void Issue(SavedProcessRule rule, SnapshotProcess running, string? path, string kind, string message, string? field) =>
        _state.Issues.Add(new(rule.RuleId, running.ProcessId, path, message) { Kind = kind, Field = field });

    private void Fail(string key, string kind, string message, string? field, string identity)
    {
        var attempt = _retries.TryGetValue(key, out var earlier) ? earlier.Attempt + 1 : 0;
        _retries[key] = new(kind, message, field, Now + Delay(attempt), attempt, identity);
    }

    private bool Due(string key, string identity)
    {
        if (_retries.TryGetValue(key, out var waiting) && Now < waiting.RetryAt) return false;
        Fail(key, "retry", "", null, identity);
        return true;
    }

    private void Forget(Dictionary<int, SnapshotProcess> processes)
    {
        var alive = processes.Values.Select(Key).ToHashSet(StringComparer.Ordinal);
        var journals = _state.Instances.Where(instance => !Terminal(instance)).Select(instance => instance.JournalPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var key in _gates.Keys.Where(key => !alive.Contains(key)).ToArray()) _gates.Remove(key);
        foreach (var key in _imagePaths.Keys.Where(key => !alive.Contains(key)).ToArray()) _imagePaths.Remove(key);
        foreach (var key in _owners.Keys.Where(key => !alive.Contains(key)).ToArray()) _owners.Remove(key);
        foreach (var pair in _retries.Where(pair => !alive.Contains(pair.Value.Identity)).ToArray()) _retries.Remove(pair.Key);
        foreach (var key in _ruleChecks.Keys.Where(key => !alive.Contains(key[(key.IndexOf('|') + 1)..])).ToArray()) _ruleChecks.Remove(key);
        foreach (var key in _watched.Keys.Where(key => !journals.Contains(key)).ToArray()) _watched.Remove(key);
        foreach (var key in _fields.Keys.Where(key => !journals.Contains(key)).ToArray()) _fields.Remove(key);
    }

    public PolicyHostState Stop()
    {
        Dictionary<int, SnapshotProcess>? processes = null;
        try { processes = ProcessSnapshot.Take(); }
        catch (Exception) { }
        foreach (var instance in _state.Instances.Where(instance => !Terminal(instance)).ToList()) Restore(instance, processes);
        _state.Status = _state.Instances.Any(instance => instance.Status == "conflict") ? "stoppedWithConflicts" : "stopped";
        _state.Host = null;
        Save();
        return _state;
    }

    private void Finish(PolicyInstance instance, string status)
    {
        instance.Status = status;
        instance.Error = null;
        instance.ErrorKind = null;
        _watched.Remove(instance.JournalPath);
        _retries.Remove("restore|" + instance.JournalPath);
        _retries.Remove("reconcile|" + instance.JournalPath);
    }

    private void Discard(PolicyInstance instance)
    {
        if (File.Exists(instance.JournalPath)) { Restore(instance); return; }
        _state.Instances.Remove(instance);
        _watched.Remove(instance.JournalPath);
        _pruned.Add(Path.GetDirectoryName(instance.JournalPath)!);
    }

    private (SavedProcessRule Rule, string Hash)[] ReadRules(List<string> unreadable)
    {
        var files = Directory.Exists(_store.RulesDirectory) ? new DirectoryInfo(_store.RulesDirectory).GetFiles("*.json") : [];
        if (_ruleSnapshot is not null && files.Length == _ruleStamps.Count &&
            files.All(file => _ruleStamps.TryGetValue(file.FullName, out var stamp) && stamp == (file.LastWriteTimeUtc, file.Length))) return _ruleSnapshot;
        _ruleSnapshot = null;
        _ruleStamps.Clear();
        var rules = _store.ReadRules(null, unreadable);
        if (unreadable.Count > 0) return rules;
        foreach (var file in files) _ruleStamps[file.FullName] = (file.LastWriteTimeUtc, file.Length);
        _ruleSnapshot = rules;
        return rules;
    }

    private void Restore(PolicyInstance instance, Dictionary<int, SnapshotProcess>? processes = null)
    {
        try
        {
            if (!File.Exists(instance.JournalPath) && instance.Status == "applying") { Finish(instance, "restored"); return; }
            if (!File.Exists(instance.JournalPath)) throw new InvalidDataException("The recovery journal is missing; restoration cannot be confirmed.");
            processes ??= ProcessSnapshot.Take();
            if (!processes.TryGetValue(instance.Process.ProcessId, out var running) || running.CreationTimeFileTimeUtc != instance.Process.CreationTimeFileTimeUtc)
            {
                Finish(instance, "expired");
                return;
            }
            if (GetGate(running).Kind == "otherAccount")
            {
                instance.Status = "conflict";
                instance.ErrorKind = "error";
                instance.Error = ForeignRecord;
                return;
            }
            ProcessControlJournal restored;
            for (var attempt = 0; ; attempt++)
            {
                try { restored = _engine.Restore(instance.JournalPath, overwrite: true); break; }
                catch (InstanceBusyException) when (attempt < 10) { Thread.Sleep(200); }
            }
            if (restored.Status is "restored" or "expired") { Finish(instance, restored.Status); return; }
            var failed = restored.Changes.FirstOrDefault(change => change.Error is not null);
            instance.Status = "conflict";
            instance.ErrorKind = failed?.ErrorKind ?? "error";
            instance.Error = failed?.Error;
        }
        catch (Exception error)
        {
            if (ProcessPolicyStore.Exited(instance.Process)) { Finish(instance, "expired"); return; }
            instance.Status = "conflict";
            instance.ErrorKind = ProcessFailures.Denied(error) ? "denied" : "error";
            instance.Error = error.Message;
        }
    }

    private void Prune()
    {
        var terminal = _state.Instances.Where(Terminal).ToList();
        foreach (var old in terminal.Take(Math.Max(0, terminal.Count - TerminalHistory)))
        {
            _state.Instances.Remove(old);
            _pruned.Add(Path.GetDirectoryName(old.JournalPath)!);
        }
    }

    private void SweepOperations()
    {
        var operations = Path.Combine(_store.Root, "operations");
        if (!Directory.Exists(operations)) return;
        var referenced = _state.Instances.Select(instance => Path.GetFullPath(Path.GetDirectoryName(instance.JournalPath)!)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in Directory.GetDirectories(operations))
            if (!referenced.Contains(Path.GetFullPath(directory)) && DateTime.UtcNow - Directory.GetLastWriteTimeUtc(directory) > TimeSpan.FromMinutes(10)) DeleteOperation(directory);
    }

    private void DeleteOperation(string directory)
    {
        var operations = Path.GetFullPath(Path.Combine(_store.Root, "operations")) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(directory);
        if (!full.StartsWith(operations, StringComparison.OrdinalIgnoreCase) || full.Length <= operations.Length) return;
        try { if (Directory.Exists(full)) Directory.Delete(full, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void Save()
    {
        Prune();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(_state, OperationFiles.Json);
        if (_lastSavedState is not null && bytes.AsSpan().SequenceEqual(_lastSavedState)) return;
        _state.UpdatedAtUtc = DateTime.UtcNow;
        OperationFiles.Write(_store.StatePath, _state);
        _lastSavedState = JsonSerializer.SerializeToUtf8Bytes(_state, OperationFiles.Json);
        foreach (var directory in _pruned) DeleteOperation(directory);
        _pruned.Clear();
    }

    private sealed class Heartbeat : IDisposable
    {
        private readonly ManualResetEventSlim _stop = new();
        private readonly Thread _thread;

        public Heartbeat(Action beat)
        {
            _thread = new Thread(() =>
            {
                do
                {
                    try { beat(); }
                    catch (Exception) { }
                }
                while (!_stop.Wait(3000));
            }) { IsBackground = true, Name = "Roo Industries Governor heartbeat" };
            _thread.Start();
        }

        public void Dispose()
        {
            _stop.Set();
            if (_thread.Join(5000)) _stop.Dispose();
        }
    }
}
