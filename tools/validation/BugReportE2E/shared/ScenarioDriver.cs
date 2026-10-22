using System.Globalization;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace Roo70Fixture;
public sealed record Surface(BugReportViewModel Model, Func<Task> Attach, Func<Task> Save, Func<Task> Send, Func<Task> SeedVisible);
public sealed record CapturedSend(string Payload, byte[] Zip, string ZipPath, string WebhookUrl, int? StatusCode, double? RetryAfterSeconds, bool ThrewHttpRequestException);
public sealed class FixtureSender(int code) : IBugReportSender
{
    private int? statusCode = code;
    private TimeSpan? retryAfter;
    private bool throwHttpRequestException;
    public List<CapturedSend> Calls { get; } = new();
    internal void Configure(int? status, TimeSpan? retry = null, bool offline = false)
    {
        statusCode = status; retryAfter = retry; throwHttpRequestException = offline;
    }
    public Task<BugSendResult> SendAsync(string webhookUrl, string payloadJson, string zipPath, CancellationToken cancellationToken)
    {
        ScenarioDriver.Require(webhookUrl == ScenarioDriver.Webhook, "Unexpected synthetic URL.");
        Calls.Add(new(payloadJson, File.ReadAllBytes(zipPath), zipPath, webhookUrl, statusCode, retryAfter?.TotalSeconds, throwHttpRequestException));
        if (throwHttpRequestException) throw new HttpRequestException("Fixture network Offline after captured bytes.");
        return Task.FromResult(new BugSendResult(statusCode == 200, statusCode, retryAfter));
    }
}
public sealed record SceneState(bool OnlineAvailable, bool OfflineOnly, bool Busy, bool LoadingSpecs, bool CanAttach, bool CanSend,
    bool ShowSave, bool HasSavedReport, string? SavedPath, string Description, string Contact, string AttachmentText, string Status, string Cpu, int SpecCount);
public sealed record EvidenceFile(string File, string Sha256, long Bytes);
public sealed record SceneReceipt(string Name, SceneState State, int SenderCalls, IReadOnlyList<EvidenceFile> Evidence, string Scope);
public sealed record AttachmentRecord(string FilePath, string FileName, long Bytes);
public sealed record AttachmentRefreshReceipt(string Outcome, int SenderIndex, string FixtureUtc, int FixtureAdvanceSeconds,
    AttachmentRecord Before, AttachmentRecord? After, bool BeforeIsOriginal, bool BeforeIsPreviousRetained, bool? AfterIsDifferent,
    bool SavePreservedPreviousRecord, long BeforeActualBytes, long SenderActualBytes, long? RetainedActualBytes,
    string OriginalSha256, string SourceSha256, string SenderSha256, string? RetainedSha256,
    string SenderPath, string WebhookUrl, int? StatusCode, double? RetryAfterSeconds, bool ThrewHttpRequestException,
    string ExpectedCpu, string ActualStatus, string ActualLabel, bool OutgoingExists, SceneState AfterState,
    EvidenceFile BeforeZip, EvidenceFile SentZip, EvidenceFile Payload);
