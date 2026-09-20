#nullable enable
using Microsoft.Win32;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record RegistrySelection([property: JsonRequired] int Depth, [property: JsonRequired] string Suffix,
    [property: JsonRequired] string Filter, [property: JsonRequired] bool ExistingValuesOnly, string? TargetRoot = null)
{
    public void Validate()
    {
        if (Depth is < 1 or > 3 || Suffix.Contains('/') || Suffix.Contains('\0') || Suffix.Split('\\').Any(part => part is "." or "..") ||
            Filter is not ("all" or "primary-interfaces" or "primary-network-devices" or "network-devices" or "device-classes" or "existing-suffix")) throw new InvalidDataException("Unknown device registry selection.");
    }
}

public static class RegistrySelections
{
    public static TweakAssignment[] Resolve(TweakAssignment assignment, Func<RegistryAddress, string[]> children, Func<RegistryAddress, TweakRead> read, Func<string[]> interfaces)
    {
        if (assignment.Selector is not { } selector) return [assignment];
        selector.Validate();
        var paths = new[] { assignment.Address.KeyPath };
        for (var level = 0; level < selector.Depth; level++)
        {
            paths = paths.SelectMany(path => children(assignment.Address with { KeyPath = path }).Select(name => path + "\\" + name)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (paths.Length > 2048) throw new InvalidDataException("The device selection exceeds 2048 registry targets.");
        }
        var ids = selector.Filter is "primary-interfaces" or "primary-network-devices" ? interfaces().ToHashSet(StringComparer.OrdinalIgnoreCase) : [];
        if (selector.Filter is "primary-interfaces" or "primary-network-devices" && ids.Count == 0) throw new InvalidDataException("No active network interface with a default gateway was found.");
        if (selector.TargetRoot is not null) TweakRead.ValidateAddress(assignment.Address with { KeyPath = selector.TargetRoot });
        var result = new List<TweakAssignment>();
        foreach (var path in paths.Order(StringComparer.OrdinalIgnoreCase))
        {
            var name = path[(path.LastIndexOf('\\') + 1)..];
            if (selector.Filter is "primary-network-devices" or "network-devices" or "device-classes" && (name.Length != 4 || !name.All(char.IsDigit))) continue;
            if (selector.Filter == "primary-interfaces" && !ids.Contains(NormalizeInterface(name))) continue;
            if (selector.Filter == "primary-network-devices")
            {
                var device = read(assignment.Address with { KeyPath = path, ValueName = "NetCfgInstanceId" }).Value;
                if (device?.Type != 1 || !ids.Contains(NormalizeInterface(Encoding.Unicode.GetString(device.Bytes).TrimEnd('\0')))) continue;
            }
            if (selector.Filter == "network-devices")
            {
                var description = read(assignment.Address with { KeyPath = path, ValueName = "DriverDesc" }).Value;
                var text = description?.Type is 1 or 2 ? Encoding.Unicode.GetString(description.Bytes).TrimEnd('\0') : "";
                if (text.Length == 0 || new[] { "wan miniport", "kernel debug", "virtual", "loopback", "teredo", "isatap", "6to4", "bluetooth" }.Any(text.ContainsIgnoreCase)) continue;
            }
            var address = assignment.Address with { KeyPath = (selector.TargetRoot is null ? path : selector.TargetRoot + "\\" + name) + (selector.Suffix.Length == 0 ? "" : "\\" + selector.Suffix) };
            var observed = read(address);
            if (selector.Filter == "existing-suffix" && !observed.KeyExists || selector.ExistingValuesOnly && observed.Value is null) continue;
            result.Add(assignment with { Address = address, Selector = null });
        }
        if (result.Count == 0) throw new InvalidDataException("No devices expose this setting.");
        return result.ToArray();
    }
    private static bool ContainsIgnoreCase(this string text, string value) => text.Contains(value, StringComparison.OrdinalIgnoreCase);
    public static string NormalizeInterface(string value) => (value.StartsWith("Tcpip_", StringComparison.OrdinalIgnoreCase) ? value[6..] : value).Trim('{', '}').ToUpperInvariant();
    public static string[] PrimaryInterfaces() => NetworkInterface.GetAllNetworkInterfaces().Where(adapter => adapter.OperationalStatus == OperationalStatus.Up &&
        adapter.GetIPProperties().GatewayAddresses.Any(gateway => gateway.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !gateway.Address.Equals(System.Net.IPAddress.Any)))
        .Select(adapter => NormalizeInterface(adapter.Id)).Distinct().ToArray();
    public static string[] Children(RegistryAddress address)
    {
        TweakRead.ValidateAddress(address);
        using var root = RegistryKey.OpenBaseKey(address.Hive switch { "CurrentUser" => RegistryHive.CurrentUser, "LocalMachine" => RegistryHive.LocalMachine, "Users" => RegistryHive.Users, _ => throw new InvalidDataException("Unknown registry hive.") },
            address.View == "Registry64" ? RegistryView.Registry64 : RegistryView.Registry32);
        using var key = root.OpenSubKey(address.KeyPath, false);
        return key?.GetSubKeyNames() ?? [];
    }
}
