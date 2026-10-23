#nullable enable
using System.Runtime.InteropServices;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class WindowsFeatures
{
    private const int RestartRequired = 3010;
    private const int UnknownFeature = unchecked((int)0x800F080C);
    public static bool IsHypervisor(string name) => name.StartsWith("Microsoft-Hyper-V", StringComparison.Ordinal) || name is "HypervisorPlatform" or "VirtualMachinePlatform" or "Containers-DisposableClientVM" or "Windows-Defender-ApplicationGuard";
    public static TweakControlRead Read(ControlAddress address) => Read(address, DismServicing.Current);
    public static TweakControlRead Read(ControlAddress address, DismServicing dism)
    {
        if (address.Target != "system" || address.Property != "features") throw new InvalidDataException("Unknown Windows feature target.");
        Check(dism.Initialize(), "DismInitialize");
        uint session = 0; var opened = false; TweakControlRead read;
        try
        {
            Check(dism.OpenSession(out session), "DismOpenSession"); opened = true;
            Check(dism.GetFeatures(session, out var features), "DismGetFeatures");
            var states = new Dictionary<string, string>(StringComparer.Ordinal);
            var pending = false;
            foreach (var feature in features)
            {
                if (feature.State is 0 or 6 or 7) continue;
                states.Add(feature.Name, State(feature.Name, feature.State));
                pending |= feature.State is 1 or 5;
            }
            var parents = new Dictionary<string, string[]>(StringComparer.Ordinal);
            foreach (var name in states.Keys.Where(name => name.StartsWith("Microsoft-Hyper-V", StringComparison.Ordinal) || name is "HypervisorPlatform" or "VirtualMachinePlatform" or "Recall" or "Containers-DisposableClientVM").ToArray())
            {
                Check(dism.GetFeatureParents(session, name, out var found), "DismGetFeatureParent(" + name + ")");
                parents.Add(name, found.Order(StringComparer.Ordinal).ToArray());
                Check(dism.GetFeatureState(session, name, out var state), "DismGetFeatureInfo(" + name + ")");
                if (state is 1 or 5) { states[name] = State(name, state); pending = true; }
            }
            read = new(address, address.Key, OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(parents)), ControlValues.From(states),
                "Windows optional features", Parents: parents, RestartPending: pending);
        }
        finally
        {
            var close = opened ? dism.CloseSession(session) : 0;
            var shutdown = dism.Shutdown();
            Complete(dism, close, "DismCloseSession"); Complete(dism, shutdown, "DismShutdown");
        }
        return dism.RestartRequired ? read with { RestartPending = true } : read;
    }
    public static Dictionary<string, int> ReadStates(string[] names, DismServicing? dism = null)
    {
        var states = new Dictionary<string, int>(StringComparer.Ordinal);
        if (names.Length == 0) return states;
        dism ??= DismServicing.Current;
        Check(dism.Initialize(), "DismInitialize");
        uint session = 0; var opened = false;
        try
        {
            Check(dism.OpenSession(out session), "DismOpenSession"); opened = true;
            foreach (var name in names.Distinct(StringComparer.Ordinal))
            {
                var result = dism.GetFeatureState(session, name, out var state);
                if (result != UnknownFeature) Check(result, "DismGetFeatureInfo(" + name + ")");
                states.Add(name, result == UnknownFeature ? 0 : state);
            }
        }
        finally
        {
            var close = opened ? dism.CloseSession(session) : 0; var shutdown = dism.Shutdown();
            Check(close, "DismCloseSession"); Check(shutdown, "DismShutdown");
        }
        return states;
    }
    private static string State(string name, int state) => state switch
    {
        2 => "Disabled", 3 => "DisabledWithPayloadRemoved", 4 => "Enabled",
        5 => "Enabled", 1 => "Disabled",
        _ => throw new InvalidDataException("Windows feature state cannot be reviewed: " + name + " (" + state + ")."),
    };
    public static void Write(TweakControlRead before, JsonElement desired) => Write(before, desired, DismServicing.Current);
    public static void Write(TweakControlRead before, JsonElement desired, DismServicing dism)
    {
        if (before.RestartPending) throw new InvalidDataException("Restart Windows before changing pending features.");
        var changes = desired.EnumerateObject().Where(property => !ControlValues.Equal(property.Value, before.Value.GetProperty(property.Name))).ToArray();
        if (changes.Any(property => property.Name.Contains(';') || property.Value.GetString() is not ("Enabled" or "Disabled" or "DisabledWithPayloadRemoved"))) throw new InvalidDataException("Invalid Windows feature selection.");
        Check(dism.Initialize(), "DismInitialize");
        uint session = 0; var opened = false;
        try
        {
            Check(dism.OpenSession(out session), "DismOpenSession"); opened = true;
            foreach (var state in new[] { "Disabled", "DisabledWithPayloadRemoved", "Enabled" })
            {
                var names = changes.Where(property => property.Value.GetString() == state).Select(property => property.Name).ToArray();
                if (names.Length == 0) continue;
                var result = state == "Enabled"
                    ? dism.EnableFeatures(session, string.Join(';', names))
                    : dism.DisableFeatures(session, string.Join(';', names), state == "DisabledWithPayloadRemoved");
                if (result != 1) Complete(dism, result, "DISM feature change");
                if (result == 1)
                {
                    opened = false; Complete(dism, dism.CloseSession(session), "DismCloseSession(reload)");
                    Check(dism.OpenSession(out session), "DismOpenSession(reload)"); opened = true;
                }
            }
        }
        finally
        {
            var close = opened ? dism.CloseSession(session) : 0; var shutdown = dism.Shutdown();
            Complete(dism, close, "DismCloseSession"); Complete(dism, shutdown, "DismShutdown");
        }
    }
    public static string[] Changed(ControlMutation change) => change.After.ValueKind != JsonValueKind.Object || change.Before.Value.ValueKind != JsonValueKind.Object ? [] : change.After.EnumerateObject()
        .Where(property => !change.Before.Value.TryGetProperty(property.Name, out var before) || !ControlValues.Equal(before, property.Value))
        .Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
    public static TweakState Reconcile(TweakState state, TweakControlRead observed, string[] features)
    {
        var id = observed.Id;
        if (features.Length == 0 && !(state.Controls ?? []).Any(item => item.Original.Id == id && item.Original.Binding != observed.Binding)) return state;
        var held = (state.Controls ?? []).Single(item => item.Original.Id == id);
        var baseline = held.RestoreValue ?? held.Original.Value;
        var profiles = new List<TweakProfile>();
        foreach (var profile in state.Profiles)
        {
            var controls = new List<ControlClaim>(); var dropped = new List<TweakSelection>();
            foreach (var claim in profile.Controls ?? [])
            {
                if (claim.Target.Id != id || !claim.Desired.EnumerateObject().Any(feature => features.Contains(feature.Name))) { controls.Add(claim); continue; }
                dropped.Add(new(claim.SettingId, claim.OptionId));
                var rest = claim.Desired.EnumerateObject().Where(feature => !features.Contains(feature.Name)).ToArray();
                if (rest.Any(feature => !baseline.TryGetProperty(feature.Name, out var original) || !ControlValues.Equal(original, feature.Value)))
                    controls.Add(claim with { Desired = ControlValues.From(rest.ToDictionary(feature => feature.Name, feature => feature.Value)) });
            }
            var selections = profile.Selections.Except(dropped).ToArray();
            if (selections.Length > 0 || profile.Claims.Length > 0 || controls.Count > 0) profiles.Add(profile with { Selections = selections, Controls = controls.ToArray() });
        }
        var owned = profiles.SelectMany(profile => profile.Controls ?? []).Any(claim => claim.Target.Id == id);
        var applied = ControlValues.From(held.Applied.EnumerateObject().ToDictionary(feature => feature.Name,
            feature => features.Contains(feature.Name) && baseline.TryGetProperty(feature.Name, out var original) ? original : feature.Value));
        return state with
        {
            Revision = Guid.NewGuid().ToString("N"), Profiles = profiles.ToArray(),
            Controls = (state.Controls ?? []).Where(item => owned || item.Original.Id != id).Select(item => item.Original.Id == id
                ? item with { Original = item.Original with { Binding = observed.Binding, Parents = observed.Parents }, Applied = applied } : item).ToArray(),
        };
    }
    public static string PendingRecovery(ControlMutation change, TweakControlRead current)
    {
        var kept = Changed(change).Where(name => current.Value.ValueKind == JsonValueKind.Object && current.Value.TryGetProperty(name, out var value) && ControlValues.Equal(value, change.After.GetProperty(name)))
            .Select(name => name + " " + change.After.GetProperty(name).GetString()).ToArray();
        return kept.Length == 0 ? "Restart Windows before recovering pending feature changes." :
            "Windows keeps these feature changes pending until restart: " + string.Join(", ", kept) + ". Restart Windows, then review recovery to undo them. Undoing them needs another restart.";
    }
    public static JsonElement Expand(TweakControlRead read, JsonElement requested, bool allowPending)
    {
        if (read.RestartPending && !allowPending) throw new InvalidDataException("Restart Windows to finish the pending feature change before changing features again.");
        if (requested.ValueKind != JsonValueKind.Object || read.Parents is null) throw new InvalidDataException("A Windows feature dependency snapshot is required.");
        var changes = requested.EnumerateObject().ToDictionary(property => property.Name, property => property.Value.GetString()!, StringComparer.Ordinal);
        foreach (var item in changes.ToArray())
        {
            if (item.Key == "Microsoft-Hyper-V-All")
                foreach (var name in read.Parents.Keys.Where(name => name.StartsWith("Microsoft-Hyper-V", StringComparison.Ordinal))) changes[name] = item.Value;
        }
        void IncludeParents(string name, HashSet<string> visited)
        {
            if (!visited.Add(name)) throw new InvalidDataException("Windows feature dependencies contain a cycle.");
            if (!read.Parents.TryGetValue(name, out var parents)) throw new InvalidDataException("Windows feature dependencies are unavailable: " + name);
            foreach (var parent in parents)
            {
                if (changes.TryGetValue(parent, out var choice) && choice != "Enabled") throw new InvalidDataException("A required Windows feature is selected for removal: " + parent);
                changes[parent] = "Enabled"; IncludeParents(parent, new(visited, StringComparer.Ordinal));
            }
        }
        foreach (var item in changes.Where(item => item.Value == "Enabled").ToArray()) IncludeParents(item.Key, new(StringComparer.Ordinal));
        foreach (var item in changes.ToArray())
        {
            if (!read.Value.TryGetProperty(item.Key, out var original)) throw new InvalidDataException("This Windows installation does not offer feature: " + item.Key);
            if (item.Value == "Disabled" && original.GetString() == "DisabledWithPayloadRemoved") changes[item.Key] = "DisabledWithPayloadRemoved";
        }
        return ControlValues.From(changes);
    }
    private static void Check(int result, string name) { if (result != 0) throw new InvalidOperationException(name + " failed with HRESULT 0x" + result.ToString("X8") + "."); }
    private static void Complete(DismServicing dism, int result, string name)
    {
        if (result == RestartRequired) dism.RestartRequired = true;
        else Check(result, name);
    }
}