public sealed record ScenarioResult(IReadOnlyList<SceneReceipt> Scenes, IReadOnlyList<AttachmentRefreshReceipt> AttachmentRefresh);
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
    public static readonly string[] Names = ["offline-empty", "offline-attached", "offline-saved", "online-rate-limited", "online-offline", "online-failed", "online-fallback-saved", "online-sent"];
    public static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    public static string CanonicalDescription(string value) => value.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
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
    public static async Task<ScenarioResult> RunAsync(string data, string evidence,
        Func<BugReportService, FixtureSender, Task<Surface>> factory, Func<SceneReceipt, BugReportViewModel, Task> checkpoint, string scope)
    {
        RequireDisabledLog();
        var receipts = new List<SceneReceipt>();
        var refresh = new List<AttachmentRefreshReceipt>();
        async Task Emit(string name, Surface surface, FixtureSender sender, List<EvidenceFile> files)
        {
            Require(receipts.Count < Names.Length && Names[receipts.Count] == name, "Checkpoint ordering changed.");
            Require(!surface.Model.Busy && !surface.Model.LoadingSpecs, "Unsettled checkpoint.");
            RequireDisabledLog();
            var receipt = new SceneReceipt(name, State(surface.Model), sender.Calls.Count, files, scope);
            FixtureFiles.WriteNew(Path.Combine(evidence, name + ".semantic.json"), receipt);
            await checkpoint(receipt, surface.Model);
            receipts.Add(receipt);
        }
        async Task<(Surface Surface, FixtureSender Sender, string Reports, Action<TimeSpan> Advance, Func<DateTime> FixtureTime)> Create(string label, bool online, int code)
        {
            var scenario = Directory.CreateDirectory(Path.Combine(data, label)).FullName;
            var logs = Directory.CreateDirectory(Path.Combine(scenario, "logs")).FullName;
            var reports = Path.Combine(scenario, "reports");
            File.WriteAllText(Path.Combine(logs, "app.log"), RawLog);
            var sender = new FixtureSender(code);
            var fixtureTime = new DateTime(2026, 10, 21, 1, 2, 3, DateTimeKind.Utc);
            var service = new BugReportService(online ? Webhook : null, sender, reports, logs,
                new BugRedactor(@"C:\Users\" + @"Alice", "Alice", "GAMER-PC"), () => fixtureTime);
            var surface = await factory(service, sender);
            Require(surface.Model.Specs.Count == 9 && surface.Model.Specs.Single(x => x.Key == "windows").Value == "Fixture Windows"
                && surface.Model.Specs.Single(x => x.Key == "cpu").Value == "Fixture CPU", "Actual LoadAsync did not complete expected specs.");
            Require(!surface.Model.Busy && !surface.Model.LoadingSpecs && surface.Model.CanAttach, "Initial VM not ready.");
            return (surface, sender, reports, delta => fixtureTime += delta, () => fixtureTime);
        }
        async Task Seed(Surface surface)
        {
            surface.Model.Contact = Contact;
            surface.Model.Specs.Single(x => x.Key == "cpu").Value = Raw;
            foreach (var description in new[] { Description.Replace("\n", "\r\n", StringComparison.Ordinal), Description.Replace('\n', '\r'), Description })
            {
                surface.Model.Description = description;
                await surface.SeedVisible();
            }
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
        var failed = await Create("failed", true, 429);
        await Seed(failed.Surface);
        await failed.Surface.Attach();
        var vm = failed.Surface.Model;
        var original = ReadAttachment(vm) ?? throw new InvalidOperationException("Original attachment missing.");
        var originalBytes = File.ReadAllBytes(original.FilePath);
        Require(original.Bytes == originalBytes.LongLength, "Original attachment size stale.");
        var originalHash = Hash(originalBytes);
        var observedRecords = new List<BugAttachment> { original };
        BugAttachment? previous = null;
        var savePreserved = false;
        var cases = new[]
        {
            (Outcome: "RateLimited", Scene: Names[3], Suffix: " | rate-limited", Code: (int?)429, Advance: 0, Retry: (TimeSpan?)TimeSpan.FromSeconds(120), Offline: false,
                Status: "Too many reports are being sent right now. Try again in 120 seconds, or save the report to a file."),
            (Outcome: "Offline", Scene: Names[4], Suffix: " | offline", Code: (int?)null, Advance: 121, Retry: (TimeSpan?)null, Offline: true,
                Status: "Couldn't send the report. Check your internet connection and try again, or save the report to a file and send it yourself."),
            (Outcome: "Rejected", Scene: Names[5], Suffix: " | rejected", Code: (int?)404, Advance: 0, Retry: (TimeSpan?)null, Offline: false,
                Status: "The report couldn't be delivered. Try again later, or save the report to a file and send it yourself."),
            (Outcome: "Sent", Scene: Names[7], Suffix: " | later", Code: (int?)200, Advance: 61, Retry: (TimeSpan?)null, Offline: false,
                Status: "Thanks! Your report was sent to the developers.")
        };
        foreach (var item in cases)
        {
            var index = refresh.Count + 1;
            failed.Advance(TimeSpan.FromSeconds(item.Advance));
            vm.Specs.Single(x => x.Key == "cpu").Value = Raw + item.Suffix;
            await failed.Surface.SeedVisible();
            var before = ReadAttachment(vm) ?? throw new InvalidOperationException("Pre-send attachment missing.");
            Require(index == 1 ? ReferenceEquals(before, original) : ReferenceEquals(before, previous) && !ReferenceEquals(before, original), "Retry did not use the exact previous refreshed record.");
            var beforeBytes = File.ReadAllBytes(before.FilePath);
            var beforeHash = Hash(beforeBytes);
            Require(before.FilePath == original.FilePath && before.Bytes == beforeBytes.LongLength, "Pre-send attachment path/size differs.");
            Require(index == 1 ? beforeHash == originalHash : beforeHash == refresh[^1].RetainedSha256 && before.Bytes == refresh[^1].After!.Bytes, "Pre-send retained bytes changed.");
            var beforeFile = SaveEvidence(evidence, item.Scene + ".before.zip", beforeBytes);
            failed.Sender.Configure(item.Code, item.Retry, item.Offline);
            await failed.Surface.Send();
            await Wait(() => !vm.Busy && failed.Sender.Calls.Count == index, "Actual Send did not settle at expected cumulative call count.");
            Require(vm.Status == item.Status, "Outcome status mismatch.");
            var files = VerifySend(failed.Sender, item.Scene, evidence, ExpectedRaw + item.Suffix, index);
            var call = failed.Sender.Calls[index - 1];
            var senderHash = Hash(call.Zip);
            Require(call.ZipPath == before.FilePath && senderHash != beforeHash && senderHash != originalHash
                && refresh.All(row => row.SenderSha256 != senderHash), "Sender reused stale path/spec bytes.");
            var after = ReadAttachment(vm);
            byte[]? retained = null;
            if (item.Outcome != "Sent")
            {
                if (after is null) throw new InvalidOperationException("Retained outcome attachment missing.");
                Require(observedRecords.All(record => !ReferenceEquals(record, after)) && after.FilePath == before.FilePath, "Retained outcome reused an attachment record.");
                retained = File.ReadAllBytes(after.FilePath);
                Require(after.Bytes == new FileInfo(after.FilePath).Length && after.Bytes == retained.LongLength
                    && retained.AsSpan().SequenceEqual(call.Zip) && Hash(retained) == senderHash, "Retained record and wire bytes differ.");
                Require(vm.CanSend && vm.ShowSave && !vm.Busy && vm.AttachmentText == AttachmentLabel(after), "Retained attachment label/state mismatch.");
                observedRecords.Add(after);
            }
            else
            {
                Require(after is null && !File.Exists(before.FilePath) && !Directory.GetFiles(Path.Combine(failed.Reports, "outgoing"), "*.zip").Any(), "Sent attachment/file retained.");
                Require(vm.Description == "" && vm.Contact == "" && vm.AttachmentText == "No logs attached yet." && vm.SavedPath is null
                    && !vm.HasSavedReport && !vm.CanSend && !vm.ShowSave, "Sent reset state mismatch.");
            }
            Require(vm.Specs.Single(x => x.Key == "cpu").Value == Raw + item.Suffix, "Current CPU changed during send.");
            refresh.Add(new(item.Outcome, index, failed.FixtureTime().ToString("O", CultureInfo.InvariantCulture), item.Advance,
                Record(before), after is null ? null : Record(after), ReferenceEquals(before, original), ReferenceEquals(before, previous),
                after is null ? null : !ReferenceEquals(before, after), savePreserved, beforeBytes.LongLength, call.Zip.LongLength, retained?.LongLength,
                originalHash, beforeHash, senderHash, retained is null ? null : Hash(retained), call.ZipPath, call.WebhookUrl, call.StatusCode,
                call.RetryAfterSeconds, call.ThrewHttpRequestException, ExpectedRaw + item.Suffix, vm.Status, vm.AttachmentText, File.Exists(before.FilePath), State(vm),
                beforeFile, files.Single(x => x.File == item.Scene + ".zip"), files.Single(x => x.File == item.Scene + ".payload.json")));
            files.Add(beforeFile);
            await Emit(item.Scene, failed.Surface, failed.Sender, files);
            previous = after;
            if (item.Outcome == "Rejected")
            {
                await failed.Surface.Save();
                await Wait(() => !vm.Busy && vm.HasSavedReport, "Fallback Save did not settle.");
                savePreserved = ReferenceEquals(ReadAttachment(vm), previous);
                Require(savePreserved && previous is not null && File.ReadAllBytes(previous.FilePath).AsSpan().SequenceEqual(retained)
                    && new FileInfo(previous.FilePath).Length == previous.Bytes && vm.AttachmentText == AttachmentLabel(previous)
                    && vm.SavedPath != previous.FilePath && Path.GetDirectoryName(vm.SavedPath) == Path.Combine(failed.Reports, "saved")
                    && failed.Sender.Calls.Count == 3, "Fallback Save replaced the retained attachment or invoked sender.");
                await Emit(Names[6], failed.Surface, failed.Sender, VerifyZip(File.ReadAllBytes(vm.SavedPath!), true, Names[6], evidence, ExpectedRaw + " | rejected"));
            }
        }
        Require(receipts.Select(x => x.Name).SequenceEqual(Names) && refresh.Count == 4
            && refresh.Select(x => x.Outcome).SequenceEqual(new[] { "RateLimited", "Offline", "Rejected", "Sent" }), "Eight scenes and four ordered send receipts required.");
        RequireDisabledLog();
        return new(receipts, refresh);
    }
    private static BugAttachment? ReadAttachment(BugReportViewModel vm)
    {
        var field = typeof(BugReportViewModel).GetField("_attachment", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new MissingFieldException("Actual VM attachment field missing.");
        Require(field.FieldType == typeof(BugAttachment), "Actual VM attachment field type changed.");
        var value = field.GetValue(vm);
        Require(value is null or BugAttachment, "Actual VM attachment value type changed.");
        return (BugAttachment?)value;
    }
    private static AttachmentRecord Record(BugAttachment value) => new(value.FilePath, value.FileName, value.Bytes);
    private static string AttachmentLabel(BugAttachment value)
    {
        double bytes = value.Bytes;
        var units = new[] { "B", "KB", "MB", "GB", "TB" };
        var unit = 0;
        while (bytes >= 1024 && unit < 4) { bytes /= 1024; unit++; }
        return "Attached " + value.FileName + " (" + bytes.ToString(unit >= 3 ? "0.0" : "0", CultureInfo.InvariantCulture) + " " + units[unit] + ")";
    }
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static List<EvidenceFile> VerifySend(FixtureSender sender, string name, string evidence, string expectedCpu = ExpectedRaw, int expectedCalls = 1)
    {
        Require(sender.Calls.Count == expectedCalls, "Exact cumulative fake sender call count required.");
        var call = sender.Calls[expectedCalls - 1];
        using var payload = JsonDocument.Parse(call.Payload);
        var embed = payload.RootElement.GetProperty("embeds")[0];
        Require(embed.GetProperty("description").GetString() is string description && CanonicalDescription(description) == ExpectedDescription, "Typed description privacy mismatch.");
        var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
        Require(fields.Single(x => x.GetProperty("name").GetString() == "Processor").GetProperty("value").GetString() == expectedCpu, "Typed specs privacy mismatch.");
        Require(fields.Single(x => x.GetProperty("name").GetString() == "Discord or email").GetProperty("value").GetString() == Contact, "Intentional contact changed.");
        RequirePrivate(call.Payload);
        var files = VerifyZip(call.Zip, false, name, evidence, expectedCpu);
        files.Add(SaveEvidence(evidence, name + ".payload.json", System.Text.Encoding.UTF8.GetBytes(call.Payload)));
        return files;
    }
    private static List<EvidenceFile> VerifyZip(byte[] bytes, bool report, string name, string evidence, string expectedCpu = ExpectedRaw)
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
        Require(specs.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == expectedCpu, "ZIP CPU privacy mismatch.");
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
                && text.Contains("Processor: " + expectedCpu + Environment.NewLine, StringComparison.Ordinal)
                && CanonicalDescription(text).Contains("What went wrong:\n" + ExpectedDescription + "\n", StringComparison.Ordinal), "Saved report/contact mismatch.");
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
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Write(bytes);
            stream.Flush(true);
        }
        return new(name, Hash(bytes), bytes.LongLength);
    }
}
