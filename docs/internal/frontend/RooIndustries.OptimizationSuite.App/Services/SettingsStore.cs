using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class SettingsStore
{
    private readonly string _filePath;
    private Dictionary<string, string> _values;
    private bool _loaded;

    public SettingsStore()
    {
        var root = RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot;
        Directory.CreateDirectory(root);
        _filePath = Path.Combine(root, "settings.json");
        _loaded = TryLoad(_filePath, out _values, out _, allowMissing: true);
    }

    public string? Get(string key) => _values.TryGetValue(key, out var value) ? value : null;

    public string? Set(string key, string value)
    {
        try
        {
            if (TryLoad(_filePath, out var latest, out var loadError))
            {
                _values = latest;
                _loaded = true;
            }
            else if (!_loaded) return loadError;
            var updated = new Dictionary<string, string>(_values) { [key] = value };
            RooIndustries.Optimizer.OperationFiles.Write(_filePath, updated);
            _values = updated;
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    private static bool TryLoad(string path, out Dictionary<string, string> values, out string? error, bool allowMissing = false)
    {
        values = new();
        error = null;
        try
        {
            values = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))
                ?? throw new JsonException("The settings file is empty.");
            return true;
        }
        catch (FileNotFoundException failure) { error = failure.Message; return allowMissing; }
        catch (Exception failure)
        {
            error = failure.Message;
            return false;
        }
    }
}
