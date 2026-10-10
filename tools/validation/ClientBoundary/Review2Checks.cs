using System.Text.Json;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

internal static class Review2Checks
{
    public static async Task Run(string output, string recoveryDirectory, bool settings = true)
    {
        Directory.CreateDirectory(output);
        var pointer = Path.Combine(recoveryDirectory, "process-profile-recovery.json");
        var generation = Path.Combine(recoveryDirectory, "process-profile-operation-generation.json");
        if (!File.Exists(pointer)) throw new InvalidOperationException("Apply the owned UI fixture once before this check.");
        var pointerBefore = OperationFiles.HashFile(pointer);
        var generationBefore = OperationFiles.HashFile(generation);
        var live = new LiveDataService(new BackendLocator(), recoveryDirectory);
        var result = await live.ApplyProcessProfileResultAsync(preset: "placement");
        if (result.Value is not null || result.Error != "Restore the last change first" ||
            OperationFiles.HashFile(pointer) != pointerBefore || OperationFiles.HashFile(generation) != generationBefore)
            throw new InvalidOperationException("Pending restore did not refuse the service Apply before changing its records.");
        File.WriteAllText(Path.Combine(output, "restore-pending-service.json"), JsonSerializer.Serialize(new { result, pointerBefore, generationBefore, pointerAfter = OperationFiles.HashFile(pointer), generationAfter = OperationFiles.HashFile(generation) }));
        if (!settings) { Console.WriteLine("PASS pending restore refuses service Apply"); return; }

        var path = Path.Combine(BrandCompatibility.LocalDataRoot, "settings.json");
        var original = File.ReadAllBytes(path);
        var attributes = File.GetAttributes(path);
        try
        {
            var known = JsonSerializer.Deserialize<Dictionary<string, string>>(original)!;
            var store = new SettingsStore();
            File.WriteAllText(path, "{broken reload");
            var saved = store.Set("review2Probe", "retained");
            var retained = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))!;
            if (saved is not null || known.Any(pair => !retained.TryGetValue(pair.Key, out var value) || value != pair.Value))
                throw new InvalidOperationException("Reload failure discarded in-memory settings.");
            File.WriteAllText(Path.Combine(output, "settings-reload.json"), JsonSerializer.Serialize(new { saved, known, retained }));
            File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly);
            var before = File.ReadAllBytes(path);
            var error = store.Set("review2Probe", "must not replace");
            if (error is null || store.Get("review2Probe") != "retained" || !File.ReadAllBytes(path).SequenceEqual(before))
                throw new InvalidOperationException("Read-only settings did not preserve the previous value and bytes.");
            File.WriteAllText(Path.Combine(output, "settings-readonly.json"), JsonSerializer.Serialize(new { error, previousValue = store.Get("review2Probe"), bytesUnchanged = true }));
            File.SetAttributes(path, attributes);
            using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                var unknown = new SettingsStore();
                var refused = unknown.Set("review2Unknown", "must not replace");
                if (refused is null) throw new InvalidOperationException("An instance without known settings wrote after its reload failed.");
                File.WriteAllText(Path.Combine(output, "settings-unreadable.json"), JsonSerializer.Serialize(new { refused, fileUnchanged = true }));
            }
            if (!File.ReadAllBytes(path).SequenceEqual(before)) throw new InvalidOperationException("Unreadable settings bytes changed.");
        }
        finally { File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly); File.WriteAllBytes(path, original); File.SetAttributes(path, attributes); }
        Console.WriteLine("PASS pending restore and settings reload/write failures");
    }
}
