using System.Diagnostics;
using System.Text.Json;
using System.Reflection;
using RooIndustries.Optimizer;

static class FakeHost
{
    public static void Run(string action)
    {
        var state = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_BOUNDS_DIR") ?? throw new InvalidOperationException("The bounds fixture folder is missing.");
        var request = Console.In.ReadToEnd();
        File.AppendAllText(Path.Combine(state, "host-calls.log"), Environment.ProcessId + " " + action + "\n");
        if (File.Exists(Path.Combine(state, "host-hang"))) Hang(state);
        if (File.Exists(Path.Combine(state, "host-slow"))) Thread.Sleep(int.Parse(File.ReadAllText(Path.Combine(state, "host-slow"))));
        string data;
        switch (action)
        {
            case "process-apply":
            case "process-restore":
                using (var document = JsonDocument.Parse(request))
                {
                    var input = document.RootElement;
                    var engine = new ProcessControlEngine(_ => false);
                    var journal = input.GetProperty("journalPath").GetString()!;
                    var result = action == "process-apply"
                        ? engine.Apply(input.GetProperty("previewPath").GetString()!, input.GetProperty("reviewHash").GetString()!, journal)
                        : engine.RestoreApplyOnce(journal, Path.GetDirectoryName(Path.GetFullPath(input.GetProperty("policyRoot").GetString()!))!, input.GetProperty("repoRoot").GetString());
                    data = JsonSerializer.Serialize(result, OperationFiles.Json);
                }
                break;
            case "rule-save":
                using (var document = JsonDocument.Parse(request))
                {
                    var input = document.RootElement;
                    var rule = input.GetProperty("rule").Deserialize<SavedProcessRule>(OperationFiles.Json)! with { Revision = Guid.NewGuid().ToString("N") };
                    OperationFiles.Write(Path.Combine(input.GetProperty("policyRoot").GetString()!, "rules", rule.RuleId + ".json"), rule);
                    data = JsonSerializer.Serialize(rule, OperationFiles.Json);
                }
                break;
            case "rule-delete":
                using (var document = JsonDocument.Parse(request))
                {
                    var input = document.RootElement;
                    var id = input.GetProperty("ruleId").GetString()!;
                    File.Delete(Path.Combine(input.GetProperty("policyRoot").GetString()!, "rules", id + ".json"));
                    data = JsonSerializer.Serialize(new { deletedRuleId = id });
                }
                break;
            case "cleanup-batch-cancel":
                using (var document = JsonDocument.Parse(request))
                    data = JsonSerializer.Serialize(CleanupBatch.Cancel(document.RootElement.GetProperty("journalPath").GetString()!), OperationFiles.Json);
                break;
            case "tweak-custom-import":
                var local = (Lazy<string>)typeof(BrandCompatibility).GetField("Local", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
                if (local.IsValueCreated) throw new InvalidOperationException("The fixture data root was already selected.");
                typeof(Lazy<string>).GetField("_factory", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(local, (Func<string>)(() => Path.Combine(state, "custom-data")));
                if (BrandCompatibility.LocalDataRoot != Path.Combine(state, "custom-data")) throw new InvalidOperationException("Custom settings are outside the fixture.");
                using (var document = JsonDocument.Parse(request))
                {
                    var catalog = CustomTweaks.Import(new TweakCatalog(1, "bounds-fixture", [], []), document.RootElement.GetProperty("customSettingsPath").GetString()!);
                    data = JsonSerializer.Serialize(new TweakCatalogResult(catalog, catalog.Digest), OperationFiles.Json);
                }
                break;
            case "rules-list":
                data = "[]";
                break;
            case "policy-run":
                data = JsonSerializer.Serialize(new PolicyHostState { SchemaVersion = 1, Owner = OperationOwner.Current(), Status = "stopped", Host = null, Instances = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow }, OperationFiles.Json);
                break;
            case "tweak-preview":
                using (var document = JsonDocument.Parse(request)) File.Copy(Path.Combine(state, "plan.json"), document.RootElement.GetProperty("outputPath").GetString()!);
                data = File.ReadAllText(Path.Combine(state, "plan.json"));
                break;
            case "tweak-apply" or "tweak-restore":
                data = File.ReadAllText(Path.Combine(state, "apply-result.json"));
                break;
            default:
                data = "{}";
                break;
        }
        if (File.Exists(Path.Combine(state, "host-hang-after"))) Hang(state);
        Console.WriteLine("{\"schemaVersion\":1,\"status\":\"completed\",\"data\":" + data + "}");
    }

    static void Hang(string state)
    {
        var ping = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "PING.EXE"), "-n 400 127.0.0.1") { UseShellExecute = false, CreateNoWindow = true };
        using var child = Process.Start(ping)!;
        using var self = Process.GetCurrentProcess();
        File.WriteAllText(Path.Combine(state, "host-pids.txt.identity"), self.Id + ":" + self.StartTime.ToUniversalTime().Ticks + " " + child.Id + ":" + child.StartTime.ToUniversalTime().Ticks);
        File.WriteAllText(Path.Combine(state, "host-pids.txt"), Environment.ProcessId + " " + child.Id);
        Thread.Sleep(Timeout.Infinite);
    }
}
