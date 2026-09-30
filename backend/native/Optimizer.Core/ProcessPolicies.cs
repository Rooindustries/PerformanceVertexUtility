#nullable enable
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

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

public sealed record PolicyIssue(string RuleId, int? ProcessId, string? ExecutablePath, string Message);
public sealed record PolicyWorkerStatus(PolicyHostState? State, bool? HostRunning, string? Error);
public sealed record PolicyStopRequest(OperationOwner Owner, RunningProcess Host);
public sealed record GovernorSettings([property: JsonRequired] int SchemaVersion, [property: JsonRequired] bool Paused);
public sealed record PolicySummary(bool Secured, string? SecurityProblem, bool Paused, int Rules, int EnabledRules, string? RulesError);

public sealed class ProcessPolicyStore
{
    public string Root { get; }
    public string RulesDirectory => Path.Combine(Root, "rules");
    public string StatePath => Path.Combine(Root, "host.json");
    public string StopPath => Path.Combine(Root, "stop.request");
    public string SettingsPath => Path.Combine(Root, "governor.json");

    public ProcessPolicyStore(string root) => Root = Path.GetFullPath(root);

    public static string DefaultRoot => Path.Combine(BrandCompatibility.LocalDataRoot, "process-rules");

    public bool Secure() => PolicyRootSecurity.Secure(Root);

    public bool Paused()
    {
        if (!File.Exists(SettingsPath)) return false;
        var settings = OperationFiles.Read<GovernorSettings>(SettingsPath);
        if (settings.SchemaVersion != 1) throw new InvalidDataException("Unsupported governor settings version.");
        return settings.Paused;
    }

    public void SetPaused(bool paused)
    {
        PolicyRootSecurity.Secure(Root);
        using var lease = OperationFiles.Lock(Path.Combine(Root, "rules-write"));
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
        try { paused = Paused(); rules = ReadRules(); }
        catch (Exception error) { rulesError = error.Message; }
        return new(problem is null, problem, paused, rules.Length, rules.Count(pair => pair.Rule.Enabled), rulesError);
    }

