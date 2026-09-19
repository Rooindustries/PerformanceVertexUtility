#nullable enable
using Microsoft.Win32;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed record LaunchPrioritySnapshot
{
    public required bool ImageKeyExisted { get; init; }
    public required bool OptionsKeyExisted { get; init; }
    public required Dictionary<string, int?> Values { get; init; }
}

public sealed class LaunchPriorities
{
    private const string Root = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options";
    private readonly string _image;
    private readonly Dictionary<string, int> _values;
    public LaunchPriorities(string executable, Dictionary<string, JsonElement> controls)
    {
        _image = Path.GetFileName(executable);
        if (string.IsNullOrWhiteSpace(_image) || _image.IndexOfAny(['\\', '/', ':']) >= 0 || !_image.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Launch priorities require an executable filename.");
        _values = [];
        if (controls.TryGetValue("cpuPriority", out var cpu)) _values.Add("CpuPriorityClass", cpu.GetString() switch
        { "Idle" => 1, "Normal" => 2, "High" => 3, "BelowNormal" => 5, "AboveNormal" => 6, _ => throw new InvalidDataException("This launch policy does not support real-time CPU priority.") });
        if (controls.TryGetValue("ioPriority", out var io))
        {
            var value = io.GetInt32(); if (value is < 0 or > 2) throw new InvalidDataException("Launch-time I/O priority supports Very Low, Low and Normal.");
            _values.Add("IoPriority", value);
        }
        if (controls.TryGetValue("memoryPriority", out var memory))
        {
            var value = memory.GetInt32(); if (value is < 1 or > 5) throw new InvalidDataException("Invalid launch memory priority.");
            _values.Add("PagePriority", value);
        }
    }
    public bool HasValues => _values.Count != 0;
    public LaunchPrioritySnapshot Read()
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var image = hive.OpenSubKey(Root + "\\" + _image);
        if (image?.GetValue("Debugger") is not null || (image?.GetValue("UseFilter") is { } filter && !Equals(filter, 0)))
            throw new InvalidOperationException("Existing IFEO debugger or filtered settings require separate review.");
        using var options = image?.OpenSubKey("PerfOptions");
        var values = new Dictionary<string, int?>();
        foreach (var name in _values.Keys)
        {
            if (options is null || !options.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase)) values[name] = null;
            else
            {
                if (options.GetValueKind(name) != RegistryValueKind.DWord) throw new InvalidDataException("Unknown registry value kind for " + name);
                values[name] = (int)options.GetValue(name)!;
            }
        }
        return new() { ImageKeyExisted = image is not null, OptionsKeyExisted = options is not null, Values = values };
    }
    public void VerifyOriginal(LaunchPrioritySnapshot original)
    {
        var actual = Read();
        if (original.ImageKeyExisted != actual.ImageKeyExisted || original.OptionsKeyExisted != actual.OptionsKeyExisted ||
            original.Values.Count != actual.Values.Count || original.Values.Any(pair => !actual.Values.TryGetValue(pair.Key, out var value) || value != pair.Value))
            throw new InvalidOperationException("Launch settings changed since review.");
    }
    public void Apply(LaunchPrioritySnapshot original)
    {
        VerifyOriginal(original);
        if (!HasValues) return;
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = hive.CreateSubKey(Root + "\\" + _image + "\\PerfOptions", true);
        foreach (var pair in _values)
        {
            var current = key.GetValue(pair.Key);
            if (!original.Values.TryGetValue(pair.Key, out var value) || !Equals(current, value))
                throw new InvalidOperationException("A concurrent writer changed " + pair.Key);
            key.SetValue(pair.Key, pair.Value, RegistryValueKind.DWord); key.Flush();
        }
        VerifyApplied();
    }
    public void VerifyApplied()
    {
        var current = Read();
        if (_values.Any(pair => current.Values[pair.Key] != pair.Value)) throw new InvalidOperationException("A launch setting no longer matches the active policy.");
    }
    public void Restore(LaunchPrioritySnapshot original)
    {
        if (!HasValues) return;
        var current = Read();
        if (!original.Values.Keys.Order().SequenceEqual(_values.Keys.Order())) throw new InvalidDataException("Incomplete launch recovery snapshot.");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        var conflicts = new List<string>();
        using (var options = hive.OpenSubKey(Root + "\\" + _image + "\\PerfOptions", true))
        {
            foreach (var pair in _values)
            {
                var observed = current.Values[pair.Key]; var before = original.Values[pair.Key];
                if (observed == before) continue;
                if (observed != pair.Value || !Equals(options?.GetValue(pair.Key), observed)) { conflicts.Add(pair.Key); continue; }
                if (before.HasValue) options!.SetValue(pair.Key, before.Value, RegistryValueKind.DWord);
                else options!.DeleteValue(pair.Key, false);
                options!.Flush();
            }
        }
        using (var image = hive.OpenSubKey(Root + "\\" + _image, true))
        {
            bool emptyOptions;
            using (var options = image?.OpenSubKey("PerfOptions")) emptyOptions = options is not null && options.ValueCount == 0 && options.SubKeyCount == 0;
            if (!original.OptionsKeyExisted && emptyOptions) image!.DeleteSubKey("PerfOptions", false);
        }
        bool emptyImage;
        using (var image = hive.OpenSubKey(Root + "\\" + _image)) emptyImage = image is not null && image.ValueCount == 0 && image.SubKeyCount == 0;
        if (!original.ImageKeyExisted && emptyImage) hive.DeleteSubKey(Root + "\\" + _image, false);
        if (conflicts.Count != 0) throw new InvalidOperationException("External registry values were preserved: " + string.Join(", ", conflicts));
        var restored = Read();
        if (original.Values.Any(pair => restored.Values[pair.Key] != pair.Value)) throw new InvalidOperationException("Registry restoration readback failed.");
    }
}
