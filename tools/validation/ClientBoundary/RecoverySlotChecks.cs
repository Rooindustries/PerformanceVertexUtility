using System.Text.Json;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

internal static class RecoverySlotChecks
{
    public static async Task Run(string action, string output, string repo, string recoveryDirectory)
    {
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", repo);
        var service = new LiveDataService(new BackendLocator(), recoveryDirectory);
        LiveDataResult<string>? result = null;
        if (action == "apply") result = await service.ApplyProcessProfileResultAsync();
        else if (action == "restore")
        {
            var recovery = service.ProcessProfileRecovery ?? throw new InvalidOperationException("No verified recovery is available.");
            result = await service.RestoreProcessProfileResultAsync(recovery);
        }
        else if (action != "inspect") throw new ArgumentException("Unknown recovery action.");
        var current = service.ProcessProfileRecovery;
        File.WriteAllText(output, JsonSerializer.Serialize(new { result, recovery = current, pending = service.ProcessProfileRestorePending }));
    }

    public static void Settings(string output)
    {
        var path = Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "settings.json");
        var original = File.ReadAllBytes(path);
        var attributes = File.GetAttributes(path);
        var evidence = new List<object>();
        try
        {
            foreach (var broken in new[] { "", "{\"themeId\":\"partial" })
            {
                File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
                File.WriteAllText(path, broken);
                var before = Directory.GetFiles(Path.GetDirectoryName(path)!, "settings.json.corrupt-*").ToHashSet();
                var store = new SettingsStore();
                var archived = Directory.GetFiles(Path.GetDirectoryName(path)!, "settings.json.corrupt-*").Except(before).Single();
                if (File.ReadAllText(archived) != broken || File.Exists(path)) throw new InvalidOperationException("Corrupt settings bytes were not preserved before recovery.");
                var requested = new Dictionary<string, string> { ["themeId"] = "roo-industries-blue", ["simpleMode"] = "1", ["reducedEffects"] = "1" };
                foreach (var pair in requested) if (store.Set(pair.Key, pair.Value) is { } error) throw new InvalidOperationException(error);
                var reloaded = new SettingsStore();
                if (requested.Any(pair => reloaded.Get(pair.Key) != pair.Value)) throw new InvalidOperationException("Recovered settings did not persist.");
                evidence.Add(new { broken, archived, requested, reloaded = requested.ToDictionary(pair => pair.Key, pair => reloaded.Get(pair.Key)) });
            }
            using (var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                var store = new SettingsStore();
                if (store.Set("unknown", "refuse") is null) throw new InvalidOperationException("Locked settings were treated as corrupt.");
            }
            File.WriteAllText(output, JsonSerializer.Serialize(new { status = "passed", cases = evidence, lockedFileRefused = true }));
        }
        finally { File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly); File.WriteAllBytes(path, original); File.SetAttributes(path, attributes); }
    }
}