    public string[] OwnedControls(string executablePath)
    {
        if (!Directory.Exists(Root) || Paused()) return [];
        var owned = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var (rule, _) in ReadRules().Where(pair => pair.Rule.Enabled && Matches(pair.Rule, executablePath)))
        {
            owned.UnionWith(rule.Controls.Keys);
            if (rule.CpuSelection is not null) owned.Add("cpuSets");
        }
        return owned.ToArray();
    }

    public string[] OwnedControls(RunningProcess identity)
    {
        if (!Directory.Exists(Root) || Paused()) return [];
        var owned = new SortedSet<string>(OwnedControls(identity.ExecutablePath), StringComparer.Ordinal);
        if (File.Exists(StatePath))
            foreach (var instance in OperationFiles.Read<PolicyHostState>(StatePath).Instances.Where(instance => instance.Status is "applying" or "active" &&
                instance.Process.ProcessId == identity.ProcessId && instance.Process.CreationTimeFileTimeUtc == identity.CreationTimeFileTimeUtc))
                owned.UnionWith(OperationFiles.Read<ProcessControlPreview>(OperationPath(instance.PreviewPath, "preview.json")).Desired.Keys);
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
        }
    }

    public void RequireUnowned(RunningProcess identity, IEnumerable<string> controls) => Refuse(OwnedControls(identity).Intersect(controls).ToArray());

    public void RequireUnowned(string executablePath, IEnumerable<string> controls) => Refuse(OwnedControls(executablePath).Intersect(controls).ToArray());

    private static void Refuse(string[] owned)
    {
        if (owned.Length > 0)
            throw new InvalidOperationException("Managed by the governor: " + string.Join(", ", owned) + ". Pause the governor or change its rule for this app first.");
    }

    public static bool Matches(SavedProcessRule rule, string executablePath) => rule.MatchMode == "filename"
        ? string.Equals(Path.GetFileName(rule.ExecutablePath), Path.GetFileName(executablePath), StringComparison.OrdinalIgnoreCase)
        : string.Equals(rule.ExecutablePath, executablePath, StringComparison.OrdinalIgnoreCase);

    public void Save(SavedProcessRule rule)
    {
        PolicyRootSecurity.Secure(Root);
        using var lease = OperationFiles.Lock(Path.Combine(Root, "rules-write"));
        rule = rule with { Revision = Guid.NewGuid().ToString("N") };
        Validate(rule);
        foreach (var existing in ReadRules(rule.RuleId).Select(pair => pair.Rule).Where(existing => existing.Enabled && rule.Enabled))
        {
            var overlaps = string.Equals(Path.GetFileName(existing.ExecutablePath), Path.GetFileName(rule.ExecutablePath), StringComparison.OrdinalIgnoreCase) &&
                (existing.MatchMode == "filename" || rule.MatchMode == "filename" || string.Equals(existing.ExecutablePath, rule.ExecutablePath, StringComparison.OrdinalIgnoreCase));
            if (overlaps && (existing.Controls.Keys.Intersect(rule.Controls.Keys).Any() || (existing.CpuSelection is not null && rule.CpuSelection is not null)))
                throw new InvalidDataException("Another enabled rule already owns a matching process control. Edit that rule or disable it first.");
        }
        OperationFiles.Write(Path.Combine(RulesDirectory, rule.RuleId + ".json"), rule);
    }

    public void Delete(string ruleId)
    {
        PolicyRootSecurity.Secure(Root);
        using var lease = OperationFiles.Lock(Path.Combine(Root, "rules-write"));
        if (!Guid.TryParseExact(ruleId, "N", out _)) throw new InvalidDataException("Invalid process rule ID.");
        var path = Path.Combine(RulesDirectory, ruleId + ".json");
        File.Delete(path);
    }

    public (SavedProcessRule Rule, string Hash)[] ReadRules(string? exceptRuleId = null)
    {
        if (!Directory.Exists(RulesDirectory)) return [];
        return Directory.GetFiles(RulesDirectory, "*.json").Where(path => Path.GetFileNameWithoutExtension(path) != exceptRuleId).Order(StringComparer.OrdinalIgnoreCase).Select(path =>
        {
            var hash = OperationFiles.HashFile(path);
            var rule = OperationFiles.Read<SavedProcessRule>(path, hash);
            Validate(rule);
            if (Path.GetFileNameWithoutExtension(path) != rule.RuleId) throw new InvalidDataException("Process rule filename and identity disagree.");
            return (rule, hash);
        }).ToArray();
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
            return new(state, true, DateTime.UtcNow - state.UpdatedAtUtc > TimeSpan.FromSeconds(15) ? "The worker heartbeat is stale; it may be busy or unresponsive." : null);
        }
        catch (ProcessEndedException) { return new(state, false, "The previous worker has exited."); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { return new(state, false, "The previous worker has exited."); }
        catch (Exception error) { return new(state, null, error.Message); }
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
        foreach (var pair in rule.Controls) ProcessControlEngine.ValidateValue(pair.Key, pair.Value);
    }
}

public sealed class ProcessPolicyHost
{
    public const int TerminalHistory = 50;
    private readonly ProcessPolicyStore _store;
    private readonly ProcessControlEngine _engine;
    private readonly Dictionary<string, DateTime> _restoreAttempts = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, (string Message, DateTime Retry, TimeSpan Delay)> _unavailable = new(StringComparer.Ordinal);
    private readonly List<string> _pruned = [];
    private int _enabledRules = -1;
    private readonly Dictionary<string, (DateTime Written, long Length)> _ruleStamps = new(StringComparer.OrdinalIgnoreCase);
    private (SavedProcessRule Rule, string Hash)[]? _ruleSnapshot;
    private readonly Dictionary<string, DateTime> _checked = new(StringComparer.OrdinalIgnoreCase);
    private TimeSpan _recheck = TimeSpan.Zero;
    private PolicyHostState _state;
    private byte[]? _lastSavedState;

