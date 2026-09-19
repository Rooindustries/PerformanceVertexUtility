#nullable enable
using System.Runtime.InteropServices;
using System.Text.Json;

namespace RooIndustries.Optimizer;

static class WindowsFeatures
{
    public static TweakControlRead Read(ControlAddress address)
    {
        if (address.Target != "system" || address.Property != "features") throw new InvalidDataException("Unknown Windows feature target.");
        Check(DismInitialize(0, IntPtr.Zero, IntPtr.Zero), "DismInitialize");
        uint session = 0; var opened = false;
        try
        {
            Check(DismOpenSession("DISM_{53BFAE52-B167-4E2F-A258-0A37B57FF845}", IntPtr.Zero, IntPtr.Zero, out session), "DismOpenSession"); opened = true;
            Check(DismGetFeatures(session, IntPtr.Zero, 0, out var pointer, out var count), "DismGetFeatures");
            var features = Values(pointer, count);
            var states = new Dictionary<string, string>(StringComparer.Ordinal);
            var pending = false;
            foreach (var feature in features)
            {
                states.Add(feature.Name, feature.State switch
                {
                    2 => "Disabled", 3 => "DisabledWithPayloadRemoved", 4 => "Enabled",
                    5 => "Enabled", 1 => "Disabled",
                    _ => throw new InvalidDataException("Windows feature state cannot be reviewed: " + feature.Name + " (" + feature.State + ")."),
                });
                pending |= feature.State is 1 or 5;
            }
            var parents = new Dictionary<string, string[]>(StringComparer.Ordinal);
            foreach (var name in states.Keys.Where(name => name.StartsWith("Microsoft-Hyper-V", StringComparison.Ordinal) || name is "HypervisorPlatform" or "VirtualMachinePlatform" or "Recall" or "Containers-DisposableClientVM"))
            {
                Check(DismGetFeatureParent(session, name, IntPtr.Zero, 0, out pointer, out count), "DismGetFeatureParent(" + name + ")");
                parents.Add(name, Values(pointer, count).Select(feature => feature.Name).Order(StringComparer.Ordinal).ToArray());
            }
            return new(address, address.Key, OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(parents)), ControlValues.From(states),
                "Windows optional features", Parents: parents, RestartPending: pending);
        }
        finally
        {
            var close = opened ? DismCloseSession(session) : 0;
            var shutdown = DismShutdown();
            Check(close, "DismCloseSession"); Check(shutdown, "DismShutdown");
        }
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        if (before.RestartPending) throw new InvalidDataException("Restart Windows before changing pending features.");
        var changes = desired.EnumerateObject().Where(property => !ControlValues.Equal(property.Value, before.Value.GetProperty(property.Name))).ToArray();
        if (changes.Any(property => property.Name.Contains(';') || property.Value.GetString() is not ("Enabled" or "Disabled" or "DisabledWithPayloadRemoved"))) throw new InvalidDataException("Invalid Windows feature selection.");
        Check(DismInitialize(0, IntPtr.Zero, IntPtr.Zero), "DismInitialize");
        uint session = 0; var opened = false;
        try
        {
            Check(DismOpenSession("DISM_{53BFAE52-B167-4E2F-A258-0A37B57FF845}", IntPtr.Zero, IntPtr.Zero, out session), "DismOpenSession"); opened = true;
            foreach (var state in new[] { "Disabled", "DisabledWithPayloadRemoved", "Enabled" })
            {
                var names = changes.Where(property => property.Value.GetString() == state).Select(property => property.Name).ToArray();
                if (names.Length == 0) continue;
                var result = state == "Enabled"
                    ? DismEnableFeature(session, string.Join(';', names), IntPtr.Zero, 0, false, IntPtr.Zero, 0, true, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero)
                    : DismDisableFeature(session, string.Join(';', names), IntPtr.Zero, state == "DisabledWithPayloadRemoved", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (result != 0 && result != 3010 && result != 1) Check(result, "DISM feature change");
                if (result == 1)
                {
                    Check(DismCloseSession(session), "DismCloseSession(reload)"); opened = false;
                    Check(DismOpenSession("DISM_{53BFAE52-B167-4E2F-A258-0A37B57FF845}", IntPtr.Zero, IntPtr.Zero, out session), "DismOpenSession(reload)"); opened = true;
                }
            }
        }
        finally
        {
            var close = opened ? DismCloseSession(session) : 0; var shutdown = DismShutdown();
            Check(close, "DismCloseSession"); Check(shutdown, "DismShutdown");
        }
    }
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
        finally { if (pointer != IntPtr.Zero) Check(DismDelete(pointer), "DismDelete"); }
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
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct Feature { public IntPtr Name; public int State; }
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismInitialize(int level, IntPtr log, IntPtr scratch);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismOpenSession(string image, IntPtr windows, IntPtr drive, out uint session);
    [DllImport("DismApi.dll")] private static extern int DismGetFeatures(uint session, IntPtr identifier, int packageKind, out IntPtr features, out uint count);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismGetFeatureParent(uint session, string feature, IntPtr identifier, int packageKind, out IntPtr features, out uint count);
    [DllImport("DismApi.dll")] private static extern int DismDelete(IntPtr memory);
    [DllImport("DismApi.dll")] private static extern int DismCloseSession(uint session);
    [DllImport("DismApi.dll")] private static extern int DismShutdown();
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismEnableFeature(uint session, string feature, IntPtr identifier, int packageKind, [MarshalAs(UnmanagedType.Bool)] bool limitAccess, IntPtr sources, uint sourceCount, [MarshalAs(UnmanagedType.Bool)] bool enableAll, IntPtr cancel, IntPtr progress, IntPtr data);
    [DllImport("DismApi.dll", CharSet = CharSet.Unicode)] private static extern int DismDisableFeature(uint session, string feature, IntPtr package, [MarshalAs(UnmanagedType.Bool)] bool removePayload, IntPtr cancel, IntPtr progress, IntPtr data);
}
