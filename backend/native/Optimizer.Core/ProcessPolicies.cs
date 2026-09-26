#nullable enable
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

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
    public required DateTime UpdatedAtUtc { get; set; }
}

public sealed record PolicyWorkerStatus(PolicyHostState? State, bool? HostRunning, string? Error);
public sealed record PolicyStopRequest(OperationOwner Owner, RunningProcess Host);

public sealed class ProcessPolicyStore
{
    public string Root { get; }
    public string RulesDirectory => Path.Combine(Root, "rules");
    public string StatePath => Path.Combine(Root, "host.json");
    public string StopPath => Path.Combine(Root, "stop.request");

    public ProcessPolicyStore(string root) => Root = Path.GetFullPath(root);

    public void Save(SavedProcessRule rule)
    {
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
    private readonly ProcessPolicyStore _store;
    private readonly ProcessControlEngine _engine;
    private PolicyHostState _state;
    private byte[]? _lastSavedState;

    public ProcessPolicyHost(ProcessPolicyStore store, Func<RunningProcess, bool> excluded)
    {
        _store = store;
        _engine = new(identity => identity.ProcessId == Environment.ProcessId || excluded(identity));
        _state = File.Exists(store.StatePath) ? OperationFiles.Read<PolicyHostState>(store.StatePath) : new()
        {
            SchemaVersion = 1, Owner = OperationOwner.Current(), Host = null, Status = "stopped", Instances = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow,
        };
        _state.Owner.Verify();
        if (_state.SchemaVersion != 1) throw new InvalidDataException("Unsupported policy-host state version.");
    }

    public PolicyHostState Run(CancellationToken cancellationToken, TimeSpan? duration = null)
    {
        Directory.CreateDirectory(_store.Root);
        using var lease = OperationFiles.Lock(Path.Combine(_store.Root, "worker"));
        if (File.Exists(_store.StatePath))
        {
            _state = OperationFiles.Read<PolicyHostState>(_store.StatePath);
            _state.Owner.Verify();
            if (_state.SchemaVersion != 1) throw new InvalidDataException("Unsupported policy-host state version.");
        }
        using (var self = new ProcessTarget(Environment.ProcessId)) _state.Host = self.Identity();
        _state.Status = "running";
        Save();
        var clock = Stopwatch.StartNew();
        try
        {
            while (!cancellationToken.IsCancellationRequested && !StopRequested() && (duration is null || clock.Elapsed < duration))
            {
                Tick();
                cancellationToken.WaitHandle.WaitOne(500);
            }
        }
        finally
        {
            Stop();
            File.Delete(_store.StopPath);
        }
        return _state;
    }

    private bool StopRequested()
    {
        if (!File.Exists(_store.StopPath)) return false;
        var request = OperationFiles.Read<PolicyStopRequest>(_store.StopPath);
        request.Owner.Verify();
        return request.Host == _state.Host;
    }

    private static string ExecutableHash(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(file));
    }

