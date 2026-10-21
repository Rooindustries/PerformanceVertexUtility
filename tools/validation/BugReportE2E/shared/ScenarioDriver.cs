using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace Roo70Fixture;
public sealed record Surface(BugReportViewModel Model, Func<Task> Attach, Func<Task> Save, Func<Task> Send, Func<Task> SeedVisible);
public sealed record CapturedSend(string Payload, byte[] Zip);
public sealed class FixtureSender(int code) : IBugReportSender
{
    public List<CapturedSend> Calls { get; } = new();
    public Task<BugSendResult> SendAsync(string webhookUrl, string payloadJson, string zipPath, CancellationToken cancellationToken)
    {
        ScenarioDriver.Require(webhookUrl == ScenarioDriver.Webhook, "Unexpected synthetic URL.");
        Calls.Add(new(payloadJson, File.ReadAllBytes(zipPath)));
        return Task.FromResult(new BugSendResult(code == 200, code));
    }
}
public sealed record SceneState(bool OnlineAvailable, bool OfflineOnly, bool Busy, bool LoadingSpecs, bool CanAttach, bool CanSend,
    bool ShowSave, bool HasSavedReport, string? SavedPath, string Description, string Contact, string AttachmentText, string Status, string Cpu, int SpecCount);
public sealed record EvidenceFile(string File, string Sha256, long Bytes);
public sealed record SceneReceipt(string Name, SceneState State, int SenderCalls, IReadOnlyList<EvidenceFile> Evidence, string Scope);
public static class ScenarioDriver
{
    public const string Webhook = "https://discord.com/api/webhooks/123/fixture-token";
    public const string Contact = "retain-contact@example.com";
    public const string Raw = @"C:\Users\" + @"Zqx Bob O'Neil\AppData\x.log";
    public const string Forward = "C:/Users/" + "Zqxbob/AppData/x.log";
    public const string R9 = @"C:/Users/\u003Cuser\u003E%USERPROFILE%\u003Cuser\u003EZqxbob/x";
    public const string ExpectedRaw = @"C:\Users\<user>\AppData\x.log";
    public const string ExpectedForward = "C:/Users/<user>/AppData/x.log";
    public const string ExpectedR9 = "C:/Users/<user>/x";
    public static readonly string Description = string.Join("\n", Raw, Forward, R9);
    public static readonly string ExpectedDescription = string.Join("\n", ExpectedRaw, ExpectedForward, ExpectedR9);
    public static readonly string RawLog = string.Join("\n", Raw, Forward, R9, @"C:\Users\" + @"Alice\AppData\x.log", "Alice GAMER-PC S-1-5-21-11-22-33-44") + "\n";
    public static readonly string ExpectedLog = string.Join("\n", ExpectedRaw, ExpectedForward, ExpectedR9, @"%USERPROFILE%\AppData\x.log", "<user> <pc-name> <sid>") + "\n";
    public static readonly string[] Names = ["offline-empty", "offline-attached", "offline-saved", "online-failed", "online-fallback-saved", "online-sent"];
    public static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    public static void RequireDisabledLog()
    {
        Require(typeof(AppLog).GetField("_enabled", BindingFlags.NonPublic | BindingFlags.Static)?.GetValue(null) is false, "Actual AppLog must remain disabled.");
        Require(AppLog.Observer is null, "No AppLog observer permitted.");
    }
    public static SceneState State(BugReportViewModel vm) => new(vm.OnlineAvailable, vm.OfflineOnly, vm.Busy, vm.LoadingSpecs,
        vm.CanAttach, vm.CanSend, vm.ShowSave, vm.HasSavedReport, vm.SavedPath, vm.Description, vm.Contact,
        vm.AttachmentText, vm.Status, vm.Specs.SingleOrDefault(x => x.Key == "cpu")?.Value ?? "", vm.Specs.Count);
    public static string Snapshot(BugReportViewModel vm) => JsonSerializer.Serialize(State(vm));
    public static async Task Wait(Func<bool> predicate, string failure)
    {
        var until = DateTime.UtcNow.AddSeconds(5);
        while (!predicate()) { if (DateTime.UtcNow >= until) throw new TimeoutException(failure); await Task.Delay(20); }
    }
    public static async Task<IReadOnlyList<SceneReceipt>> RunAsync(string data, string evidence,
        Func<BugReportService, FixtureSender, Task<Surface>> factory, Func<SceneReceipt, BugReportViewModel, Task> checkpoint, string scope)
    {
        RequireDisabledLog();
        var receipts = new List<SceneReceipt>();
        async Task Emit(string name, Surface surface, FixtureSender sender, List<EvidenceFile> files)
        {
            Require(receipts.Count < Names.Length && Names[receipts.Count] == name, "Checkpoint ordering changed.");
            Require(!surface.Model.Busy && !surface.Model.LoadingSpecs, "Unsettled checkpoint.");
            RequireDisabledLog();
            var receipt = new SceneReceipt(name, State(surface.Model), sender.Calls.Count, files, scope);
            File.WriteAllText(Path.Combine(evidence, name + ".semantic.json"), JsonSerializer.Serialize(receipt));
            await checkpoint(receipt, surface.Model);
            receipts.Add(receipt);
        }
        async Task<(Surface Surface, FixtureSender Sender, string Reports)> Create(string label, bool online, int code)
        {
            var scenario = Directory.CreateDirectory(Path.Combine(data, label)).FullName;
            var logs = Directory.CreateDirectory(Path.Combine(scenario, "logs")).FullName;
            var reports = Path.Combine(scenario, "reports");
            File.WriteAllText(Path.Combine(logs, "app.log"), RawLog);
            var sender = new FixtureSender(code);
            var service = new BugReportService(online ? Webhook : null, sender, reports, logs,
                new BugRedactor(@"C:\Users\" + @"Alice", "Alice", "GAMER-PC"), () => new DateTime(2026, 10, 21, 1, 2, 3, DateTimeKind.Utc));
            var surface = await factory(service, sender);
            Require(surface.Model.Specs.Count == 9 && surface.Model.Specs.Single(x => x.Key == "windows").Value == "Fixture Windows"
                && surface.Model.Specs.Single(x => x.Key == "cpu").Value == "Fixture CPU", "Actual LoadAsync did not complete expected specs.");
            Require(!surface.Model.Busy && !surface.Model.LoadingSpecs && surface.Model.CanAttach, "Initial VM not ready.");
            return (surface, sender, reports);
        }
        async Task Seed(Surface surface)
        {
            surface.Model.Description = Description;
            surface.Model.Contact = Contact;
            surface.Model.Specs.Single(x => x.Key == "cpu").Value = Raw;
            await surface.SeedVisible();
        }
        var offline = await Create("offline", false, 404);
        Require(offline.Surface.Model.OfflineOnly && !offline.Surface.Model.OnlineAvailable && !offline.Surface.Model.CanSend
            && offline.Surface.Model.ShowSave && !offline.Surface.Model.HasSavedReport
            && offline.Surface.Model.AttachmentText == "No logs attached yet.", "Offline-empty state mismatch.");
        await Emit(Names[0], offline.Surface, offline.Sender, []);
        await Seed(offline.Surface);
        await offline.Surface.Attach();
        await Wait(() => !offline.Surface.Model.Busy && offline.Surface.Model.AttachmentText.StartsWith("Attached ", StringComparison.Ordinal), "Attach did not settle.");
        Require(offline.Surface.Model.CanSend, "Attached VM cannot save/send.");
        var offlineZip = Directory.GetFiles(Path.Combine(offline.Reports, "outgoing"), "*.zip").Single();
        var attachedFiles = VerifyZip(File.ReadAllBytes(offlineZip), false, "offline-attached", evidence);
        Require(offline.Sender.Calls.Count == 0, "Offline flow invoked sender.");
        await Emit(Names[1], offline.Surface, offline.Sender, attachedFiles);
        await offline.Surface.Save();
        await Wait(() => !offline.Surface.Model.Busy && offline.Surface.Model.HasSavedReport, "Offline Save did not settle.");
        Require(offline.Surface.Model.Status.StartsWith("Saved ", StringComparison.Ordinal), "Save status mismatch.");
        await Emit(Names[2], offline.Surface, offline.Sender, VerifyZip(File.ReadAllBytes(offline.Surface.Model.SavedPath!), true, Names[2], evidence));
        var failed = await Create("failed", true, 404);
        await Seed(failed.Surface);
        await failed.Surface.Attach();
        await failed.Surface.Send();
        await Wait(() => !failed.Surface.Model.Busy && failed.Sender.Calls.Count == 1, "Failed Send did not settle.");
        Require(failed.Surface.Model.ShowSave && failed.Surface.Model.CanSend
            && failed.Surface.Model.Status == "The report couldn't be delivered. Try again later, or save the report to a file and send it yourself.", "Failed-send fallback mismatch.");
        var failureFiles = VerifySend(failed.Sender, Names[3], evidence);
        await Emit(Names[3], failed.Surface, failed.Sender, failureFiles);
        await failed.Surface.Save();
        await Wait(() => !failed.Surface.Model.Busy && failed.Surface.Model.HasSavedReport, "Fallback Save did not settle.");
        await Emit(Names[4], failed.Surface, failed.Sender, VerifyZip(File.ReadAllBytes(failed.Surface.Model.SavedPath!), true, Names[4], evidence));
        var sent = await Create("sent", true, 200);
        await Seed(sent.Surface);
        await sent.Surface.Attach();
        await sent.Surface.Send();
        await Wait(() => !sent.Surface.Model.Busy && sent.Sender.Calls.Count == 1, "Successful Send did not settle.");
        Require(sent.Surface.Model.Status == "Thanks! Your report was sent to the developers."
            && sent.Surface.Model.Description == "" && sent.Surface.Model.Contact == ""
            && sent.Surface.Model.AttachmentText == "No logs attached yet." && sent.Surface.Model.SavedPath is null
            && !sent.Surface.Model.CanSend && !sent.Surface.Model.ShowSave, "Sent reset state mismatch.");
        Require(!Directory.GetFiles(Path.Combine(sent.Reports, "outgoing"), "*.zip").Any(), "Sent outgoing archive was not removed.");
        await Emit(Names[5], sent.Surface, sent.Sender, VerifySend(sent.Sender, Names[5], evidence));
        Require(receipts.Select(x => x.Name).SequenceEqual(Names), "Six checkpoints required.");
        RequireDisabledLog();
        return receipts;
    }
    private static List<EvidenceFile> VerifySend(FixtureSender sender, string name, string evidence)
    {
        Require(sender.Calls.Count == 1, "Exactly one fake sender call required.");
        var call = sender.Calls[0];
        using var payload = JsonDocument.Parse(call.Payload);
        var embed = payload.RootElement.GetProperty("embeds")[0];
        Require(embed.GetProperty("description").GetString() == ExpectedDescription, "Typed description privacy mismatch.");
        var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
        Require(fields.Single(x => x.GetProperty("name").GetString() == "Processor").GetProperty("value").GetString() == ExpectedRaw, "Typed specs privacy mismatch.");
        Require(fields.Single(x => x.GetProperty("name").GetString() == "Discord or email").GetProperty("value").GetString() == Contact, "Intentional contact changed.");
        RequirePrivate(call.Payload);
        var files = VerifyZip(call.Zip, false, name, evidence);
        files.Add(SaveEvidence(evidence, name + ".payload.json", System.Text.Encoding.UTF8.GetBytes(call.Payload)));
        return files;
    }
    private static List<EvidenceFile> VerifyZip(byte[] bytes, bool report, string name, string evidence)
    {
        using var memory = new MemoryStream(bytes);
        using var zip = new ZipArchive(memory, ZipArchiveMode.Read);
        string Read(string entry)
        {
            using var reader = new StreamReader(zip.GetEntry(entry)?.Open() ?? throw new InvalidDataException("Missing ZIP entry: " + entry), new System.Text.UTF8Encoding(false, true));
            return reader.ReadToEnd();
        }
        var specsText = Read("specs.json");
        using var specs = JsonDocument.Parse(specsText);
        Require(specs.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == ExpectedRaw, "ZIP CPU privacy mismatch.");
        var summaryText = Read("tweak-state.json");
        using var summary = JsonDocument.Parse(summaryText);
        Require(summary.RootElement.GetProperty("schemaVersion").GetInt32() == 1 && summary.RootElement.GetProperty("appliedProfiles").GetArrayLength() == 0
            && summary.RootElement.GetProperty("pendingRecovery").ValueKind == JsonValueKind.Null && summary.RootElement.GetProperty("pendingPhase").ValueKind == JsonValueKind.Null, "Summary metadata mismatch.");
        var errors = summary.RootElement.GetProperty("lastErrors").EnumerateArray().Select(x => x.GetString()).ToArray();
        Require(errors.SequenceEqual(new[] { @"C:\Users\<user>\AppData\recovery.log", @"C:\Users\<user>\AppData\prior.log" }), "Summary error privacy mismatch.");
        var log = Read("logs/app.log");
        Require(log == ExpectedLog, "Actual log-tail privacy mismatch.");
        RequirePrivate(specsText); RequirePrivate(summaryText); RequirePrivate(log);
        if (report)
        {
            var text = Read("report.txt");
            Require(text.Contains("Discord or email: " + Contact + Environment.NewLine, StringComparison.Ordinal)
                && text.Contains("Processor: " + ExpectedRaw + Environment.NewLine, StringComparison.Ordinal)
                && text.Contains("What went wrong:" + Environment.NewLine + ExpectedDescription + Environment.NewLine, StringComparison.Ordinal), "Saved report/contact mismatch.");
            RequirePrivate(text);
        }
        var files = new List<EvidenceFile> { SaveEvidence(evidence, name + ".zip", bytes) };
        foreach (var entry in zip.Entries)
        {
            var text = Read(entry.FullName);
            files.Add(SaveEvidence(evidence, name + "." + entry.FullName.Replace('/', '_'), System.Text.Encoding.UTF8.GetBytes(text)));
        }
        return files;
    }
    private static void RequirePrivate(string text)
    {
        foreach (var name in new[] { "Zqx Bob O'Neil", "Zqxbob", "Alice", "GAMER-PC", "S-1-5-21-11-22-33-44" })
            Require(!text.Contains(name, StringComparison.OrdinalIgnoreCase), "Private token remained in output.");
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(text));
        Require(json.RootElement.GetString() == text, "JSON string changed.");
        for (var index = 0; index < text.Length; index++)
            if (char.IsSurrogate(text[index]))
                Require(char.IsHighSurrogate(text[index]) && ++index < text.Length && char.IsLowSurrogate(text[index]), "Lone surrogate.");
    }
    private static EvidenceFile SaveEvidence(string directory, string name, byte[] bytes)
    {
        var path = Path.Combine(directory, name);
        File.WriteAllBytes(path, bytes);
        return new(name, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), bytes.LongLength);
    }
}
