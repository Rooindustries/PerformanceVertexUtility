#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class ProcessPolicyAdoption
{
    public static string[] Adopt(string root)
    {
        var store = new ProcessPolicyStore(root);
        if (!PolicyRootSecurity.Elevated() || !Directory.Exists(store.Root)) return [];
        var current = OperationOwner.Current();
        if (!Foreign(store, current)) return [];
        using var rootLease = PolicyRootLease.Acquire(store.Root);
        using var lease = Lock(Path.Combine(store.Root, "rules-write"));
        using var gate = ProcessPolicyStore.Gate();
        var adopted = new List<string>();
        if (Directory.Exists(store.RulesDirectory))
            foreach (var path in Directory.GetFiles(store.RulesDirectory, "*.json").Order(StringComparer.OrdinalIgnoreCase))
            {
                SavedProcessRule rule;
                try { rule = OperationFiles.Read<SavedProcessRule>(path); }
                catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException) { continue; }
                if (!FromOtherName(rule.Owner, current)) continue;
                OperationFiles.Write(path, rule with { Owner = current, Revision = Guid.NewGuid().ToString("N") });
                adopted.Add(Path.GetFileName(path));
            }
        var discarded = false;
        if (File.Exists(store.StatePath) && ReadState(store) is { } state && FromOtherName(state.Owner, current) && (state.Host is null || ProcessPolicyStore.Exited(state.Host)))
        {
            foreach (var file in new[] { store.StatePath, store.HeartbeatPath, store.StopPath }) File.Delete(file);
            discarded = true;
        }
        if (rootLease.Moved) throw new UnauthorizedAccessException("The saved rules folder moved while it was changed.");
        if (adopted.Count > 0 || discarded)
            GovernorLog.Write(store.Root, "The PC name changed: kept " + adopted.Count + " saved rules for this Windows user" + (discarded ? " and discarded the earlier worker state, whose processes ended with the restart" : "") + ".");
        return adopted.ToArray();
    }

    private static bool Foreign(ProcessPolicyStore store, OperationOwner current)
    {
        if (File.Exists(store.StatePath) && ReadState(store) is { } state && FromOtherName(state.Owner, current)) return true;
        if (!Directory.Exists(store.RulesDirectory)) return false;
        foreach (var path in Directory.GetFiles(store.RulesDirectory, "*.json"))
        {
            try { if (FromOtherName(OperationFiles.Read<SavedProcessRule>(path).Owner, current)) return true; }
            catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException) { }
        }
        return false;
    }

    private static PolicyHostState? ReadState(ProcessPolicyStore store)
    {
        try { return OperationFiles.Read<PolicyHostState>(store.StatePath); }
        catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException) { return null; }
    }

    private static bool FromOtherName(OperationOwner owner, OperationOwner current)
        => owner.UserSid == current.UserSid && !string.Equals(owner.Machine, current.Machine, StringComparison.OrdinalIgnoreCase);

    private static FileStream Lock(string path)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            try { return OperationFiles.Lock(path); }
            catch (IOException) when (clock.Elapsed < TimeSpan.FromSeconds(10)) { Thread.Sleep(100); }
        }
    }
}
