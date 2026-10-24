using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.Optimizer;

static class LaunchPresetChecks
{
    static int passed;
    static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
        passed++; Console.WriteLine("PASS " + message);
    }
    static string Preset(string id, string settings, string? name = null, string description = "Fixture preset.")
        => "{\"id\":\"" + id + "\",\"name\":\"" + (name ?? id) + "\",\"description\":\"" + description + "\",\"settings\":" + settings + "}";

    public static void Run(string repo)
    {
        var shipped = LaunchPresetCatalog.Read(Path.Combine(repo, "backend", "catalogs", "launch-presets.json"));
        Check(shipped.Presets.Length > 0, "The shipped launch presets load through the app's loader and pass the game session's own checks");
        var schema = JsonNode.Parse(File.ReadAllText(Path.Combine(repo, "backend", "contracts", "roo-industries-backend-contracts.schema.json")))!;
        var choices = schema["$defs"]!["launchPresetCatalog"]!["properties"]!["presets"]!["items"]!["properties"]!["settings"]!["properties"]!.AsObject()
            .SelectMany(pair => pair.Value!["enum"]!.AsArray().Select(value => (Name: pair.Key, Value: value!.ToJsonString()))).ToArray();
        Check(choices.Select(choice => choice.Name).Distinct().SequenceEqual(LaunchPresetCatalog.SettingNames), "The catalog schema and the loader list the same game session settings, in the same order");
        var folder = Directory.CreateTempSubdirectory("roo-industries-launch-presets-");
        try
        {
            var path = Path.Combine(folder.FullName, "launch-presets.json");
            LaunchPresetCatalog Load(string presets, int version = 1)
            {
                File.WriteAllText(path, "{\"schemaVersion\":" + version + ",\"presets\":[" + presets + "]}");
                return LaunchPresetCatalog.Read(path);
            }
            string? Refused(string presets, int version = 1)
            {
                try { Load(presets, version); return null; }
                catch (Exception error) when (error is InvalidDataException or JsonException) { return error.Message; }
            }
            var every = Load(string.Join(",", choices.Select((choice, index) => Preset("choice-" + index, "{\"" + choice.Name + "\":" + choice.Value + "}"))));
            Check(every.Presets.Length == choices.Length, "Every value the catalog schema allows passes the game session's own checks (" + choices.Length + " values)");
            var converted = Load(Preset("power", "{\"executionQoS\":\"high\",\"cpuPriority\":\"High\"}")).Presets[0].Controls();
            Check(converted["executionQoS"].GetRawText() == JsonSerializer.SerializeToElement(new PowerThrottling(0, 0).WithExecutionMode("high"), OperationFiles.Json).GetRawText()
                && converted["cpuPriority"].GetRawText() == "\"High\"", "A preset's power mode becomes the value the game session form sends, and other settings pass through as written");
            Check(Refused(Preset("bad", "{\"cpuPriority\":\"Realtime\"}"))?.Contains("real-time CPU priority", StringComparison.Ordinal) == true, "A preset with Realtime CPU priority is refused by the session's own check");
            Check(Refused(Preset("high-io", "{\"ioPriority\":3}")) is null, "The session's own check accepts High I/O priority, which the session sets on the running game; only the catalog schema keeps it out of presets");
            Check(Refused(Preset("bad", "{\"gpuPriority\":5}"))?.Contains("Real-time GPU priority", StringComparison.Ordinal) == true, "A preset with Realtime GPU priority is refused by the session's own check");
            var good = Preset("good", "{\"cpuPriority\":\"AboveNormal\"}");
            foreach (var (label, presets) in new (string, string)[]
            {
                ("a memory priority below Very low", Preset("bad", "{\"memoryPriority\":0}")),
                ("an unknown power mode", Preset("bad", "{\"executionQoS\":\"turbo\"}")),
                ("CPU priority written as a number", Preset("bad", "{\"cpuPriority\":4}")),
                ("priority boost written as text", Preset("bad", "{\"priorityBoost\":\"true\"}")),
                ("an escaped spelling of High", Preset("bad", "{\"cpuPriority\":\"\\u0048igh\"}")),
                ("I/O priority written as 2.0", Preset("bad", "{\"ioPriority\":2.0}")),
                ("a setting the session form lacks", Preset("bad", "{\"affinity\":{\"group\":0,\"mask\":\"0x1\"}}")),
                ("no settings", Preset("bad", "{}")),
                ("null settings", Preset("bad", "null")),
                ("the same setting twice", Preset("bad", "{\"cpuPriority\":\"High\",\"cpuPriority\":\"Normal\"}")),
                ("a repeated id", good + "," + Preset("good", "{\"cpuPriority\":\"High\"}", "Other")),
                ("a repeated name in another case", good + "," + Preset("other", "{\"cpuPriority\":\"High\"}", "GOOD")),
                ("the same settings as another preset", good + "," + Preset("other", "{\"cpuPriority\":\"AboveNormal\"}", "Other")),
                ("the name Custom", Preset("custom", "{\"cpuPriority\":\"High\"}", "custom")),
                ("an id with spaces and capitals", Preset("Bad id", "{\"cpuPriority\":\"High\"}")),
                ("a name with a leading space", Preset("bad", "{\"cpuPriority\":\"High\"}", " Spaced")),
                ("an empty description", Preset("bad", "{\"cpuPriority\":\"High\"}", description: " ")),
                ("an unknown field", "{\"id\":\"bad\",\"name\":\"Bad\",\"description\":\"Fixture preset.\",\"settings\":{\"cpuPriority\":\"High\"},\"cores\":\"performance\"}"),
                ("a missing description", "{\"id\":\"bad\",\"name\":\"Bad\",\"settings\":{\"cpuPriority\":\"High\"}}"),
                ("a null entry", good + ",null"),
            })
                Check(Refused(presets) is not null, "A launch preset with " + label + " is refused");
            Check(Refused("") is not null, "A launch preset catalog with no presets is refused");
            Check(Refused(good, 2) is not null, "A launch preset catalog with an unknown version is refused");
        }
        finally { folder.Delete(true); }
        Console.WriteLine("Launch preset assertions: " + passed);
    }
}
