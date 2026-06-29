using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Roo.OptimizationSuite.Services;

public sealed class SettingsStore
{
    private readonly string _filePath;
    private Dictionary<string, string> _values;

    public SettingsStore()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RooOptimizationSuite");
        Directory.CreateDirectory(root);
        _filePath = Path.Combine(root, "settings.json");
        _values = Load(_filePath);
    }

    public string? Get(string key) => _values.TryGetValue(key, out var value) ? value : null;

    public void Set(string key, string value)
    {
        _values[key] = value;
        try
        {
            File.WriteAllText(_filePath, JsonSerializer.Serialize(_values));
        }
        catch (IOException)
        {
        }
    }

    private static Dictionary<string, string> Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))
                       ?? new Dictionary<string, string>();
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
        }

        return new Dictionary<string, string>();
    }
}
