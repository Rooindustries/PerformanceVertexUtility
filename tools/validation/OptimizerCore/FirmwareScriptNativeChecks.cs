using System.Diagnostics;
using System.Text;
using System.Text.Json;
using RooIndustries.Optimizer;

static class FirmwareScriptNativeChecks
{
    public static void Run(Action<bool, string> check, string evidenceRoot)
    {
        var root = Path.GetFullPath(evidenceRoot);
        var originalPath = Path.Combine(root, "original.txt");
        var goldenPath = Path.Combine(root, "legacy-parser.json");
        var pilotPath = Path.Combine(root, "pilot", "3BE7D87FEFDE62D5A9E5999C4E9315FEE0CFF3477E743FBFBE722340712EE113.txt");
        var candidatePath = Path.Combine(root, "analysis", "led-original-format.txt");
        check(File.Exists(originalPath) && File.Exists(goldenPath) && File.Exists(pilotPath) && File.Exists(candidatePath), "Native firmware evidence files are present");
        if (!File.Exists(originalPath) || !File.Exists(goldenPath) || !File.Exists(pilotPath) || !File.Exists(candidatePath)) return;
        var bytes = File.ReadAllBytes(originalPath);
        var script = new FirmwareScript(bytes);
        var golden = JsonDocument.Parse(File.ReadAllBytes(goldenPath)).RootElement;
        check(script.Questions.Count == golden.GetProperty("questions").GetArrayLength(), "Native parser reads all 4,693 editable firmware records");
        check(Compatible(script, golden), "Native parser preserves every public question ID, context, type, width, option and value");
        var turboRange = script.Questions.Single(question => question.Name.StartsWith("Turbo E-Core Range 8", StringComparison.Ordinal));
        var turboBoost = script.Questions.Single(question => question.Name == "Intel(R) Turbo Boost Max Technology 3.0");
        check(turboRange.StorageGuid != turboBoost.StorageGuid || turboRange.StorageName != turboBoost.StorageName,
            "Adjacent variable forms retain distinct native storage identities");
        var led = script.Questions.Single(question => question.Name == "LEDs in System Power On State");
        var corrected = script.Changes(new Dictionary<string, string> { [led.Id] = "00" });
        var expected = File.ReadAllBytes(candidatePath);
        var pilot = File.ReadAllBytes(pilotPath);
        check(!NativeFormat(pilot), "The rejected pilot script fails native format checks");
        check(NativeFormat(corrected), "The corrected one-setting script passes native format checks");
        check(corrected.SequenceEqual(expected), "The corrected LED script preserves the native header, context and line endings");
        var correctedScript = new FirmwareScript(corrected);
        check(correctedScript.Questions.Count == 1 && correctedScript.Questions[0].Id == led.Id && correctedScript.Questions[0].Current == "00",
            "The corrected script retains the reviewed setting identity and selected value");
        var baselineMs = golden.GetProperty("parseMilliseconds").GetDouble();
        var stopwatch = Stopwatch.StartNew();
        _ = new FirmwareScript(bytes);
        stopwatch.Stop();
        check(stopwatch.Elapsed.TotalMilliseconds < baselineMs, $"Linear parser benchmark is below the prior prefix-rescan baseline ({stopwatch.Elapsed.TotalMilliseconds:F2} ms versus {baselineMs:F2} ms)");
    }

    private static bool Compatible(FirmwareScript script, JsonElement golden)
    {
        var expected = golden.GetProperty("questions");
        if (script.Questions.Count != expected.GetArrayLength()) return false;
        for (var i = 0; i < script.Questions.Count; i++)
        {
            var actual = script.Questions[i];
            var item = expected[i];
            if (actual.Id != item.GetProperty("id").GetString() || actual.Name != item.GetProperty("name").GetString()
                || actual.Help != item.GetProperty("help").GetString() || actual.Current != item.GetProperty("current").GetString()
                || actual.Kind != item.GetProperty("kind").GetString() || actual.Width != item.GetProperty("width").GetInt32()
                || actual.Context != item.GetProperty("context").GetString()) return false;
            var options = item.GetProperty("options");
            if (actual.Options.Length != options.GetArrayLength()) return false;
            for (var optionIndex = 0; optionIndex < actual.Options.Length; optionIndex++)
            {
                var option = options[optionIndex];
                if (actual.Options[optionIndex].Value != option.GetProperty("value").GetString()
                    || actual.Options[optionIndex].Label != option.GetProperty("label").GetString()) return false;
            }
        }
        return true;
    }

    private static bool NativeFormat(byte[] bytes)
    {
        var text = Encoding.Latin1.GetString(bytes);
        var residual = text.Replace("\r\n", "", StringComparison.Ordinal);
        return text.StartsWith("// Script File Name : ", StringComparison.Ordinal)
            && !residual.Contains('\r') && !residual.Contains('\n')
            && RegexCount(text, "HIICrc32") == 1
            && !text.Contains("AmiWrapperSetup", StringComparison.Ordinal)
            && !text.Contains("c61c31a3-cb5d-46dd-9fe5-8a82bbc72483", StringComparison.Ordinal);
    }

    private static int RegexCount(string value, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = value.IndexOf(needle, index, StringComparison.Ordinal)) >= 0) { count++; index += needle.Length; }
        return count;
    }
}