public abstract class DismServicing
{
    public static DismServicing Native { get; } = new NativeDism();
    internal static DismServicing Current =>
#if ROO_INDUSTRIES_TEST_HOOKS
        Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_FEATURE_STATES") is { Length: > 0 } states ? new FileDism(states) :
#endif
        Native;
    public bool RestartRequired { get; internal set; }
    public abstract int Initialize();
    public abstract int OpenSession(out uint session);
    public abstract int GetFeatures(uint session, out (string Name, int State)[] features);
    public abstract int GetFeatureParents(uint session, string feature, out string[] parents);
    public abstract int GetFeatureState(uint session, string feature, out int state);
    public abstract int EnableFeatures(uint session, string features);
    public abstract int DisableFeatures(uint session, string features, bool removePayload);
    public abstract int CloseSession(uint session);
    public abstract int Shutdown();
}

#if ROO_INDUSTRIES_TEST_HOOKS
sealed class FileDism(string path) : DismServicing
{
    private readonly Dictionary<string, int> _states = OperationFiles.Read<Dictionary<string, int>>(path);
    private const int Refused = unchecked((int)0x80070005);
    public override int Initialize() => 0;
    public override int OpenSession(out uint session) { session = 1; return 0; }
    public override int GetFeatures(uint session, out (string Name, int State)[] features) { features = _states.Select(item => (item.Key, item.Value)).ToArray(); return 0; }
    public override int GetFeatureParents(uint session, string feature, out string[] parents) { parents = []; return 0; }
    public override int GetFeatureState(uint session, string feature, out int state) { state = _states[feature]; return 0; }
    public override int EnableFeatures(uint session, string features) => Refused;
    public override int DisableFeatures(uint session, string features, bool removePayload) => Refused;
    public override int CloseSession(uint session) => 0;
    public override int Shutdown() => 0;
}
#endif