    public ProcessPolicyHost(ProcessPolicyStore store, Func<RunningProcess, bool> excluded)
    {
        _store = store;
        _engine = new(identity => identity.ProcessId == Environment.ProcessId || excluded(identity));
        _state = Load();
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

    public PolicyHostState Run(CancellationToken cancellationToken, TimeSpan? duration = null, Action? verifyLocked = null)
    {
        using var rootLease = PolicyRootLease.Acquire(_store.Root);
        verifyLocked?.Invoke();
        using var lease = OperationFiles.Lock(Path.Combine(_store.Root, "worker"));
        _state = Load();
        using (var self = new ProcessTarget(Environment.ProcessId)) _state.Host = self.Identity();
        _state.Status = "running";
        var clock = Stopwatch.StartNew();
        var swept = TimeSpan.MinValue;
        var moved = false;
        _recheck = TimeSpan.FromSeconds(2);
        try
        {
            Save();
            while (!cancellationToken.IsCancellationRequested && (duration is null || clock.Elapsed < duration))
            {
                if (rootLease.Moved) { moved = true; break; }
                if (PausedOrUnreadable() || StopRequested()) break;
                if (swept == TimeSpan.MinValue || clock.Elapsed - swept > TimeSpan.FromMinutes(10)) { SweepOperations(); swept = clock.Elapsed; }
                Tick();
                if (_enabledRules == 0 && _state.Instances.All(instance => instance.Status is "restored" or "expired")) break;
                cancellationToken.WaitHandle.WaitOne(500);
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
        _state.Errors = [];
        _state.Issues = [];
        (SavedProcessRule Rule, string Hash)[] rules;
        try { rules = ReadRules(); }
        catch (Exception error)
        {
            _state.Errors.Add("Saved rules could not be read: " + error.Message);
            foreach (var instance in _state.Instances.Where(instance => instance.Status is not ("restored" or "expired"))) Restore(instance);
            _state.Status = "configurationError";
            Save();
            return _state;
        }
        var enabledRules = rules.Where(pair => pair.Rule.Enabled).ToArray();
        var processes = ProcessNames.Find(enabledRules.Select(pair => Path.GetFileNameWithoutExtension(pair.Rule.ExecutablePath)));
        foreach (var instance in _state.Instances.Where(instance => instance.Status is not ("restored" or "expired")).ToList())
        {
            var owner = enabledRules.FirstOrDefault(pair => pair.Rule.RuleId == instance.RuleId && pair.Hash == instance.RuleHash).Rule;
            if (owner is null)
            {
                if (instance.Status != "conflict" || RestoreDue(instance)) Restore(instance);
                continue;
            }
            if (instance.Status == "conflict")
            {
                if (!processes[Path.GetFileNameWithoutExtension(owner.ExecutablePath)].Contains(instance.Process.ProcessId) || !Alive(instance.Process)) Restore(instance);
                continue;
            }
            if (instance.Status == "active" && _checked.TryGetValue(instance.JournalPath, out var checkedAt) && DateTime.UtcNow - checkedAt < _recheck) continue;
            _checked[instance.JournalPath] = DateTime.UtcNow;
            try
            {
                using var process = new ProcessTarget(instance.Process.ProcessId);
                if (process.UserSid() != _state.Owner.UserSid) throw new InvalidOperationException("The process belongs to another Windows user.");
                var identity = process.Identity();
                if (identity.CreationTimeFileTimeUtc != instance.Process.CreationTimeFileTimeUtc) { instance.Status = "expired"; continue; }
                instance.Process.Verify(identity);
                if (instance.Status == "applying" && !File.Exists(instance.JournalPath)) { Discard(instance); continue; }
                var result = _engine.Apply(instance.PreviewPath, instance.ReviewHash, instance.JournalPath);
                instance.Status = result.Status == "applied" ? "active" : "conflict";
                instance.Error = result.Changes.FirstOrDefault(change => change.Error is not null)?.Error;
                if (result.Changes.Any(change => change.Status is "restoreIntent" or "restored")) Restore(instance);
            }
            catch (ProcessEndedException) { instance.Status = "expired"; }
            catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { instance.Status = "expired"; }
            catch (Exception error) { instance.Status = "conflict"; instance.Error = error.Message; }
        }

        var live = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (rule, hash) in enabledRules)
        {
            foreach (var processId in processes[Path.GetFileNameWithoutExtension(rule.ExecutablePath)])
            {
                if (processId == Environment.ProcessId) continue;
                RunningProcess? identity = null;
                var key = rule.RuleId + "|" + hash + "|" + processId;
                live.Add(key);
                if (_unavailable.TryGetValue(key, out var opening) && DateTime.UtcNow < opening.Retry) { _state.Issues.Add(new(rule.RuleId, processId, null, opening.Message)); continue; }
                PolicyInstance? created = null;
                try
                {
                    using (var target = new ProcessTarget(processId))
                    {
                        if (target.UserSid() != rule.Owner.UserSid) continue;
                        identity = target.Identity();
                        key += "|" + identity.CreationTimeFileTimeUtc;
                        live.Add(key);
                        if (_unavailable.TryGetValue(key, out var known) && DateTime.UtcNow < known.Retry) { _state.Issues.Add(new(rule.RuleId, processId, identity.ExecutablePath, known.Message)); continue; }
                        if (rule.Controls.ContainsKey("affinity") && CpuSelection.Fingerprint(target.Topology()) != rule.AffinityTopologyHash)
                            throw new InvalidDataException("CPU topology changed; review the saved hard-affinity selection.");
                    }
                    if (rule.MatchMode == "path" && !string.Equals(rule.ExecutablePath, identity.ExecutablePath, StringComparison.OrdinalIgnoreCase)) continue;
                    if (_state.Instances.Any(instance => instance.RuleId == rule.RuleId && instance.RuleHash == hash && instance.Process == identity && instance.Status is not ("restored" or "expired"))) continue;
                    if (rule.ExecutableHash is not null && !string.Equals(OperationFiles.HashFile(identity.ExecutablePath), rule.ExecutableHash, StringComparison.OrdinalIgnoreCase))
                    {
                        _unavailable[key] = ("The executable changed and needs review.", DateTime.MaxValue, TimeSpan.MaxValue);
                        throw new InvalidDataException("The executable changed and needs review.");
                    }
                    var preview = _engine.Preview(identity.ProcessId, rule.Controls, rule.CpuSelection);
                    identity.Verify(preview.Identity);
                    var directory = Path.Combine(_store.Root, "operations", preview.OperationId);
                    var previewPath = Path.Combine(directory, "preview.json");
                    OperationFiles.Write(previewPath, preview);
                    var instance = new PolicyInstance
                    {
                        RuleId = rule.RuleId, RuleHash = hash, Process = identity, PreviewPath = previewPath,
                        ReviewHash = OperationFiles.HashFile(previewPath), JournalPath = Path.Combine(directory, "journal.json"), Status = "applying",
                    };
                    _state.Instances.Add(instance);
                    created = instance;
                    Save();
                    var applied = _engine.Apply(previewPath, instance.ReviewHash, instance.JournalPath);
                    if (applied.Status != "applied")
                    {
                        var reason = applied.Changes.FirstOrDefault(change => change.Error is not null) is { } failed ? failed.Name + ": " + failed.Error : "Windows did not accept the requested values.";
                        Restore(instance);
                        instance.Error = reason;
                        throw new InvalidOperationException(reason);
                    }
                    instance.Status = "active";
                    instance.Error = null;
                }
                catch (ProcessEndedException) { if (created is not null) Discard(created); }
                catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { if (created is not null) Discard(created); }
                catch (Exception error)
                {
                    if (created is not null && created.Status == "applying") Discard(created);
                    _state.Errors.Add(rule.Name + ": " + error.Message);
                    _state.Issues.Add(new(rule.RuleId, processId, identity?.ExecutablePath, error.Message));
                    if (!(_unavailable.TryGetValue(key, out var previous) && previous.Retry == DateTime.MaxValue))
                    {
                        var delay = _unavailable.TryGetValue(key, out var earlier) ? TimeSpan.FromSeconds(earlier.Delay.TotalSeconds * 2) : TimeSpan.FromSeconds(1);
                        _unavailable[key] = (error.Message, delay > TimeSpan.FromSeconds(64) ? DateTime.MaxValue : DateTime.UtcNow + delay, delay);
                    }
                }
            }
        }
        foreach (var stale in _unavailable.Keys.Where(key => !live.Contains(key)).ToArray()) _unavailable.Remove(stale);
        _enabledRules = enabledRules.Length;
        _state.Status = "running";
        Save();
        return _state;
    }

    public PolicyHostState Stop()
    {
        foreach (var instance in _state.Instances.Where(instance => instance.Status is not ("restored" or "expired"))) Restore(instance);
        _state.Status = _state.Instances.Any(instance => instance.Status == "conflict") ? "stoppedWithConflicts" : "stopped";
        _state.Host = null;
        Save();
        return _state;
    }

    private void Discard(PolicyInstance instance)
    {
        if (File.Exists(instance.JournalPath)) { Restore(instance); return; }
        _state.Instances.Remove(instance);
        _pruned.Add(Path.GetDirectoryName(instance.JournalPath)!);
    }

    private static bool Alive(RunningProcess process)
    {
        try
        {
            using var target = new ProcessTarget(process.ProcessId);
            return target.Identity().CreationTimeFileTimeUtc == process.CreationTimeFileTimeUtc;
        }
        catch (ProcessEndedException) { return false; }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { return false; }
        catch (Exception) { return true; }
    }

    private (SavedProcessRule Rule, string Hash)[] ReadRules()
    {
        var files = Directory.Exists(_store.RulesDirectory) ? new DirectoryInfo(_store.RulesDirectory).GetFiles("*.json") : [];
        if (_ruleSnapshot is not null && files.Length == _ruleStamps.Count &&
            files.All(file => _ruleStamps.TryGetValue(file.FullName, out var stamp) && stamp == (file.LastWriteTimeUtc, file.Length))) return _ruleSnapshot;
        _ruleSnapshot = null;
        _ruleStamps.Clear();
        var rules = _store.ReadRules();
        foreach (var file in files) _ruleStamps[file.FullName] = (file.LastWriteTimeUtc, file.Length);
        _ruleSnapshot = rules;
        return rules;
    }

    private bool RestoreDue(PolicyInstance instance)
    {
        var now = DateTime.UtcNow;
        if (_restoreAttempts.TryGetValue(instance.JournalPath, out var last) && now - last < TimeSpan.FromSeconds(30)) return false;
        _restoreAttempts[instance.JournalPath] = now;
        return true;
    }

    private void Restore(PolicyInstance instance)
    {
        try
        {
            if (!File.Exists(instance.JournalPath) && instance.Status == "applying") { instance.Status = "restored"; instance.Error = null; return; }
            if (!File.Exists(instance.JournalPath)) throw new InvalidDataException("The recovery journal is missing; restoration cannot be confirmed.");
            var restored = _engine.Restore(instance.JournalPath);
            instance.Status = restored.Status is "restored" or "expired" ? restored.Status : "conflict";
            instance.Error = restored.Changes.FirstOrDefault(change => change.Error is not null)?.Error;
        }
        catch (Exception error) { instance.Status = "conflict"; instance.Error = error.Message; }
        if (instance.Status is "restored" or "expired") _restoreAttempts.Remove(instance.JournalPath);
    }

    private void Prune()
    {
        var terminal = _state.Instances.Where(instance => instance.Status is "restored" or "expired").ToList();
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
        if (_lastSavedState is not null && bytes.AsSpan().SequenceEqual(_lastSavedState) && DateTime.UtcNow - _state.UpdatedAtUtc < TimeSpan.FromSeconds(5)) return;
        _state.UpdatedAtUtc = DateTime.UtcNow;
        OperationFiles.Write(_store.StatePath, _state);
        _lastSavedState = JsonSerializer.SerializeToUtf8Bytes(_state, OperationFiles.Json);
        foreach (var directory in _pruned) DeleteOperation(directory);
        _pruned.Clear();
    }
}