    public PolicyHostState Tick()
    {
        _state.Errors = [];
        (SavedProcessRule Rule, string Hash)[] rules;
        try { rules = _store.ReadRules(); }
        catch (Exception error)
        {
            _state.Errors.Add("Saved rules could not be read: " + error.Message);
            foreach (var instance in _state.Instances.Where(instance => instance.Status is not ("restored" or "expired"))) Restore(instance);
            _state.Status = "configurationError";
            Save();
            return _state;
        }
        foreach (var instance in _state.Instances.Where(instance => instance.Status is not ("restored" or "expired")))
        {
            var enabled = rules.Any(pair => pair.Rule.Enabled && pair.Rule.RuleId == instance.RuleId && pair.Hash == instance.RuleHash);
            if (!enabled) { Restore(instance); continue; }
            if (instance.Status == "conflict") continue;
            try
            {
                using var process = new ProcessTarget(instance.Process.ProcessId);
                if (process.UserSid() != _state.Owner.UserSid) throw new InvalidOperationException("The process belongs to another Windows user.");
                var identity = process.Identity();
                if (identity.CreationTimeFileTimeUtc != instance.Process.CreationTimeFileTimeUtc) { instance.Status = "expired"; continue; }
                instance.Process.Verify(identity);
                var result = _engine.Apply(instance.PreviewPath, instance.ReviewHash, instance.JournalPath);
                instance.Status = result.Status == "applied" ? "active" : "conflict";
                instance.Error = result.Changes.FirstOrDefault(change => change.Error is not null)?.Error;
            }
            catch (ProcessEndedException) { instance.Status = "expired"; }
            catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { instance.Status = "expired"; }
            catch (Exception error) { instance.Status = "conflict"; instance.Error = error.Message; }
        }

        var enabledRules = rules.Where(pair => pair.Rule.Enabled).ToArray();
        var processes = ProcessNames.Find(enabledRules.Select(pair => Path.GetFileNameWithoutExtension(pair.Rule.ExecutablePath)));
        foreach (var (rule, hash) in enabledRules)
        {
            foreach (var processId in processes[Path.GetFileNameWithoutExtension(rule.ExecutablePath)])
            {
                if (processId == Environment.ProcessId) continue;
                try
                {
                    RunningProcess identity;
                    using (var target = new ProcessTarget(processId))
                    {
                        if (target.UserSid() != rule.Owner.UserSid) continue;
                        identity = target.Identity();
                        if (rule.Controls.ContainsKey("affinity") && CpuSelection.Fingerprint(target.Topology()) != rule.AffinityTopologyHash)
                            throw new InvalidDataException("CPU topology changed; review the saved hard-affinity selection.");
                    }
                    if (rule.MatchMode == "path" && !string.Equals(rule.ExecutablePath, identity.ExecutablePath, StringComparison.OrdinalIgnoreCase)) continue;
                    if (_state.Instances.Any(instance => instance.RuleId == rule.RuleId && instance.RuleHash == hash && instance.Process == identity && instance.Status is not ("restored" or "expired"))) continue;
                    if (rule.ExecutableHash is not null && !string.Equals(ExecutableHash(identity.ExecutablePath), rule.ExecutableHash, StringComparison.OrdinalIgnoreCase))
                    {
                        _state.Errors.Add(rule.Name + ": the executable changed and needs review.");
                        continue;
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
                    Save();
                    var applied = _engine.Apply(previewPath, instance.ReviewHash, instance.JournalPath);
                    instance.Status = applied.Status == "applied" ? "active" : "conflict";
                    instance.Error = applied.Changes.FirstOrDefault(change => change.Error is not null)?.Error;
                }
                catch (ProcessEndedException) { }
                catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { }
                catch (Exception error) { _state.Errors.Add(rule.Name + ": " + error.Message); }
            }
        }
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

    private void Restore(PolicyInstance instance)
    {
        try
        {
            if (!File.Exists(instance.JournalPath)) throw new InvalidDataException("The recovery journal is missing; restoration cannot be confirmed.");
            var restored = _engine.Restore(instance.JournalPath);
            instance.Status = restored.Status is "restored" or "expired" ? restored.Status : "conflict";
            instance.Error = restored.Changes.FirstOrDefault(change => change.Error is not null)?.Error;
        }
        catch (Exception error) { instance.Status = "conflict"; instance.Error = error.Message; }
    }

    private void Save()
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(_state, OperationFiles.Json);
        if (_lastSavedState is not null && bytes.AsSpan().SequenceEqual(_lastSavedState) && DateTime.UtcNow - _state.UpdatedAtUtc < TimeSpan.FromSeconds(5)) return;
        _state.UpdatedAtUtc = DateTime.UtcNow;
        OperationFiles.Write(_store.StatePath, _state);
        _lastSavedState = JsonSerializer.SerializeToUtf8Bytes(_state, OperationFiles.Json);
    }
}