sealed class NativeDism : DismServicing
{
    private const string Online = "DISM_{53BFAE52-B167-4E2F-A258-0A37B57FF845}";
    public override int Initialize() => DismInitialize(0, IntPtr.Zero, IntPtr.Zero);
    public override int OpenSession(out uint session) => DismOpenSession(Online, IntPtr.Zero, IntPtr.Zero, out session);
    public override int GetFeatures(uint session, out (string Name, int State)[] features)
    {
        var result = DismGetFeatures(session, IntPtr.Zero, 0, out var pointer, out var count);
        features = result == 0 ? Values(pointer, count) : []; return result;
    }
    public override int GetFeatureParents(uint session, string feature, out string[] parents)
    {
        var result = DismGetFeatureParent(session, feature, IntPtr.Zero, 0, out var pointer, out var count);
        parents = result == 0 ? Values(pointer, count).Select(item => item.Name).ToArray() : []; return result;
    }
    public override int GetFeatureState(uint session, string feature, out int state)
    {
        state = -1;
        var result = DismGetFeatureInfo(session, feature, IntPtr.Zero, 0, out var pointer);
        if (result != 0) return result;
        try
        {
            if (pointer == IntPtr.Zero) throw new InvalidDataException("Windows feature information is missing: " + feature);
            state = Marshal.PtrToStructure<Feature>(pointer).State; return result;
        }
        finally { if (pointer != IntPtr.Zero) Delete(pointer); }
    }
    public override int EnableFeatures(uint session, string features) => DismEnableFeature(session, features, IntPtr.Zero, 0, false, IntPtr.Zero, 0, true, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    public override int DisableFeatures(uint session, string features, bool removePayload) => DismDisableFeature(session, features, IntPtr.Zero, removePayload, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    public override int CloseSession(uint session) => DismCloseSession(session);
    public override int Shutdown() => DismShutdown();
    private static (string Name, int State)[] Values(IntPtr pointer, uint count)
    {
        try
        {
            if (count > 10000 || count > 0 && pointer == IntPtr.Zero) throw new InvalidDataException("Invalid Windows feature array.");
            var result = new List<(string, int)>(); var stride = Marshal.SizeOf<Feature>();
            for (var index = 0; index < count; index++)
            {
                var value = Marshal.PtrToStructure<Feature>(IntPtr.Add(pointer, checked((int)index * stride)));
                result.Add((Marshal.PtrToStringUni(value.Name) ?? throw new InvalidDataException("A Windows feature name is missing."), value.State));
            }
            return result.ToArray();
        }
        finally { if (pointer != IntPtr.Zero) Delete(pointer); }
    }
    private static void Delete(IntPtr pointer)
    {
        var result = DismDelete(pointer);
        if (result != 0) throw new InvalidOperationException("DismDelete failed with HRESULT 0x" + result.ToString("X8") + ".");
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct Feature { public IntPtr Name; public int State; }
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismInitialize(int level, IntPtr log, IntPtr scratch);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismOpenSession(string image, IntPtr windows, IntPtr drive, out uint session);
    [DllImport("DismApi.dll")] private static extern int DismGetFeatures(uint session, IntPtr identifier, int packageKind, out IntPtr features, out uint count);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismGetFeatureParent(uint session, string feature, IntPtr identifier, int packageKind, out IntPtr features, out uint count);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismGetFeatureInfo(uint session, string feature, IntPtr identifier, int packageKind, out IntPtr info);
    [DllImport("DismApi.dll")] private static extern int DismDelete(IntPtr memory);
    [DllImport("DismApi.dll")] private static extern int DismCloseSession(uint session);
    [DllImport("DismApi.dll")] private static extern int DismShutdown();
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismEnableFeature(uint session, string feature, IntPtr identifier, int packageKind, [MarshalAs(UnmanagedType.Bool)] bool limitAccess, IntPtr sources, uint sourceCount, [MarshalAs(UnmanagedType.Bool)] bool enableAll, IntPtr cancel, IntPtr progress, IntPtr data);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismDisableFeature(uint session, string feature, IntPtr package, [MarshalAs(UnmanagedType.Bool)] bool removePayload, IntPtr cancel, IntPtr progress, IntPtr data);
}
