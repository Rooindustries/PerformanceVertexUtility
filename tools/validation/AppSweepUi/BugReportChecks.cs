using System.IO.Compression;
using System.Text;
using System.Text.Json;
using RooIndustries.OptimizationSuite.Services;

static class BugReportChecks
{
    private const string Webhook = "https://discord.com/api/webhooks/123/fixture-token";

    private sealed class FakeSender : IBugReportSender
    {
        public List<(string Url, string Payload, string ZipPath)> Calls { get; } = new();
        public BugSendResult Result { get; set; } = new(true, 200);
        public Exception? Throw { get; set; }

        public Task<BugSendResult> SendAsync(string webhookUrl, string payloadJson, string zipPath, CancellationToken cancellationToken)
        {
            Calls.Add((webhookUrl, payloadJson, zipPath));
            if (Throw is not null) throw Throw;
            return Task.FromResult(Result);
        }
    }

    public static async Task OpenFolderAsync(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-report-folder-" + Guid.NewGuid().ToString("N"));
        var logs = Directory.CreateDirectory(Path.Combine(root, "logs")).FullName;
        var sender = new FakeSender();
        var savedService = RooIndustries.OptimizationSuite.App.BugReports;
        var savedObserver = AppLog.Observer;
        var observations = new List<string>();
        try
        {
            RooIndustries.OptimizationSuite.App.BugReports = new(null, sender, Path.Combine(root, "reports"), logs, new BugRedactor(null, null, null));
            var view = new RooIndustries.OptimizationSuite.ViewModels.BugReportViewModel { Description = "Private report folder fixture" };
            await view.LoadAsync(); await view.AttachAsync(); await view.SaveAsync();
            check(view.SavedPath is { } path && File.Exists(path), "The actual bug-report viewmodel saves a private report before Open folder");
            var method = typeof(RooIndustries.OptimizationSuite.ViewModels.BugReportViewModel).GetMethod("OpenFolder")!;
            var calls = Calls(method);
            check(calls.Any(call => call.DeclaringType == typeof(RooIndustries.Optimizer.RuntimeEnvironment) && call.Name == "OpenInExplorer") && !calls.Any(call => call.DeclaringType == typeof(System.Diagnostics.Process) && call.Name == "Start"), "The compiled bug-report opener uses the shared Explorer handoff");
            if (OperatingSystem.IsWindows())
            {
                check(ShellWindow() == IntPtr.Zero, "The no-shell proof runs in a Windows session without a desktop Explorer");
                AppLog.Observer = (_, detail) => observations.Add(detail ?? "");
                view.OpenFolder();
                check(observations.Any(text => text.Contains("Windows Explorer is not running. Sign in to Windows, then try again.", StringComparison.Ordinal)), "Open folder refuses through the shared shell guard when no desktop Explorer exists");
            }
            check(sender.Calls.Count == 0, "The folder proof never sends a report or contacts a webhook");
        }
        finally { AppLog.Observer = savedObserver; RooIndustries.OptimizationSuite.App.BugReports = savedService; Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The native report folder fixture is removed");
    }

    private static IEnumerable<System.Reflection.MethodBase> Calls(System.Reflection.MethodInfo method)
    {
        var codes = typeof(System.Reflection.Emit.OpCodes).GetFields().Where(field => field.FieldType == typeof(System.Reflection.Emit.OpCode)).Select(field => (System.Reflection.Emit.OpCode)field.GetValue(null)!).ToDictionary(code => unchecked((ushort)code.Value));
        var bytes = method.GetMethodBody()!.GetILAsByteArray()!;
        for (var offset = 0; offset < bytes.Length;)
        {
            var value = (ushort)bytes[offset++];
            if (value == 0xfe) value = (ushort)(0xfe00 | bytes[offset++]);
            var code = codes[value];
            if (code.OperandType == System.Reflection.Emit.OperandType.InlineMethod && method.Module.ResolveMethod(BitConverter.ToInt32(bytes, offset)) is { } called) yield return called;
            offset += code.OperandType switch
            {
                System.Reflection.Emit.OperandType.InlineNone => 0,
                System.Reflection.Emit.OperandType.ShortInlineBrTarget or System.Reflection.Emit.OperandType.ShortInlineI or System.Reflection.Emit.OperandType.ShortInlineVar => 1,
                System.Reflection.Emit.OperandType.InlineVar => 2,
                System.Reflection.Emit.OperandType.InlineI8 or System.Reflection.Emit.OperandType.InlineR => 8,
                System.Reflection.Emit.OperandType.InlineSwitch => 4 + 4 * BitConverter.ToInt32(bytes, offset),
                _ => 4,
            };
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetShellWindow")]
    private static extern IntPtr ShellWindow();

    public static async Task RunAsync(Action<bool, string> check)
    {
        var calls = Calls(typeof(RooIndustries.OptimizationSuite.ViewModels.BugReportViewModel).GetMethod("OpenFolder")!);
        check(calls.Any(call => call.DeclaringType == typeof(RooIndustries.Optimizer.RuntimeEnvironment) && call.Name == "OpenInExplorer") && !calls.Any(call => call.DeclaringType == typeof(System.Diagnostics.Process) && call.Name == "Start"), "The compiled bug-report opener uses the shared Explorer handoff");
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-bug-report-" + Guid.NewGuid().ToString("N"));
        var logs = Path.Combine(root, "logs");
        Directory.CreateDirectory(logs);
        try
        {
            var redactor = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
            var now = new DateTime(2026, 9, 26, 12, 0, 0, DateTimeKind.Utc);
            BugReportService Service(string? url, FakeSender sender) => new(url, sender, Path.Combine(root, "reports"), logs, redactor, () => now);
            BugSpec[] specs = [new("windows", "Windows", "Windows 11 Pro 24H2"), new("cpu", "Processor", "Fixture CPU"), new("app", "App version", "0.1.0 beta")];
            BugReport Report(string description, string? contact = null, IReadOnlyList<BugSpec>? values = null) => new("0.1.0 beta", values ?? specs, contact, description);

            File.WriteAllText(Path.Combine(logs, "app.log"),
                "2026-09-26 [backend] C:\\Users\\Alice\\AppData\\Local\\x failed\n"
                + "2026-09-26 [backend] {\"path\":\"C:\\\\Users\\\\alice\\\\Desktop\"} on GAMER-PC for alice\n"
                + "2026-09-26 [start] Run as administrator, CurrentUser key, ALICE~1 short path\n");

            var offlineSender = new FakeSender();
            var noUrl = Service(null, offlineSender);
            check(!noUrl.OnlineAvailable, "A build without a webhook has no online reporting");
            check(!Service("http://discord.com/api/webhooks/1/x", offlineSender).OnlineAvailable && !Service("https://example.com/api/webhooks/1/x", offlineSender).OnlineAvailable
                && !Service("https://discord.com/other/1/x", offlineSender).OnlineAvailable && Service(Webhook, offlineSender).OnlineAvailable,
                "Only https Discord webhook addresses enable online reporting");
            check(BugReportService.ReadWebhook(typeof(BugReportChecks).Assembly) is null, "An assembly without the embedded webhook reads as not configured");
            check(BugReportService.ParseWebhook("\uFEFFurl=" + Webhook + "\r\n") == Webhook && BugReportService.ParseWebhook("url=\r\n") is null
                && BugReportService.ParseWebhook("url=") is null && BugReportService.ParseWebhook("") is null,
                "The build-time webhook file yields the URL when set and nothing when the variable was empty");
            var offlineAttachment = noUrl.CreateAttachment(specs, "{}");
            var notConfigured = await noUrl.SendAsync(Report("Crash on apply"), offlineAttachment);
            check(notConfigured.Status == BugSendStatus.NotConfigured && offlineSender.Calls.Count == 0, "Without a webhook, Send never contacts the network");
            var saved = noUrl.SaveReport(Report("Crash on apply", "gamer#1"), offlineAttachment);
            using (var savedZip = ZipFile.OpenRead(saved))
            {
                var reportText = Read(savedZip, "report.txt");
                check(File.Exists(saved) && reportText.Contains("Crash on apply", StringComparison.Ordinal) && reportText.Contains("gamer#1", StringComparison.Ordinal)
                    && savedZip.GetEntry("specs.json") is not null && savedZip.GetEntry("logs/app.log") is not null,
                    "Save report to a file writes the message, specs and logs to one zip");
            }

            check(!BugReportService.CanSubmit("Crash on apply", null), "Send stays locked until logs are attached");
            check(!BugReportService.CanSubmit("   ", offlineAttachment), "Send stays locked until the description is filled");
            check(BugReportService.CanSubmit("Crash on apply", offlineAttachment), "Send unlocks with a description and attached logs");
            var gatedSender = new FakeSender();
            var gated = Service(Webhook, gatedSender);
            var needsLogs = await gated.SendAsync(Report("Crash on apply"), null);
            var needsText = await gated.SendAsync(Report(" "), offlineAttachment);
            check(needsLogs.Status == BugSendStatus.NeedsDetails && needsText.Status == BugSendStatus.NeedsDetails && gatedSender.Calls.Count == 0,
                "The service refuses to send without attached logs or a description");

            var attachment = gated.CreateAttachment(specs, BugReportService.TweakSummaryJson(["my-settings"], true, "applying", ["Failed for Alice on GAMER-PC", null]));
            using (var zip = ZipFile.OpenRead(attachment.FilePath))
            {
                var log = Read(zip, "logs/app.log");
                var summary = Read(zip, "tweak-state.json");
                var all = log + summary + Read(zip, "specs.json");
                check(!all.Contains("alice", StringComparison.OrdinalIgnoreCase) && !all.Contains("GAMER-PC", StringComparison.OrdinalIgnoreCase),
                    "Logs, tweak summary and specs in the zip never contain the Windows user name or PC name");
                check(log.Contains("%USERPROFILE%", StringComparison.Ordinal) && log.Contains("<pc-name>", StringComparison.Ordinal)
                    && log.Contains("administrator", StringComparison.Ordinal) && log.Contains("CurrentUser", StringComparison.Ordinal),
                    "Redaction replaces identities without damaging ordinary words");
                using var state = JsonDocument.Parse(summary);
                check(state.RootElement.GetProperty("appliedProfiles")[0].GetString() == "my-settings" && state.RootElement.GetProperty("pendingRecovery").GetBoolean()
                    && state.RootElement.GetProperty("lastErrors").GetArrayLength() == 1,
                    "The tweak summary lists applied profiles, pending recovery and non-empty errors");
            }
            var sid = new BugRedactor(null, null, null).Redact(@"HKEY_USERS\S-1-5-21-111111111-222222222-333333333-1001\Software and S-1-5-18");
            check(!sid.Contains("111111111") && sid.Contains(@"HKEY_USERS\<sid>\Software") && sid.Contains("S-1-5-18"), "A user account SID is removed while well-known system SIDs stay readable");
            var admin = new BugRedactor(null, "Admin", null).Redact("Run as administrator. admin signed in.");
            check(admin == "Run as administrator. <user> signed in.", "A short user name is only redacted as a whole word");
            var accented = new BugRedactor(@"C:\Users\José", "José", "PC-JOSÉ").Redact("{\"p\":\"C:\\\\Users\\\\Jos\\u00e9\"} José on PC-JOSÉ");
            check(!accented.Contains("José", StringComparison.OrdinalIgnoreCase) && !accented.Contains("Jos\\u00e9", StringComparison.OrdinalIgnoreCase),
                "Accented user names are redacted in plain and JSON-escaped text");
            var spaced = new BugRedactor(@"C:\Users\John Smith", "John Smith", "PC").Redact(@"{""p"":""C:\\Users\\John Smith\\x""} C:/Users/John Smith/y");
            check(!spaced.Contains("John", StringComparison.Ordinal) && !spaced.Contains("Smith", StringComparison.Ordinal),
                "A user name with a space is fully redacted in escaped and forward-slash paths");
            var renamed = new BugRedactor(@"C:\Users\jsmith", "John Smith", "PC").Redact(@"C:/Users/John Smith/y and {""p"":""C:\\Users\\John Smith\\z""}");
            check(!renamed.Contains("John", StringComparison.Ordinal) && !renamed.Contains("Smith", StringComparison.Ordinal),
                "A user name that differs from the profile folder is still fully redacted inside other paths");
            var others = redactor.Redact(@"C:\Users\Bob\AppData and {""p"":""D:\\Users\\Carol\\x""} and C:\Users\Public\Desktop and C:\Users\Default User\x");
            check(!others.Contains("Bob", StringComparison.Ordinal) && !others.Contains("Carol", StringComparison.Ordinal)
                && others.Contains(@"C:\Users\Public\Desktop", StringComparison.Ordinal) && others.Contains(@"C:\Users\Default User\x", StringComparison.Ordinal),
                "Other accounts' profile folders are redacted while shared Windows folders stay readable");
            var known = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC", ["John Smith", "O'Connor", "Client", "Fixture", "Public", "Default User"]);
            var otherNames = known.Redact(@"C:\Users\John Smith\AppData and C:\Users\O'Connor\Desktop and {""p"":""C:\\Users\\John Smith\\x"",""q"":""C:\\Users\\O\u0027Connor\\y""} and 'C:\Users\Client' or C:/Users/Fixture/z");
            check(!otherNames.Contains("Smith", StringComparison.Ordinal) && !otherNames.Contains("Connor", StringComparison.Ordinal)
                && !otherNames.Contains("Client", StringComparison.Ordinal) && !otherNames.Contains("Fixture", StringComparison.Ordinal)
                && otherNames.Contains(@"C:\Users\<user>\AppData", StringComparison.Ordinal) && otherNames.Contains(@"C:\\Users\\<user>\\y", StringComparison.Ordinal)
                && otherNames.Contains(@"'C:\Users\<user>' or C:/Users/<user>/z", StringComparison.Ordinal),
                "Other accounts on this PC are fully redacted even with spaces or apostrophes in their folder names");
            var context = known.Redact(@"Cannot access 'C:\Users\Client' while checking 'AppData\Local\fixture.log'. Scanning C:\Users\Fixture for leftovers in AppData\Local and C:\Users\Public\Desktop");
            check(context == @"Cannot access 'C:\Users\<user>' while checking 'AppData\Local\fixture.log'. Scanning C:\Users\<user> for leftovers in AppData\Local and C:\Users\Public\Desktop",
                "Redacting another account keeps the rest of the log line and shared folders readable");
            var edges = known.Redact(@"Scanning (C:\Users\John Smith), C:\Users\O'Connor. Done");
            check(edges == @"Scanning (C:\Users\<user>), C:\Users\<user>. Done", "A profile name followed by punctuation is fully redacted");
            var prefixOther = new BugRedactor(@"C:\Users\Alice", "Alice", "PC", ["Client", "Client two"]).Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixOwn = new BugRedactor(@"C:\Users\Client", "Client", "PC", ["Client", "Client two"]).Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixLonger = new BugRedactor(@"C:\Users\Client two", "Client two", "PC", ["Client", "Client two"]).Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixUser = new BugRedactor(@"C:\Users\jsmith", "Client", "PC", ["jsmith", "Client two"]).Redact(@"C:\Users\Client two\AppData");
            check(prefixOther == @"C:\Users\<user>\AppData and C:\Users\<user>\Desktop" && prefixOwn == @"C:\Users\<user>\AppData and %USERPROFILE%\Desktop"
                && prefixLonger == @"%USERPROFILE%\AppData and C:\Users\<user>\Desktop" && prefixUser == @"C:\Users\<user>\AppData",
                "Account names that start with another account's name are redacted whole, whichever account is signed in");

            var longText = "@everyone " + new string('x', 10_000);
            var payload = BugReportService.BuildPayload(Report(longText, "<@123> me@example.com",
                specs.Select(spec => spec with { Value = new string('v', 2_000) }).ToArray()), attachment.FileName);
            using (var document = JsonDocument.Parse(payload))
            {
                var rootElement = document.RootElement;
                var parse = rootElement.GetProperty("allowed_mentions").GetProperty("parse");
                check(parse.ValueKind == JsonValueKind.Array && parse.GetArrayLength() == 0 && !rootElement.TryGetProperty("content", out _),
                    "Payload suppresses every mention and carries no message content");
                var embed = rootElement.GetProperty("embeds")[0];
                var description = embed.GetProperty("description").GetString()!;
                var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
                var title = embed.GetProperty("title").GetString()!;
                var total = title.Length + description.Length + fields.Sum(field => field.GetProperty("name").GetString()!.Length + field.GetProperty("value").GetString()!.Length);
                check(description.Length <= BugReportService.DescriptionLimit && description.EndsWith("...", StringComparison.Ordinal) && description.StartsWith("@everyone", StringComparison.Ordinal),
                    "A long description is truncated with an ellipsis inside the embed");
                check(fields.All(field => field.GetProperty("value").GetString()!.Length <= BugReportService.FieldValueLimit)
                    && fields.Any(field => field.GetProperty("value").GetString()!.EndsWith("...", StringComparison.Ordinal)),
                    "Long spec values are truncated to the field limit");
                check(total <= BugReportService.EmbedTotalLimit, "The whole embed stays within the 6000 character limit");
                check(title.Contains("0.1.0 beta", StringComparison.Ordinal), "The embed title carries the app version");
                check(rootElement.GetProperty("attachments")[0].GetProperty("filename").GetString() == attachment.FileName, "The payload names the attached zip");
            }
            using (var blank = JsonDocument.Parse(BugReportService.BuildPayload(Report("Short"), "x.zip")))
            {
                var contact = blank.RootElement.GetProperty("embeds")[0].GetProperty("fields").EnumerateArray().Last();
                check(contact.GetProperty("name").GetString() == "Discord or email" && contact.GetProperty("value").GetString() == "Not given",
                    "A blank contact is sent as Not given instead of an empty field");
            }

            var sender = new FakeSender();
            var service = Service(Webhook, sender);
            var first = service.CreateAttachment(specs, "{}");
            var edited = specs.Select(spec => spec.Key == "cpu" ? spec with { Value = "Edited CPU" } : spec).ToArray();
            var sent = await service.SendAsync(Report("Crash on apply", values: edited), first);
            check(sent.Status == BugSendStatus.Sent && sender.Calls.Count == 1 && sender.Calls[0].Url == Webhook, "A complete report is sent once to the webhook");
            check(!File.Exists(first.FilePath), "A sent attachment is removed from the outgoing folder");
            var typedSender = new FakeSender();
            var typed = Service(Webhook, typedSender);
            var pasted = specs.Select(spec => spec.Key == "cpu" ? spec with { Value = @"Alice's CPU, see C:\Users\Alice\specs.txt on GAMER-PC" } : spec).ToArray();
            var typedSent = await typed.SendAsync(Report(@"Crash for Alice at C:\Users\Alice\AppData\x.log on GAMER-PC", "alice#1", pasted), typed.CreateAttachment(specs, "{}"));
            using (var typedBody = JsonDocument.Parse(typedSender.Calls.Single().Payload))
            {
                var embed = typedBody.RootElement.GetProperty("embeds")[0];
                var values = embed.GetProperty("fields").EnumerateArray().ToDictionary(field => field.GetProperty("name").GetString()!, field => field.GetProperty("value").GetString()!);
                check(typedSent.Status == BugSendStatus.Sent && embed.GetProperty("description").GetString() == @"Crash for <user> at %USERPROFILE%\AppData\x.log on <pc-name>"
                    && values["Processor"] == @"<user>'s CPU, see %USERPROFILE%\specs.txt on <pc-name>" && values["Discord or email"] == "alice#1",
                    "Text the user typed or pasted into the report is redacted before it is sent, while the contact they gave stays as typed");
            }
            var typedSaved = typed.SaveReport(Report(@"Crash for Alice on GAMER-PC", "alice#1", pasted), typed.CreateAttachment(specs, "{}"));
            using (var typedZip = ZipFile.OpenRead(typedSaved))
            {
                var reportText = Read(typedZip, "report.txt");
                check(!reportText.Contains("Alice", StringComparison.Ordinal) && !reportText.Contains("GAMER-PC", StringComparison.Ordinal) && reportText.Contains("Crash for <user> on <pc-name>", StringComparison.Ordinal),
                    "A saved report file redacts the description the user typed");
            }
            var second = service.CreateAttachment(specs, "{}");
            var throttled = await service.SendAsync(Report("Again"), second);
            check(throttled.Status == BugSendStatus.Throttled && throttled.Wait > TimeSpan.Zero && sender.Calls.Count == 1, "A second send within 60 seconds is blocked on the client");
            now = now.AddSeconds(61);
            sender.Result = new(false, 429, TimeSpan.FromSeconds(120));
            var limited = await service.SendAsync(Report("Again"), second);
            check(limited.Status == BugSendStatus.RateLimited && limited.Wait >= TimeSpan.FromSeconds(119) && File.Exists(second.FilePath),
                "A Discord rate limit keeps the report and waits for Retry-After");
            now = now.AddSeconds(121);
            sender.Throw = new HttpRequestException("offline");
            var offline = await service.SendAsync(Report("Again"), second);
            check(offline.Status == BugSendStatus.Offline && service.WaitBeforeSend == TimeSpan.Zero && File.Exists(second.FilePath),
                "No network keeps the report and allows an immediate retry");
            sender.Throw = null;
            sender.Result = new(false, 404);
            var rejected = await service.SendAsync(Report("Again", values: edited), second);
            check(rejected.Status == BugSendStatus.Rejected && File.Exists(second.FilePath), "A rejected webhook keeps the report for saving");
            using (var zip = ZipFile.OpenRead(second.FilePath))
            {
                var sentSpecs = Read(zip, "specs.json");
                check(sentSpecs.Contains("Edited CPU", StringComparison.Ordinal) && !sentSpecs.Contains("Fixture CPU", StringComparison.Ordinal),
                    "Sending refreshes specs.json from the current form");
            }

            var noise = new StringBuilder();
            var random = new Random(7);
            var buffer = new byte[3072];
            while (noise.Length < 20_000_000)
            {
                random.NextBytes(buffer);
                noise.Append(Convert.ToBase64String(buffer)).Append('\n');
            }
            noise.Append("LAST-LINE-MARKER\n");
            File.WriteAllText(Path.Combine(logs, "app.log"), noise.ToString());
            File.WriteAllText(Path.Combine(logs, "app.log.old"), noise.ToString(0, 5_000_000));
            var large = service.CreateAttachment(specs, "{}");
            check(large.Bytes <= BugReportService.MaxZipBytes && new FileInfo(large.FilePath).Length == large.Bytes, "Twenty megabytes of logs still produce a zip under 8 MB");
            var small = service.CreateAttachment(specs, "{}", 200_000);
            using (var zip = ZipFile.OpenRead(small.FilePath))
                check(small.Bytes <= 200_000 && Read(zip, "logs/app.log").TrimEnd().EndsWith("LAST-LINE-MARKER", StringComparison.Ordinal),
                    "A tighter size cap keeps only the most recent log lines");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static string Read(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name) ?? throw new InvalidDataException(name + " is missing from the report zip.");
        using var reader = new StreamReader(entry.Open());
        return reader.ReadToEnd();
    }
}
