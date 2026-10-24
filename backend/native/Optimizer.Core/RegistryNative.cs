#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public sealed class RegistryApiException(string api, int status) : Win32Exception(status, api + " failed with registry status " + status + ": " + new Win32Exception(status).Message)
{
    public string Api { get; } = api;
}

public sealed class RegistryTransaction : SafeHandleZeroOrMinusOneIsInvalid
{
    private RegistryTransaction() : base(true) { }
    public static RegistryTransaction Begin()
    {
        var transaction = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 60000, "Reviewed application cleanup");
        if (transaction.IsInvalid) { var error = Marshal.GetLastWin32Error(); transaction.Dispose(); throw new Win32Exception(error, "CreateTransaction failed: " + error); }
        return transaction;
    }
    public void Commit()
    {
        if (!CommitTransaction(this)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Registry transaction commit failed.");
    }
    public void Rollback()
    {
        if (!RollbackTransaction(this)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Registry transaction rollback failed.");
    }
    protected override bool ReleaseHandle() => CloseHandle(handle);
    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern RegistryTransaction CreateTransaction(IntPtr attributes, IntPtr guid, uint options, uint isolation, uint isolationFlags, uint timeout, string description);
    [DllImport("ktmw32.dll", SetLastError = true)] private static extern bool CommitTransaction(RegistryTransaction transaction);
    [DllImport("ktmw32.dll", SetLastError = true)] private static extern bool RollbackTransaction(RegistryTransaction transaction);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
}

public static partial class RegistryNative
{
    private const uint Query = 1, SetValue = 2, CreateSubKey = 4, Enumerate = 8, Delete = 0x10000, ReadControl = 0x20000, WriteDacl = 0x40000, WriteOwner = 0x80000;
    private const uint Read = Query | Enumerate | ReadControl;
    private const uint Change = Read | SetValue | CreateSubKey | Delete;
    internal static Func<SafeRegistryHandle>? MachineRoot;
    private const uint OpenLink = 8;

    public static SafeRegistryHandle? OpenRead(RegistryAddress address)
    {
        if (address.KeyPath != "Software") address.Validate();
        else if (address.Hive is not ("CurrentUser" or "LocalMachine") || address.View is not ("Registry32" or "Registry64") || address.Kind != "key")
            throw new InvalidDataException("Invalid Software registry scope.");
        return Open(address, Query | Enumerate, null);
    }

    public static string KeyName(RegistryAddress address)
    {
        using var key = OpenRead(address) ?? throw new InvalidDataException("Registry identity parent is missing.");
        return NativeName(key);
    }

    internal static SafeRegistryHandle? OpenReadChild(SafeRegistryHandle parent, string name, string view)
    {
        if (string.IsNullOrEmpty(name) || name.Contains('\\') || !RegistryAddress.SerializableName(name)) throw new InvalidDataException("Invalid registry child name.");
        var key = OpenChild(parent, name, Query | Enumerate, view, null);
        try { if (key is not null) RejectLink(key); return key; }
        catch { key?.Dispose(); throw; }
    }

    public static RegistrySnapshot Capture(RegistryAddress address, RegistryTransaction? transaction = null)
    {
        address.Validate();
        using var key = Open(address, Read, transaction);
        if (key is null) return new(address, false, null);
        var budget = new ReadBudget();
        var node = ReadNode(key, address.KeyPath.Split('\\')[^1], address.View, transaction, address.Kind == "key", address.ValueName, budget, 0);
        if (address.Kind == "value" && node.Values.Length == 0) return new(address, false, node);
        return new(address, true, node);
    }

    public static void DeleteReviewed(RegistrySnapshot reviewed, RegistryTransaction transaction)
    {
        reviewed.Address.RequireDeletionScope();
        if (!reviewed.Exists || reviewed.Node is null) throw new InvalidDataException("Only an existing reviewed registry resource can be deleted.");
        using var key = Open(reviewed.Address, Change, transaction) ?? throw new InvalidDataException("The reviewed registry key disappeared.");
        var current = new RegistrySnapshot(reviewed.Address, true, ReadNode(key, reviewed.Node.Name, reviewed.Address.View, transaction,
            reviewed.Address.Kind == "key", reviewed.Address.ValueName, new(), 0));
        if (current.Digest(true) != reviewed.Digest(true)) throw new InvalidDataException("The registry resource changed after review.");
        if (reviewed.Address.Kind == "value")
        {
            Check(RegDeleteValue(key, reviewed.Address.ValueName!), "RegDeleteValue");
            return;
        }
        DeleteChildren(key, reviewed.Node, reviewed.Address.View, transaction);
        var separator = reviewed.Address.KeyPath.LastIndexOf('\\');
        var parentAddress = reviewed.Address with { KeyPath = reviewed.Address.KeyPath[..separator], Kind = "key", ValueName = null };
        using var parent = Open(parentAddress, Change, transaction) ?? throw new InvalidDataException("Registry parent disappeared.");
        Check(RegDeleteKeyTransacted(parent, reviewed.Node.Name, ViewFlag(reviewed.Address.View), 0, transaction, IntPtr.Zero), "RegDeleteKeyTransacted");
    }

    public static void RestoreReviewed(RegistrySnapshot original, RegistryTransaction transaction)
    {
        original.Address.RequireDeletionScope();
        if (!original.Exists || original.Node is null) throw new InvalidDataException("The registry backup has no original resource.");
        if (original.Address.Kind == "value")
        {
            using var key = Open(original.Address, Change, transaction) ?? throw new InvalidDataException("The value's parent key is missing; its metadata was not backed up as a key.");
            VerifyName(key, original.Node.NativeName);
            var value = ReadValue(key, original.Address.ValueName!);
            var expected = original.Node.Values.Single();
            if (value is not null)
            {
                if (!SameValue(value, expected)) throw new InvalidDataException("A new registry value occupies the restore destination.");
                return;
            }
            WriteValue(key, expected);
            return;
        }
        var current = Capture(original.Address, transaction);
        if (current.Exists)
        {
            if (current.Digest(false) != original.Digest(false)) throw new InvalidDataException("New registry data occupies the restore destination.");
            return;
        }
        var separator = original.Address.KeyPath.LastIndexOf('\\');
        var parentAddress = original.Address with { KeyPath = original.Address.KeyPath[..separator], Kind = "key", ValueName = null };
        using var parent = Open(parentAddress, Change, transaction) ?? throw new InvalidDataException("The original registry parent is missing.");
        CreateNode(parent, original.Node, original.Address.View, transaction);
        var restored = Capture(original.Address, transaction);
        if (restored.Digest(false) != original.Digest(false)) throw new InvalidDataException("Registry restoration did not reproduce the captured data and permissions.");
    }

    public static void WriteReceipt(RegistryAddress address, string parentNativeName, byte[] bytes, RegistryTransaction transaction, bool mustCreate)
    {
        address.Validate();
        var separator = address.KeyPath.LastIndexOf('\\');
        var parentAddress = address with { KeyPath = address.KeyPath[..separator], Kind = "key", ValueName = null };
        using var parent = Open(parentAddress, Change, transaction) ?? throw new InvalidDataException("The operation receipt parent is missing.");
        VerifyName(parent, parentNativeName);
        Check(RegCreateKeyTransacted(parent, address.KeyPath[(separator + 1)..], 0, null, 0, Change | ViewFlag(address.View), IntPtr.Zero,
            out var key, out var disposition, transaction, IntPtr.Zero), "RegCreateKeyTransacted(receipt)");
        using (key)
        {
            if (mustCreate && disposition != 1) throw new InvalidDataException("The operation receipt already exists.");
            var expected = NativeName(parent) + "\\" + address.KeyPath[(separator + 1)..];
            VerifyName(key, expected);
            WriteValue(key, new("state", 3, bytes));
        }
    }

    public static byte[]? ReadReceipt(RegistryAddress address, string parentNativeName)
    {
        using var key = Open(address, Read, null);
        if (key is null) return null;
        VerifyName(key, parentNativeName + "\\" + address.KeyPath.Split('\\')[^1]);
        var value = ReadValue(key, "state") ?? throw new InvalidDataException("The registry operation receipt is incomplete.");
        if (value.Type != 3) throw new InvalidDataException("The registry operation receipt has the wrong type.");
        return value.Bytes;
    }

    public static bool SameValue(RegistryValueData first, RegistryValueData second)
        => string.Equals(first.Name, second.Name, StringComparison.OrdinalIgnoreCase) && first.Type == second.Type && first.Bytes.SequenceEqual(second.Bytes);

    private static RegistryNode ReadNode(SafeRegistryHandle key, string name, string view, RegistryTransaction? transaction,
        bool recursive, string? selectedValue, ReadBudget budget, int depth)
    {
        if (++budget.Keys > 20000 || depth > 64) throw new InvalidDataException("Registry capture exceeded its key or depth limit.");
        RejectLink(key);
        var info = ReadInfo(key);
        var nativeName = NativeName(key);
        var values = new List<RegistryValueData>();
        if (selectedValue is not null)
        {
            var value = ReadValue(key, selectedValue);
            if (value is not null) values.Add(value);
        }
        else
        {
            for (uint index = 0; ; index++)
            {
                var buffer = new StringBuilder(16384);
                uint length = (uint)buffer.Capacity;
                var result = RegEnumValue(key, index, buffer, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (result == 259) break;
                Check(result, "RegEnumValue");
                values.Add(ReadValue(key, buffer.ToString()) ?? throw new InvalidDataException("Registry value changed during capture."));
            }
        }
        foreach (var value in values)
        {
            budget.Bytes += value.Bytes.LongLength;
            if (++budget.Values > 100000 || budget.Bytes > 128 * 1024 * 1024) throw new InvalidDataException("Registry value capture exceeded its resource limit.");
        }
        var children = new List<RegistryNode>();
        if (recursive)
        {
            for (uint index = 0; ; index++)
            {
                var buffer = new StringBuilder(256);
                uint length = (uint)buffer.Capacity;
                var result = RegEnumKeyEx(key, index, buffer, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (result == 259) break;
                Check(result, "RegEnumKeyEx");
                using var child = OpenChild(key, buffer.ToString(), Read, view, transaction) ?? throw new InvalidDataException("Registry child changed during capture.");
                var node = ReadNode(child, buffer.ToString(), view, transaction, true, null, budget, depth + 1);
                if (transaction is not null && !node.NativeName.StartsWith(nativeName + "\\", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("A registry child resolved outside its reviewed parent.");
                children.Add(node);
            }
        }
        var security = recursive ? ReadSecurity(key) : null;
        if (ReadInfo(key).LastWrite != info.LastWrite) throw new InvalidDataException("Registry data changed during capture.");
        return new(nativeName, name, info.Class, info.LastWrite, recursive ? 7u : 0u, security,
            values.OrderBy(value => value.Name, StringComparer.OrdinalIgnoreCase).ToArray(), children.OrderBy(child => child.Name, StringComparer.OrdinalIgnoreCase).ToArray());
    }

    private static void DeleteChildren(SafeRegistryHandle parent, RegistryNode node, string view, RegistryTransaction transaction)
    {
        VerifyName(parent, node.NativeName);
        foreach (var childNode in node.Children)
        {
            using var child = OpenChild(parent, childNode.Name, Change, view, transaction) ?? throw new InvalidDataException("Registry child disappeared.");
            DeleteChildren(child, childNode, view, transaction);
            Check(RegDeleteKeyTransacted(parent, childNode.Name, ViewFlag(view), 0, transaction, IntPtr.Zero), "RegDeleteKeyTransacted");
        }
    }

    private static void CreateNode(SafeRegistryHandle parent, RegistryNode node, string view, RegistryTransaction transaction)
    {
        Check(RegCreateKeyTransacted(parent, node.Name, 0, node.Class, 0, Change | WriteDacl | WriteOwner | ViewFlag(view), IntPtr.Zero,
            out var key, out var disposition, transaction, IntPtr.Zero), "RegCreateKeyTransacted");
        using (key)
        {
            if (disposition != 1) throw new InvalidDataException("A new key occupies the registry restore destination.");
            VerifyName(key, node.NativeName);
            foreach (var value in node.Values) WriteValue(key, value);
            foreach (var child in node.Children) CreateNode(key, child, view, transaction);
            if (node.SecurityCoverage != 7 || node.Security is null) throw new InvalidDataException("Registry permission backup is incomplete.");
            WindowsPermissions.Restore(key, 4, node.Security);
        }
    }

    private static void WriteValue(SafeRegistryHandle key, RegistryValueData value)
    {
        if (!value.Recoverable) throw new InvalidDataException("This raw registry representation has no supported restoration contract.");
        Check(RegSetValueEx(key, value.Name, 0, value.Type, value.Bytes, (uint)value.Bytes.Length), "RegSetValueEx");
        if (!SameValue(ReadValue(key, value.Name) ?? throw new InvalidDataException("Registry value readback is missing."), value))
            throw new InvalidDataException("Registry value readback differs from the saved raw data.");
    }

    private static SafeRegistryHandle? Open(RegistryAddress address, uint access, RegistryTransaction? transaction)
    {
        using var root = OpenRoot(address.Hive);
        if (transaction is not null)
        {
            var result = RegOpenKeyTransacted(root, address.KeyPath, 0, access | ViewFlag(address.View), out var key, transaction, IntPtr.Zero);
            if (result is 2 or 3) { key?.Dispose(); return null; }
            Check(result, "RegOpenKeyTransacted");
            return key;
        }
        SafeRegistryHandle? current = null;
        try
        {
            var parts = address.KeyPath.Split('\\');
            for (var index = 0; index < parts.Length; index++)
            {
                var next = OpenChild(current ?? root, parts[index], index == parts.Length - 1 ? access : Query | Enumerate, address.View, null);
                current?.Dispose(); current = next;
                if (current is null) return null;
                RejectLink(current);
            }
            var result = current; current = null; return result;
        }
        finally { current?.Dispose(); }
    }

    private static SafeRegistryHandle? OpenChild(SafeRegistryHandle parent, string name, uint access, string view, RegistryTransaction? transaction)
    {
        SafeRegistryHandle key;
        var result = transaction is null ? RegOpenKeyEx(parent, name, OpenLink, access | ViewFlag(view), out key)
            : RegOpenKeyTransacted(parent, name, 0, access | ViewFlag(view), out key, transaction, IntPtr.Zero);
        if (result is 2 or 3) { key?.Dispose(); return null; }
        Check(result, transaction is null ? "RegOpenKeyEx" : "RegOpenKeyTransacted");
        return key;
    }

    private static SafeRegistryHandle OpenRoot(string hive)
    {
        SafeRegistryHandle key;
        if (hive == "CurrentUser")
        {
            Check(RegOpenCurrentUser(Query | Enumerate, out key), "RegOpenCurrentUser");
            var expected = "\\REGISTRY\\USER\\" + OperationOwner.Current().UserSid;
            if (!string.Equals(NativeName(key), expected, StringComparison.OrdinalIgnoreCase)) { key.Dispose(); throw new InvalidDataException("The registry user root does not belong to the current SID."); }
        }
        else if (hive == "LocalMachine" && MachineRoot is { } machine) key = machine();
        else if (hive == "LocalMachine") Check(RegOpenKeyEx(new SafeRegistryHandle(new IntPtr(unchecked((int)0x80000002)), false), "", 0, Query | Enumerate, out key), "RegOpenKeyEx(HKLM)");
        else throw new InvalidDataException("Unsupported registry hive.");
        return key;
    }

    private static void RejectLink(SafeRegistryHandle key)
    {
        var symbolic = ReadValue(key, "SymbolicLinkValue");
        if (symbolic?.Type == 6) throw new InvalidDataException("Registry links remain read-only cleanup candidates.");
    }

    private static RegistryValueData? ReadValue(SafeRegistryHandle key, string name)
    {
        uint size = 0;
        var result = RegQueryValueEx(key, name, IntPtr.Zero, out var type, null, ref size);
        if (result == 2) return null;
        if (result != 234) Check(result, "RegQueryValueEx(size)");
        for (var attempt = 0; attempt < 4; attempt++)
        {
            if (size > 64 * 1024 * 1024) throw new InvalidDataException("Registry value is too large to back up in this operation.");
            var bytes = new byte[size];
            result = RegQueryValueEx(key, name, IntPtr.Zero, out type, bytes, ref size);
            if (result == 234) continue;
            Check(result, "RegQueryValueEx(data)");
            if (size > bytes.Length) throw new InvalidDataException("Registry value exceeded its returned buffer.");
            Array.Resize(ref bytes, (int)size);
            return new(name, type, bytes);
        }
        throw new InvalidDataException("Registry value changed repeatedly during capture.");
    }

    private static (string Class, string LastWrite) ReadInfo(SafeRegistryHandle key)
    {
        var capacity = 256;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            var name = new StringBuilder(capacity); uint length = (uint)name.Capacity;
            var status = RegQueryInfoKey(key, name, ref length, IntPtr.Zero, out _, out _, out _, out _, out _, out _, out _, out var time);
            if (status is 122 or 234)
            {
                if (length >= 32767) throw new InvalidDataException("Registry class exceeds the supported capture size.");
                capacity = Math.Max(capacity * 2, (int)length + 1);
                continue;
            }
            Check(status, "RegQueryInfoKey");
            if (length != name.Length) throw new InvalidDataException("Registry class contains an unsupported embedded terminator.");
            return (name.ToString(), time.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        throw new InvalidDataException("Registry class changed repeatedly during capture.");
    }

    private static byte[] ReadSecurity(SafeRegistryHandle key)
    {
        uint size = 0;
        var result = RegGetKeySecurity(key, 7, null, ref size);
        if (result != 122) Check(result, "RegGetKeySecurity(size)");
        if (size is 0 or > 1048576) throw new InvalidDataException("Registry security descriptor size is invalid.");
        var bytes = new byte[size];
        Check(RegGetKeySecurity(key, 7, bytes, ref size), "RegGetKeySecurity(data)");
        Array.Resize(ref bytes, (int)size);
        return bytes;
    }

    private static void VerifyName(SafeRegistryHandle key, string expected)
    {
        if (!string.Equals(NativeName(key), expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The registry handle resolved to another destination.");
    }

    internal static string NativeName(SafeRegistryHandle key)
    {
        var status = NtQueryKey(key, 3, IntPtr.Zero, 0, out var needed);
        if (status is not (0 or unchecked((int)0xC0000023) or unchecked((int)0x80000005)))
            throw new InvalidOperationException("NtQueryKey failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8"));
        if (needed < 4 || needed > 1024 * 1024) throw new InvalidDataException("Invalid native registry name size.");
        var buffer = Marshal.AllocHGlobal(needed);
        try
        {
            status = NtQueryKey(key, 3, buffer, needed, out var returned);
            if (status != 0) throw new InvalidOperationException("NtQueryKey failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8"));
            var length = Marshal.ReadInt32(buffer);
            if (returned > needed || length < 0 || length % 2 != 0 || length > needed - 4) throw new InvalidDataException("Invalid native registry name length.");
            return Marshal.PtrToStringUni(buffer + 4, length / 2)!;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static uint ViewFlag(string view) => view switch { "Registry32" => 0x200, "Registry64" => 0x100, _ => throw new InvalidDataException("Explicit registry view is required.") };
    private static void Check(int status, string api) { if (status != 0) throw new RegistryApiException(api, status); }
    private sealed class ReadBudget { public int Keys, Values; public long Bytes; }

    [DllImport("advapi32.dll")] private static extern int RegOpenCurrentUser(uint access, out SafeRegistryHandle key);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegOpenKeyEx(SafeRegistryHandle parent, string path, uint options, uint access, out SafeRegistryHandle key);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegOpenKeyTransacted(SafeRegistryHandle parent, string path, uint options, uint access, out SafeRegistryHandle key, RegistryTransaction transaction, IntPtr extended);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegCreateKeyTransacted(SafeRegistryHandle parent, string path, uint reserved, string? keyClass, uint options, uint access, IntPtr security, out SafeRegistryHandle key, out uint disposition, RegistryTransaction transaction, IntPtr extended);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegDeleteKeyTransacted(SafeRegistryHandle parent, string name, uint view, uint reserved, RegistryTransaction transaction, IntPtr extended);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegDeleteValue(SafeRegistryHandle key, string name);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegQueryValueEx(SafeRegistryHandle key, string name, IntPtr reserved, out uint type, [Out] byte[]? data, ref uint size);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegSetValueEx(SafeRegistryHandle key, string name, uint reserved, uint type, byte[] data, uint size);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegEnumValue(SafeRegistryHandle key, uint index, StringBuilder name, ref uint nameLength, IntPtr reserved, IntPtr type, IntPtr data, IntPtr dataSize);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegEnumKeyEx(SafeRegistryHandle key, uint index, StringBuilder name, ref uint nameLength, IntPtr reserved, IntPtr keyClass, IntPtr classLength, IntPtr lastWrite);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegQueryInfoKey(SafeRegistryHandle key, StringBuilder keyClass, ref uint classLength, IntPtr reserved, out uint subkeys, out uint maxSubkey, out uint maxClass, out uint values, out uint maxValueName, out uint maxValueData, out uint securitySize, out long lastWrite);
    [DllImport("advapi32.dll")] private static extern int RegGetKeySecurity(SafeRegistryHandle key, uint information, [Out] byte[]? descriptor, ref uint size);
    [DllImport("ntdll.dll")] private static extern int NtQueryKey(SafeRegistryHandle key, int informationClass, IntPtr data, int size, out int returned);
}
