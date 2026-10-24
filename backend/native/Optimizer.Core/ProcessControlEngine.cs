#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class InstanceBusyException() : IOException("Another operation controls this process instance.");

public sealed class ProcessControlEngine
{
    private readonly Func<RunningProcess, bool> _excluded;
    private readonly ProcessTarget? _retained;
    public ProcessControlEngine(Func<RunningProcess, bool> excluded) => _excluded = excluded;
    private ProcessControlEngine(Func<RunningProcess, bool> excluded, ProcessTarget retained) { _excluded = excluded; _retained = retained; }
    internal ProcessControlEngine WithTarget(ProcessTarget retained) => new(_excluded, retained);
    private ProcessTarget Open(int processId, IEnumerable<string>? writable = null, IEnumerable<string>? readControls = null)
    {
        if (_retained is null) return new(processId, writable, readControls);
        if (_retained.Identity().ProcessId != processId) throw new InvalidDataException("The retained handle belongs to another process.");
        return _retained.Borrow(writable);
    }

    public ProcessControlPreview Preview(int processId, Dictionary<string, JsonElement> desired, CpuSelection? cpuSelection = null)
    {
        using var target = Open(processId);
        var identity = target.Identity();
        if (_excluded(identity)) throw new InvalidOperationException("This application is excluded by the protection policy.");
        target.RequireUnprotected();
        var topology = target.Topology();
        desired = new(desired, StringComparer.Ordinal);
        if (cpuSelection is not null)
        {
            if (desired.ContainsKey("cpuSets")) throw new InvalidDataException("Specify a CPU selection or resolved IDs, not both.");
            desired.Add("cpuSets", JsonSerializer.SerializeToElement(cpuSelection.Resolve(topology)));
        }
        ValidateNames(desired.Keys);
        var blocked = _retained is null ? ProcessTarget.BlockedControls(processId, desired.Keys) : new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in blocked.Keys) desired.Remove(name);
        if (desired.Count == 0) throw new ProcessControlBlockedException(blocked.Keys);
        var original = new Dictionary<string, ControlRead>(StringComparer.Ordinal);
        foreach (var pair in desired)
        {
            var read = target.Read(pair.Key);
            var value = read.Require();
            ValidateValue(pair.Key, value);
            ValidateValue(pair.Key, pair.Value);
            original.Add(pair.Key, read);
        }
        return new()
        {
            SchemaVersion = 1, OperationId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(),
            Identity = identity, Original = original, Desired = desired, TopologyHash = CpuSelection.Fingerprint(topology),
            Blocked = blocked.Count == 0 ? null : blocked,
        };
    }

    public ProcessControlJournal Apply(string previewPath, string reviewHash, string journalPath)
    {
        RequireSeparate(previewPath, journalPath);
        var preview = OperationFiles.Read<ProcessControlPreview>(previewPath, reviewHash);
        ValidatePreview(preview);
        preview.Owner.Verify();
        using var lease = OperationFiles.Lock(journalPath);
        using var instanceLease = InstanceLease(preview.Identity);
#if GOVERNOR_TEST_HOOKS
        if (int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_APPLY_PAUSE_MS"), out var applyPause) && applyPause > 0) Thread.Sleep(Math.Min(applyPause, 10000));
#endif
        if (File.Exists(journalPath))
        {
            var existing = OperationFiles.Read<ProcessControlJournal>(journalPath);
            if (existing.Preview.OperationId != preview.OperationId || !string.Equals(existing.ReviewHash, reviewHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("This journal belongs to a different reviewed operation.");
            ValidateJournal(existing);
            if (existing.Status is "restored" or "expired") return existing;
            if (existing.Status == "applying") return Resume(preview, existing, journalPath);
            var before = JsonSerializer.Serialize(existing, OperationFiles.Json);
            using var observedTarget = Open(preview.Identity.ProcessId, readControls: existing.Changes.Select(change => change.Name));
            preview.Identity.Verify(observedTarget.Identity());
            existing.Status = "applied";
            foreach (var change in existing.Changes)
            {
                if (change.Status is "pending" or "restoreIntent" or "restored" or "leftAsSet") { existing.Status = "needsReconciliation"; continue; }
                var observation = observedTarget.Read(change.Name);
                if (change.Error is not null && observation.Known && ProcessTarget.Equivalent(change.Name, observation.Require(), change.Original))
                {
                    existing.Status = "needsReconciliation";
                    change.Observed = observation.Value;
                    continue;
                }
                try
                {
                    if (!ProcessTarget.Equivalent(change.Name, observation.Require(), change.Desired)) throw new InvalidOperationException("Another controller changed this field; the saved policy is suspended.");
                    if (change.Status == "applyIntent") change.Status = "applied";
                    change.Error = null; change.ErrorKind = null;
                }
                catch (Exception error) { existing.Status = "needsReconciliation"; change.Error = error.Message; }
                change.Observed = observation.Value;
            }
            if (before != JsonSerializer.Serialize(existing, OperationFiles.Json)) Save(journalPath, existing);
            return existing;
        }
        using var target = Open(preview.Identity.ProcessId, preview.Desired.Keys);
        preview.Identity.Verify(target.Identity());
        if (_excluded(preview.Identity)) throw new InvalidOperationException("This application is now excluded by the protection policy.");
        target.RequireUnprotected();
        if (preview.TopologyHash != CpuSelection.Fingerprint(target.Topology())) throw new InvalidDataException("Topology changed after preview.");
        foreach (var pair in preview.Original)
            if (!ProcessTarget.Equivalent(pair.Key, pair.Value.Require(), target.Read(pair.Key).Require()))
                throw new InvalidOperationException("The " + pair.Key + " value changed after preview.");

        var journal = new ProcessControlJournal
        {
            SchemaVersion = 1, Preview = preview, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash, Status = "applying", UpdatedAtUtc = DateTime.UtcNow,
            Changes = preview.Desired.Select(pair => new ControlChange
            {
                Name = pair.Key, Original = preview.Original[pair.Key].Require(), Desired = pair.Value, Status = "pending",
            }).ToList(),
        };
        Save(journalPath, journal);
        return Execute(target, journal, journalPath);
    }

    internal ProcessControlJournal Adopt(string previewPath, string reviewHash, string journalPath)
    {
        RequireSeparate(previewPath, journalPath);
        var preview = OperationFiles.Read<ProcessControlPreview>(previewPath, reviewHash);
        ValidatePreview(preview);
        preview.Owner.Verify();
        using var lease = OperationFiles.Lock(journalPath);
        using var instanceLease = InstanceLease(preview.Identity);
        if (File.Exists(journalPath)) throw new InvalidDataException("This process already has a recovery journal.");
        using var target = Open(preview.Identity.ProcessId, readControls: preview.Desired.Keys);
        preview.Identity.Verify(target.Identity());
        if (_excluded(preview.Identity)) throw new InvalidOperationException("This application is now excluded by the protection policy.");
        target.RequireUnprotected();
        if (preview.TopologyHash != CpuSelection.Fingerprint(target.Topology())) throw new InvalidDataException("Topology changed after preview.");
        var changes = new List<ControlChange>();
        foreach (var pair in preview.Desired)
        {
            var current = target.Read(pair.Key).Require();
            if (!ProcessTarget.Equivalent(pair.Key, current, pair.Value)) throw new InvalidOperationException("The inherited " + ProcessControlBlockedException.Label(pair.Key) + " changed before it was recorded.");
            changes.Add(new ControlChange { Name = pair.Key, Original = preview.Original[pair.Key].Require(), Desired = pair.Value, Status = "applied", Observed = current });
        }
        var journal = new ProcessControlJournal
        {
            SchemaVersion = 1, Preview = preview, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash, Status = "applied", UpdatedAtUtc = DateTime.UtcNow, Changes = changes,
        };
        Save(journalPath, journal);
        return journal;
    }

    private ProcessControlJournal Resume(ProcessControlPreview preview, ProcessControlJournal journal, string journalPath)
    {
        using var target = Open(preview.Identity.ProcessId, preview.Desired.Keys);
        preview.Identity.Verify(target.Identity());
        if (_excluded(preview.Identity)) throw new InvalidOperationException("This application is now excluded by the protection policy.");
        target.RequireUnprotected();
        if (preview.TopologyHash != CpuSelection.Fingerprint(target.Topology())) throw new InvalidDataException("Topology changed after preview.");
        return Execute(target, journal, journalPath);
    }

    private static ProcessControlJournal Execute(ProcessTarget target, ProcessControlJournal journal, string journalPath)
    {
        var failed = false;
        foreach (var change in journal.Changes)
        {
            try
            {
                var current = target.Read(change.Name).Require();
                if (change.Status is "unchanged" or "applied")
                {
                    change.Observed = current;
                    if (!ProcessTarget.Equivalent(change.Name, current, change.Desired)) throw new InvalidOperationException("Another controller changed this field; the saved policy is suspended.");
                    continue;
                }
                if (change.Status == "applyIntent" && ProcessTarget.Equivalent(change.Name, current, change.Desired)) { Succeeded(change, "applied", current); Save(journalPath, journal); continue; }
                if (!ProcessTarget.Equivalent(change.Name, change.Original, current)) throw new InvalidOperationException("A concurrent change replaced the reviewed original.");
                if (ProcessTarget.Equivalent(change.Name, current, change.Desired)) { Succeeded(change, "unchanged", current); Save(journalPath, journal); continue; }
                change.Status = "applyIntent";
                Save(journalPath, journal);
                target.Write(change.Name, change.Desired);
                var after = target.Read(change.Name).Require();
                change.Observed = after;
                if (!ProcessTarget.Equivalent(change.Name, after, change.Desired)) throw new InvalidOperationException("Windows readback differs from the requested value.");
                Succeeded(change, "applied", after);
                Save(journalPath, journal);
            }
            catch (Exception error)
            {
                change.Error = error.Message;
                change.ErrorKind = ProcessFailures.Denied(error) ? "denied" : null;
                failed = true;
                Save(journalPath, journal);
            }
        }
        journal.Status = failed ? "needsReconciliation" : "applied";
        Save(journalPath, journal);
        return journal;
    }

    private static void Succeeded(ControlChange change, string status, JsonElement observed)
    {
        change.Status = status; change.Observed = observed; change.Error = null; change.ErrorKind = null;
    }

    public ProcessControlJournal Reassert(string journalPath, out bool wrote)
    {
        wrote = false;
        using var lease = OperationFiles.Lock(journalPath);
        var journal = OperationFiles.Read<ProcessControlJournal>(journalPath);
        ValidateJournal(journal);
        if (journal.Status is not ("applied" or "needsReconciliation") || journal.Changes.Any(change => change.Status is not ("applied" or "unchanged" or "applyIntent"))) return journal;
        using var instanceLease = InstanceLease(journal.Preview.Identity);
        using var target = Open(journal.Preview.Identity.ProcessId, journal.Changes.Select(change => change.Name));
        journal.Preview.Identity.Verify(target.Identity());
        if (_excluded(journal.Preview.Identity)) throw new InvalidOperationException("This application is now excluded by the protection policy.");
        target.RequireUnprotected();
        foreach (var change in journal.Changes)
        {
            var current = target.Read(change.Name).Require();
            change.Observed = current;
            if (ProcessTarget.Equivalent(change.Name, current, change.Desired)) { if (change.Status == "applyIntent") change.Status = "applied"; change.Error = null; change.ErrorKind = null; continue; }
            change.Status = "applyIntent";
            Save(journalPath, journal);
            target.Write(change.Name, change.Desired);
            wrote = true;
            var after = target.Read(change.Name).Require();
            change.Observed = after;
            if (!ProcessTarget.Equivalent(change.Name, after, change.Desired))
            {
                change.Error = "Windows readback differs from the requested value.";
                journal.Status = "needsReconciliation";
                Save(journalPath, journal);
                return journal;
            }
            change.Status = "applied";
            change.Error = null; change.ErrorKind = null;
        }
        journal.Status = "applied";
        Save(journalPath, journal);
        return journal;
    }

    public ProcessControlJournal Restore(string journalPath, bool overwrite = false) => Restore(journalPath, overwrite, false, false, null);

    public ProcessControlJournal RestoreApplyOnce(string journalPath, string dataRoot, string? repoRoot) =>
        Restore(journalPath, false, false, false, new Ownership(dataRoot, repoRoot, journalPath));

    internal ProcessControlJournal RestoreGovernor(string journalPath, bool relinquished) => Restore(journalPath, false, true, relinquished, null);

    private sealed record Ownership(string DataRoot, string? RepoRoot, string JournalPath)
    {
        public GovernorClaims.Own? Holders(RunningProcess identity, string name, JsonElement current) => GovernorClaims.OwnChange(identity, name, current, DataRoot, RepoRoot, JournalPath);
        public (string[] Journals, ReleasedClaim[] Released) SetBack(RunningProcess identity, string name, JsonElement current, JsonElement desired) =>
            GovernorClaims.SetBack(identity, name, current, desired, DataRoot, RepoRoot, JournalPath);
    }

    private ProcessControlJournal Restore(string journalPath, bool overwrite, bool governor, bool relinquished, Ownership? owned, string? only = null)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = OperationFiles.Read<ProcessControlJournal>(journalPath);
        ValidateJournal(journal);
        if (journal.Status is "restored" or "expired") return journal;
        using var instanceLease = InstanceLease(journal.Preview.Identity);
        ProcessTarget target;
        try { target = Open(journal.Preview.Identity.ProcessId, journal.Changes.Where(IsAttempted).Select(change => change.Name)); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87)
        {
            journal.Status = "expired";
            Save(journalPath, journal);
            return journal;
        }
        catch (ProcessEndedException)
        {
            journal.Status = "expired";
            Save(journalPath, journal);
            return journal;
        }
        using (target)
        {
            var identity = target.Identity();
            if (identity.CreationTimeFileTimeUtc != journal.Preview.Identity.CreationTimeFileTimeUtc)
            {
                journal.Status = "expired";
                Save(journalPath, journal);
                return journal;
            }
            journal.Preview.Identity.Verify(identity);
            target.RequireUnprotected();
            var conflicts = false;
            JsonElement Release(string name, string[] holders)
            {
                foreach (var held in holders)
                {
                    var record = Restore(held, false, false, false, null, name);
                    if (record.Status != "expired" && record.Changes.FirstOrDefault(change => change.Name == name) is { Status: not ("restored" or "leftAsSet") } stuck)
                        throw new InvalidOperationException("Another saved change on this app couldn't be undone first" + (stuck.Error is { } reason ? ": " + reason : "."));
                }
                return target.Read(name).Require();
            }
            bool Settle(ControlChange change)
            {
                var confirmed = change.Status == "applied";
                var settled = false;
                var current = target.Read(change.Name).Require();
                for (var round = 0; ; round++)
                {
                    if (round > 4) throw new InvalidOperationException("This setting kept changing, so Undo left it for now. Try again in a moment.");
                    if (ProcessTarget.Equivalent(change.Name, current, change.Original))
                    {
                        if (owned is not null && !settled)
                        {
                            settled = true;
                            var (stacked, released) = owned.SetBack(journal.Preview.Identity, change.Name, current, change.Desired);
                            if (released.Length > 0)
                            {
                                change.Released = (change.Released ?? []).Concat(released).DistinctBy(claim => claim.Feature + "\n" + claim.Original.GetRawText() + "\n" + claim.Record).ToList();
                                Save(journalPath, journal);
                            }
                            if (stacked.Length > 0) { current = Release(change.Name, stacked); continue; }
                        }
                        Succeeded(change, "restored", current);
                        return true;
                    }
                    if (ProcessTarget.Equivalent(change.Name, current, change.Desired)) confirmed = true;
                    if (governor && (relinquished || !ProcessTarget.Equivalent(change.Name, current, change.Desired)))
                    {
                        LeaveAsSet(change, current);
                        return true;
                    }
                    if (!overwrite && !ProcessTarget.Equivalent(change.Name, current, change.Desired))
                    {
                        var holders = owned?.Holders(journal.Preview.Identity, change.Name, current);
                        if (holders is null)
                        {
                            if (owned is null || !confirmed) throw new InvalidOperationException("Another writer changed this field; restoration will not overwrite it.");
                            LeaveAsSet(change, current);
                            return true;
                        }
                        if (holders.Unsure is { } unsure) throw new InvalidOperationException(unsure);
                        if (holders.Journals.Length > 0) { current = Release(change.Name, holders.Journals); continue; }
                    }
                    change.Status = "restoreIntent";
                    Save(journalPath, journal);
#if GOVERNOR_TEST_HOOKS
                    if (int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_RESTORE_INTENT_PAUSE_MS"), out var intentPause) && intentPause > 0) Thread.Sleep(Math.Min(intentPause, 10000));
#endif
                    if (!overwrite)
                    {
                        var beforeWrite = target.Read(change.Name).Require();
                        if (!ProcessTarget.Equivalent(change.Name, beforeWrite, current) && !ProcessTarget.Equivalent(change.Name, beforeWrite, change.Desired))
                        {
                            if (owned is null && !governor) throw new InvalidOperationException("The field changed before restoration.");
                            if (owned is null)
                            {
                                LeaveAsSet(change, beforeWrite);
                                return true;
                            }
                            current = beforeWrite;
                            continue;
                        }
                    }
                    target.Write(change.Name, change.Original);
                    var after = target.Read(change.Name).Require();
                    change.Observed = after;
                    if (!ProcessTarget.Equivalent(change.Name, after, change.Original)) throw new InvalidOperationException("Restoration readback did not match the saved original.");
                    Succeeded(change, "restored", after);
                    return false;
                }
            }
            foreach (var change in journal.Changes.Where(change => IsAttempted(change) && (only is null || change.Name == only)).Reverse())
            {
                var early = false;
                try { early = Settle(change); }
                catch (Exception error) { change.Error = error.Message; change.ErrorKind = ProcessFailures.Denied(error) ? "denied" : null; conflicts = true; }
                Save(journalPath, journal);
#if GOVERNOR_TEST_HOOKS
                if (!early && int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_RESTORE_PAUSE_MS"), out var pause) && pause > 0) Thread.Sleep(Math.Min(pause, 10000));
#endif
            }
            journal.Status = conflicts ? "needsReconciliation" : journal.Changes.Any(IsAttempted) ? journal.Status : "restored";
            Save(journalPath, journal);
        }
        return journal;
    }

    public const string LeftAsSet = "Left as another program set it.";

    private static void LeaveAsSet(ControlChange change, JsonElement current)
    {
        change.Status = "leftAsSet";
        change.Observed = current;
        change.ErrorKind = "leftAsSet";
        change.Error = LeftAsSet;
    }

    private static bool IsAttempted(ControlChange change) => change.Status is "applyIntent" or "applied" or "restoreIntent";
    private static void Save(string path, ProcessControlJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }

    private static void ValidateJournal(ProcessControlJournal journal)
    {
        ValidatePreview(journal.Preview);
        journal.Preview.Owner.Verify();
        var reviewed = OperationFiles.Read<ProcessControlPreview>(journal.PreviewPath, journal.ReviewHash);
        if (JsonSerializer.Serialize(reviewed, OperationFiles.Json) != JsonSerializer.Serialize(journal.Preview, OperationFiles.Json))
            throw new InvalidDataException("The recovery journal's preview no longer matches its reviewed source.");
        if (journal.SchemaVersion != 1 || journal.Status is not ("applying" or "applied" or "needsReconciliation" or "restored" or "expired") ||
            journal.Changes.Count != journal.Preview.Desired.Count || journal.Changes.Select(change => change.Name).Distinct().Count() != journal.Changes.Count)
            throw new InvalidDataException("The process recovery journal is incomplete.");
        foreach (var change in journal.Changes)
        {
            if (change.Status is not ("pending" or "unchanged" or "applyIntent" or "applied" or "restoreIntent" or "restored" or "leftAsSet") ||
                change.Status == "leftAsSet" && (change.ErrorKind != "leftAsSet" || change.Error != LeftAsSet || change.Observed is null) ||
                !journal.Preview.Desired.TryGetValue(change.Name, out var desired) ||
                !ProcessTarget.Equivalent(change.Name, desired, change.Desired) ||
                !ProcessTarget.Equivalent(change.Name, journal.Preview.Original[change.Name].Require(), change.Original))
                throw new InvalidDataException("Recovery values no longer match the reviewed operation.");
        }
    }

    private static void ValidatePreview(ProcessControlPreview preview)
    {
        if (preview.SchemaVersion != 1 || !Guid.TryParseExact(preview.OperationId, "N", out _) || preview.Owner is null || preview.Identity is null || preview.Original is null || preview.Desired is null ||
            preview.TopologyHash is not { Length: 64 }) throw new InvalidDataException("The process preview is incomplete.");
        ValidateNames(preview.Desired.Keys);
        if (!preview.Original.Keys.Order().SequenceEqual(preview.Desired.Keys.Order())) throw new InvalidDataException("Every requested field needs its own original observation.");
        foreach (var name in preview.Desired.Keys)
        {
            ValidateValue(name, preview.Original[name].Require());
            ValidateValue(name, preview.Desired[name]);
        }
    }

    private static void ValidateNames(IEnumerable<string> names)
    {
        var all = names.ToArray();
        if (all.Length == 0 || all.Any(name => !ProcessTarget.ControlNames.Contains(name))) throw new InvalidDataException("Select supported process controls.");
    }

    public static void ValidateValue(string name, JsonElement value)
    {
        switch (name)
        {
            case "cpuPriority":
                if (value.GetString() is not ("Idle" or "BelowNormal" or "Normal" or "AboveNormal" or "High" or "Realtime")) throw new InvalidDataException("Invalid CPU priority.");
                break;
            case "affinity":
                var affinity = value.Deserialize<AffinityState>(OperationFiles.Json) ?? throw new InvalidDataException("Missing affinity.");
                if (string.IsNullOrWhiteSpace(affinity.Mask) || ProcessTarget.ParseMask(affinity.Mask) == 0) throw new InvalidDataException("Affinity mask must be nonzero.");
                break;
            case "cpuSets":
                var ids = value.Deserialize<uint[]>() ?? throw new InvalidDataException("Missing CPU Set IDs.");
                if (ids.Distinct().Count() != ids.Length) throw new InvalidDataException("Duplicate CPU Set ID.");
                break;
            case "ioPriority": if (value.GetInt32() is < 0 or > 3) throw new InvalidDataException("I/O priority is outside the supported range."); break;
            case "gpuPriority": if (value.GetInt32() is < 0 or > 5) throw new InvalidDataException("Invalid GPU priority."); break;
            case "memoryPriority": if (value.GetInt32() is < 1 or > 5) throw new InvalidDataException("Invalid memory priority."); break;
            case "executionQoS": _ = value.Deserialize<PowerThrottling>(OperationFiles.Json) ?? throw new InvalidDataException("Missing QoS state."); break;
            case "priorityBoost": _ = value.GetBoolean(); break;
            default: throw new InvalidDataException("Unknown process control.");
        }
    }

    private static IDisposable InstanceLease(RunningProcess identity)
    {
        var mutex = new Mutex(false, BrandCompatibility.ProcessMutexPrefix + identity.ProcessId + "-" + identity.CreationTimeFileTimeUtc);
        bool held;
        try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
        if (!held) { mutex.Dispose(); throw new InstanceBusyException(); }
        return new MutexLease(mutex);
    }

    private static void RequireSeparate(string left, string right)
    {
        if (string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Preview and journal paths must be separate.");
    }

    private sealed class MutexLease(Mutex mutex) : IDisposable
    {
        public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
    }
}
