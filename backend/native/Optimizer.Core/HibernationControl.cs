#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

static class HibernationControl
{
    private static readonly Dictionary<string, (string Path, string Name)> Values = new()
    {
        ["sizePercent"] = (@"SYSTEM\CurrentControlSet\Control\Power", "HiberFileSizePercent"),
        ["configuredType"] = (@"SYSTEM\CurrentControlSet\Control\Power", "HiberFileType"),
        ["enabled"] = (@"SYSTEM\CurrentControlSet\Control\Power", "HibernateEnabled"),
        ["defaultEnabled"] = (@"SYSTEM\CurrentControlSet\Control\Power", "HibernateEnabledDefault"),
        ["fastStartup"] = (@"SYSTEM\CurrentControlSet\Control\Session Manager\Power", "HiberbootEnabled"),
    };
    public static TweakControlRead Read(ControlAddress address)
    {
        if (address.Target != "system" || address.Property != "configuration") throw new InvalidDataException("Unknown hibernation target.");
        var caps = new byte[76];
        if (!GetPwrCapabilities(caps)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetPwrCapabilities failed.");
        if (caps[8] != 0 && caps[22] is not (1 or 2)) throw new InvalidDataException("The hibernation file type is unknown.");
        var state = new Dictionary<string, object?> { ["mode"] = caps[8] == 0 ? "Off" : caps[22] == 1 ? "Reduced" : "Full" };
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        foreach (var entry in Values)
        {
            using var key = machine.OpenSubKey(entry.Value.Path) ?? throw new InvalidDataException("A Windows power configuration key is missing.");
            var value = key.GetValue(entry.Value.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (value is not null && key.GetValueKind(entry.Value.Name) != RegistryValueKind.DWord) throw new InvalidDataException("This power configuration type cannot be restored by the hibernation control: " + entry.Value.Name);
            state.Add(entry.Key, value is null ? null : unchecked((uint)(int)value));
        }
        var snapshot = ControlValues.From(state);
        Validate(snapshot);
        return new(address, address.Key, "power-capabilities:s4=" + (caps[6] != 0), snapshot, "Hibernation");
    }
    public static void Validate(JsonElement value)
    {
        var mode = value.GetProperty("mode").GetString();
        if (mode is not ("Off" or "Full" or "Reduced")) throw new InvalidDataException("Unknown hibernation mode.");
        foreach (var name in Values.Keys)
            if (value.GetProperty(name).ValueKind != JsonValueKind.Null) _ = value.GetProperty(name).GetUInt32();
        if (mode == "Full" && value.GetProperty("sizePercent").ValueKind != JsonValueKind.Null)
        {
            var percent = value.GetProperty("sizePercent").GetUInt32();
            if (percent > 100 || percent is > 0 and < 40) throw new InvalidDataException("The captured full-hibernation size cannot be reproduced with powercfg.");
        }
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        Validate(before.Value);
        Validate(desired);
        var mode = desired.GetProperty("mode").GetString();
        if (mode == "Full" && before.Binding != "power-capabilities:s4=True") throw new InvalidDataException("This PC does not expose full hibernation support.");
        var modeChanged = before.Value.GetProperty("mode").GetString() != mode;
        var sizeChanged = !ControlValues.Equal(before.Value.GetProperty("sizePercent"), desired.GetProperty("sizePercent"));
        if (modeChanged && mode == "Off") Run("/hibernate", "off");
        else if (mode != "Off" && (modeChanged || sizeChanged))
        {
            Run("/hibernate", "on");
            if (mode == "Reduced") { Run("/hibernate", "/size", "0"); Run("/hibernate", "/type", "reduced"); }
            else
            {
                Run("/hibernate", "/type", "full");
                if (desired.GetProperty("sizePercent").ValueKind != JsonValueKind.Null)
                {
                    var percent = desired.GetProperty("sizePercent").GetUInt32();
                    Run("/hibernate", "/size", percent.ToString(System.Globalization.CultureInfo.InvariantCulture));
                }
            }
        }
        using var transaction = RegistryTransaction.Begin();
        foreach (var entry in Values)
        {
            var address = new RegistryAddress("LocalMachine", "Registry64", entry.Value.Path, "value", entry.Value.Name);
            var original = RegistryNative.ReadTweak(address, transaction);
            var value = desired.GetProperty(entry.Key);
            RegistryValueData? after = value.ValueKind == JsonValueKind.Null ? null : new(entry.Value.Name, 4, BitConverter.GetBytes(value.GetUInt32()));
            if (!TweakRead.SameValue(original.Value, after)) RegistryNative.SetTweak(address, original.NativeKey, after, transaction);
        }
        transaction.Commit();
    }
    private static void Run(params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "powercfg.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Powercfg could not start.");
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        process.WaitForExit(); Task.WaitAll(output, error);
        if (process.ExitCode != 0) throw new IOException("powercfg " + string.Join(' ', arguments) + " exited " + process.ExitCode + ": " + output.Result.Trim() + " " + error.Result.Trim());
    }
    [DllImport("powrprof.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool GetPwrCapabilities([Out] byte[] value);
}
