#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class PowerSchemes
{
    private sealed record Value(string Group, string Setting, string Channel, uint Status, uint Type, string? Data);
    private sealed class NativeGuid(Guid value) : IDisposable
    {
        public IntPtr Pointer { get; } = Allocate(value);
        private static IntPtr Allocate(Guid value) { var pointer = Marshal.AllocHGlobal(16); Marshal.StructureToPtr(value, pointer, false); return pointer; }
        public void Dispose() => Marshal.FreeHGlobal(Pointer);
    }
    public static Guid Active()
    {
        var code = PowerGetActiveScheme(IntPtr.Zero, out var pointer);
        try { Check(code, "PowerGetActiveScheme"); return pointer == IntPtr.Zero ? throw new InvalidDataException("The active power scheme identity is missing.") : Marshal.PtrToStructure<Guid>(pointer); }
        finally { if (pointer != IntPtr.Zero) LocalFree(pointer); }
    }
    public static Guid[] Schemes() => Enumerate(IntPtr.Zero, IntPtr.Zero, 16);
    private static Guid[] Enumerate(IntPtr scheme, IntPtr subgroup, uint access)
    {
        var values = new HashSet<Guid>();
        for (uint index = 0; index < 4096; index++)
        {
            var buffer = new byte[16]; uint size = 16;
            var code = PowerEnumerate(IntPtr.Zero, scheme, subgroup, access, index, buffer, ref size);
            if (code == 259) return values.Order().ToArray();
            Check(code, "PowerEnumerate(" + access + ")");
            if (size != 16 || !values.Add(new(buffer))) throw new InvalidDataException("Power scheme enumeration returned an invalid identity.");
        }
        throw new InvalidDataException("Power scheme enumeration exceeded its limit.");
    }
    public static string Fingerprint(Guid id)
    {
        using var scheme = new NativeGuid(id); var values = new List<Value>();
        void Metadata(string group, string setting, IntPtr groupPointer, IntPtr settingPointer)
        {
            foreach (var channel in new[] { "name", "description", "icon" }) values.Add(Read(group, setting, channel, scheme.Pointer, groupPointer, settingPointer));
        }
        Metadata("", "", IntPtr.Zero, IntPtr.Zero);
        var groups = Enumerate(scheme.Pointer, IntPtr.Zero, 17).Append(new("fea3413e-7e05-4911-9a71-700331f1c294")).Distinct().Order();
        foreach (var groupId in groups)
        {
            using var group = new NativeGuid(groupId); var groupName = groupId.ToString("D");
            Metadata(groupName, "", group.Pointer, IntPtr.Zero);
            foreach (var settingId in Enumerate(scheme.Pointer, group.Pointer, 18))
            {
                using var setting = new NativeGuid(settingId); var settingName = settingId.ToString("D");
                Metadata(groupName, settingName, group.Pointer, setting.Pointer);
                foreach (var channel in new[] { "ac", "dc" }) values.Add(Read(groupName, settingName, channel, scheme.Pointer, group.Pointer, setting.Pointer));
            }
        }
        return OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(values.OrderBy(value => value.Group + "|" + value.Setting + "|" + value.Channel, StringComparer.Ordinal)));
    }
    private static Value Read(string groupId, string settingId, string channel, IntPtr scheme, IntPtr group, IntPtr setting)
    {
        uint size = 0;
        var code = Call(channel, scheme, group, setting, out var type, null, ref size);
        if (code == 2 && channel is not ("ac" or "dc")) return new(groupId, settingId, channel, code, type, null);
        if (code is not (0 or 234)) Check(code, "PowerRead(" + channel + ")");
        for (var retry = 0; retry < 4; retry++)
        {
            if (size > 1048576) throw new InvalidDataException("Power scheme metadata exceeded its size limit.");
            var bytes = new byte[size]; var capacity = size;
            code = Call(channel, scheme, group, setting, out type, bytes, ref size);
            if (code == 234 || code == 0 && size > capacity) continue;
            Check(code, "PowerRead(" + channel + ")");
            return new(groupId, settingId, channel, code, type, Convert.ToBase64String(bytes, 0, checked((int)size)));
        }
        throw new InvalidDataException("Power settings changed repeatedly during inspection.");
    }
    private static uint Call(string channel, IntPtr scheme, IntPtr group, IntPtr setting, out uint type, byte[]? buffer, ref uint size)
    {
        type = 0;
        return channel switch
        {
            "name" => PowerReadFriendlyName(IntPtr.Zero, scheme, group, setting, buffer, ref size),
            "description" => PowerReadDescription(IntPtr.Zero, scheme, group, setting, buffer, ref size),
            "icon" => PowerReadIconResourceSpecifier(IntPtr.Zero, scheme, group, setting, buffer, ref size),
            "ac" => PowerReadACValue(IntPtr.Zero, scheme, group, setting, out type, buffer, ref size),
            "dc" => PowerReadDCValue(IntPtr.Zero, scheme, group, setting, out type, buffer, ref size),
            _ => throw new InvalidDataException("Unknown power setting field."),
        };
    }
    public static void Select(Guid id) { Check(PowerSetActiveScheme(IntPtr.Zero, ref id), "PowerSetActiveScheme"); if (Active() != id) throw new IOException("The active power scheme did not match the requested identity."); }
    public static void Delete(Guid id) { if (Active() == id) throw new InvalidDataException("An active power scheme cannot be removed."); Check(PowerDeleteScheme(IntPtr.Zero, ref id), "PowerDeleteScheme"); if (Schemes().Contains(id)) throw new IOException("The owned power scheme remains after deletion."); }
    public static void Duplicate(Guid source, Guid destination)
    {
        using var memory = new NativeGuid(destination); var pointer = memory.Pointer;
        Check(PowerDuplicateScheme(IntPtr.Zero, ref source, ref pointer), "PowerDuplicateScheme");
        if (pointer != memory.Pointer || Marshal.PtrToStructure<Guid>(pointer) != destination) throw new InvalidDataException("Power duplication returned an unexpected destination; review its retained creation intent.");
    }
    private static void Check(uint code, string api) { if (code != 0) throw new Win32Exception((int)code, api + " failed with Win32 " + code); }
    [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr active);
    [DllImport("powrprof.dll")] private static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerDeleteScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerDuplicateScheme(IntPtr root, ref Guid source, ref IntPtr destination);
    [DllImport("powrprof.dll")] private static extern uint PowerEnumerate(IntPtr root, IntPtr scheme, IntPtr subgroup, uint access, uint index, byte[] bytes, ref uint size);
    [DllImport("powrprof.dll")] private static extern uint PowerReadFriendlyName(IntPtr root, IntPtr scheme, IntPtr subgroup, IntPtr setting, byte[]? bytes, ref uint size);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDescription(IntPtr root, IntPtr scheme, IntPtr subgroup, IntPtr setting, byte[]? bytes, ref uint size);
    [DllImport("powrprof.dll")] private static extern uint PowerReadIconResourceSpecifier(IntPtr root, IntPtr scheme, IntPtr subgroup, IntPtr setting, byte[]? bytes, ref uint size);
    [DllImport("powrprof.dll")] private static extern uint PowerReadACValue(IntPtr root, IntPtr scheme, IntPtr subgroup, IntPtr setting, out uint type, byte[]? bytes, ref uint size);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDCValue(IntPtr root, IntPtr scheme, IntPtr subgroup, IntPtr setting, out uint type, byte[]? bytes, ref uint size);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
}
