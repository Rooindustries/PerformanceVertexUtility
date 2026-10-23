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
            var known = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
            var otherNames = known.Redact(@"C:\Users\John Smith\AppData and C:\Users\O'Connor\Desktop and {""p"":""C:\\Users\\John Smith\\x"",""q"":""C:\\Users\\O\u0027Connor\\y""} and 'C:\Users\Client' or C:/Users/Fixture/z");
            check(!otherNames.Contains("Smith", StringComparison.Ordinal) && !otherNames.Contains("Connor", StringComparison.Ordinal)
                && !otherNames.Contains("Client", StringComparison.Ordinal) && !otherNames.Contains("Fixture", StringComparison.Ordinal)
                && otherNames.Contains(@"C:\Users\<user>\AppData", StringComparison.Ordinal) && otherNames.Contains(@"C:\\Users\\<user>\\y", StringComparison.Ordinal)
                && otherNames.Contains(@"'C:\Users\<user> C:/Users/<user>/z", StringComparison.Ordinal),
                "Other accounts on this PC are fully redacted even with spaces or apostrophes in their folder names");
            var context = known.Redact(@"Cannot access 'C:\Users\Client' while checking 'AppData\Local\fixture.log'. Scanning C:\Users\Fixture for leftovers in AppData\Local and C:\Users\Public\Desktop");
            check(context == @"Cannot access 'C:\Users\<user>\Local\fixture.log'. Scanning C:\Users\<user>\Local and C:\Users\Public\Desktop",
                "Redacting an ambiguous profile consumes uncertain prose and keeps context beyond hard delimiters");
            var edges = known.Redact(@"Scanning (C:\Users\John Smith), C:\Users\O'Connor. Done");
            check(edges == @"Scanning (C:\Users\<user>), C:\Users\<user>", "A profile name followed by ambiguous prose is fully redacted");
            var prefixOther = new BugRedactor(@"C:\Users\Alice", "Alice", "PC").Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixOwn = new BugRedactor(@"C:\Users\Client", "Client", "PC").Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixLonger = new BugRedactor(@"C:\Users\Client two", "Client two", "PC").Redact(@"C:\Users\Client two\AppData and C:\Users\Client\Desktop");
            var prefixUser = new BugRedactor(@"C:\Users\jsmith", "Client", "PC").Redact(@"C:\Users\Client two\AppData");
            check(prefixOther == @"C:\Users\<user>\AppData and C:\Users\<user>\Desktop" && prefixOwn == @"C:\Users\<user>\AppData and %USERPROFILE%\Desktop"
                && prefixLonger == @"%USERPROFILE%\AppData and C:\Users\<user>\Desktop" && prefixUser == @"C:\Users\<user>\AppData",
                "Account names that start with another account's name are redacted whole, whichever account is signed in");
            var escapedOwn = new BugRedactor(@"C:\Users\Client o'Connor", "Client o'Connor", "PC").Redact(@"{""p"":""C:\\Users\\Client o\u0027Connor\\x"",""q"":""C:\\Users\\Client\\y""}");
            var caseVariant = new BugRedactor(@"C:\Users\Alice", "Alice", "PC").Redact(@"{""p"":""C:\\Users\\JOS\u00C9 SMITH\\x""}");
            check(escapedOwn == @"{""p"":""%USERPROFILE%\\x"",""q"":""C:\\Users\\<user>\\y""}" && caseVariant == @"{""p"":""C:\\Users\\<user>\\x""}",
                "JSON-escaped and differently cased account names are matched on their decoded text");
            var unusual = new BugRedactor(@"C:\Users\Alice", "Alice", "PC").Redact(JsonSerializer.Serialize(new { p = @"C:\Users\" + "李" + @"\x" }) + @" C:\Users\ John Smith\AppData");
            check(unusual == @"{""p"":""C:\\Users\\<user>\\x""} C:\Users\<user>\AppData", "One-letter and space-led account folder names are redacted as Windows stores them");
            check(known.Redact(edges) == edges && known.Redact(otherNames) == otherNames && known.Redact(context) == context,
                "Log text already redacted when it was written stays the same when the bug report redacts it again");
            var plain = new BugRedactor(null, "user", "PC").Redact("<user> signed in and user left on PC with <pc-name> and <sid>");
            check(plain == "<user> signed in and <user> left on <pc-name> with <pc-name> and <sid>", "An account named like a placeholder never turns a redacted name into <<user>>");
            RedactorBoundaries(check, root, logs, specs);
            await RedactorComponentsAsync(check, root, logs);
            await AccountFormsAsync(check, root);

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

    public static void RedactorBoundaries(Action<bool, string> check, string root, string logs, BugSpec[] specs)
    {
        var own = new BugRedactor(@"C:\Users\John Smith", "John Smith", "PC");
        check(own.Redact(@"Skipped C:\Users\John Smith: Access is denied.") == "Skipped %USERPROFILE%: Access is denied.",
            "A colon after the current profile keeps the complete denial message without a surname");
        check(JsonSerializer.Deserialize<string>(own.Redact(JsonSerializer.Serialize(@"C:\Users\John Smith: denied"))) == "%USERPROFILE%: denied",
            "A JSON-escaped current profile followed by a colon has no name suffix");
        var other = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
        foreach (var name in new[] { "John Smith", "Bob" })
        {
            var path = @"C:\Users\" + name + ": denied";
            check(other.Redact(path) == @"C:\Users\<user>: denied"
                && JsonSerializer.Deserialize<string>(other.Redact(JsonSerializer.Serialize(path))) == @"C:\Users\<user>: denied",
                "A plain or JSON-escaped " + name + " profile before a colon keeps no surname or last letter");
        }
        check(other.Redact(@"C:\Users\Bob and D:\Games") == @"C:\Users\<user> D:\Games",
            "Redacting an ambiguous profile keeps the adjacent drive outside the private component");
        var sender = new FakeSender();
        var service = new BugReportService(null, sender, Path.Combine(root, "boundary-reports"), logs, other);
        var prefixes = new[] { "\n", "\t", "\r\n" };
        var errors = prefixes.SelectMany(prefix => new[] { prefix + @"C:\Users\Bob\x: denied", prefix + @"C:\Users\John Smith\x: denied", prefix + @"C:\Users\Alice\x: denied" }).ToArray();
        var expected = prefixes.SelectMany(prefix => new[] { prefix + @"C:\Users\<user>\x: denied", prefix + @"C:\Users\<user>\x: denied", prefix + @"%USERPROFILE%\x: denied" }).ToArray();
        var tweakState = BugReportService.TweakSummaryJson([], false, null, errors);
        check(errors.All(error => tweakState.Contains(JsonSerializer.Serialize(error)[1..^1], StringComparison.Ordinal)),
            "The attachment fixture serializes newline, tab and carriage-return prefixes before the profile paths");
        var attachment = service.CreateAttachment(specs, tweakState);
        using (var zip = ZipFile.OpenRead(attachment.FilePath))
        {
            var summary = Read(zip, "tweak-state.json");
            using var document = JsonDocument.Parse(summary);
            var actual = document.RootElement.GetProperty("lastErrors").EnumerateArray().Select(error => error.GetString()).ToArray();
            check(actual.SequenceEqual(expected) && !summary.Contains("Bob", StringComparison.Ordinal) && !summary.Contains("Smith", StringComparison.Ordinal),
                "The attached JSON redacts all nine serialized-prefix paths and preserves every separator and denial message");
        }
        check(sender.Calls.Count == 0, "Profile-boundary attachment checks never send a report");
        var unknown = new BugRedactor(null, null, null);
        foreach (var name in new[] { "Public-Bob", "Default.Carol" })
        {
            var path = @"C:\Users\" + name + @"\x";
            check(unknown.Redact(path) == @"C:\Users\<user>\x"
                && JsonSerializer.Deserialize<string>(unknown.Redact(JsonSerializer.Serialize(path))) == @"C:\Users\<user>\x",
                "An unknown " + name + " folder is private in plain and serialized paths");
        }
        foreach (var path in new[] { @"C:\Users\Public\Desktop", @"C:\Users\Default User\x" })
        {
            check(unknown.Redact(path) == path && unknown.Redact(JsonSerializer.Serialize(path)) == JsonSerializer.Serialize(path),
                "The shared folder " + path + " stays readable in plain and serialized paths");
        }
        var placeholders = new BugRedactor(null, "user", "PC");
        const string canonical = "<user> <user> <pc-name> <sid>";
        var shielded = placeholders.Redact("<USER> user <PC-NAME> <SID>");
        check(shielded == canonical && placeholders.Redact(shielded) == canonical,
            "Mixed-case identity placeholders stay canonical and stable for an account named user");
        const string controls = "Text \u0001 \u0002 \u0003 remains readable.";
        const string escapedControls = @"Text \u0001 \u0002 \u0003 remains readable.";
        var escaped = placeholders.Redact(controls);
        check(escaped == escapedControls && placeholders.Redact(escaped) == escapedControls,
            "Literal sentinel controls become readable escapes and remain stable without false identity labels");
    }

    public static async Task RedactorComponentsAsync(Action<bool, string> check, string root, string logs)
    {
        void Exact(BugRedactor redactor, string input, string expected)
        {
            foreach (var serialized in new[] { false, true })
            {
                var source = serialized ? JsonSerializer.Serialize(input) : input;
                var actual = redactor.Redact(source);
                try
                {
                    var decoded = serialized ? JsonSerializer.Deserialize<string>(actual) : actual;
                    check(decoded == expected && redactor.Redact(actual) == actual,
                        "Complete component " + (serialized ? "JSON " : "plain ") + JsonSerializer.Serialize(input) + " => " + JsonSerializer.Serialize(decoded));
                }
                catch (JsonException error)
                {
                    check(false, "Invalid redacted JSON for " + JsonSerializer.Serialize(input) + ": " + error.Message);
                }
            }
        }
        var other = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
        var bob = new BugRedactor(@"C:\Users\Bob", "Bob", "GAMER-PC");
        var transports = new List<(BugRedactor Redactor, string Input, string Expected)>
        {
            (other, @"D:\Users\John Smith\file", @"D:\Users\<user>\file"),
            (bob, @"D:\Users\" + "Bob.Smith" + @"\x", @"D:\Users\<user>\x"),
            (other, @"Cannot find path 'C:\Users\Bob\x'", @"Cannot find path 'C:\Users\<user>\x'"),
            (other, @"'C:\Users\O'Connor", @"'C:\Users\<user>"),
            (other, @"C:\Users\" + "John Sm...", @"C:\Users\<user>..."),
        };
        var literalNames = new[] { "u0012345", "u0009876", "u0022999", "u0123456", "Ubeda", "uFace", "U2018x" };
        foreach (var name in literalNames)
        {
            var profile = @"C:\Users\" + name;
            transports.Add((other, profile + @"\x", @"C:\Users\<user>\x"));
            transports.Add((new BugRedactor(profile, name, "GAMER-PC"), profile + @"\x", @"%USERPROFILE%\x"));
        }
        foreach (var drive in new[] { "C", "D" })
        foreach (var separator in new[] { ".", "-", ",", ";", "=", "@", "#", "!", "$", "~", "(", ")", "[", "{", "%20", " ", "'" })
        foreach (var (tail, remaining) in new[] { (@"\x", @"\x"), ("", ""), (": denied", ": denied"), (" finished.", ".") })
            Exact(bob, drive + @":\Users\Bob" + separator + "Smith" + tail, drive + @":\Users\<user>" + remaining);
        foreach (var prefix in new[] { @"\u0027", @"\u0022", @"\u003C", @"\u0026" })
            transports.Add((other, "x" + prefix + @"C:\\Users\\Bob\\x", "x" + prefix + @"C:\\Users\\<user>\\x"));
        foreach (var name in new[] { "Public,", "Default'", "!!!" })
            transports.Add((other, @"C:\Users\" + name + @"\x", @"C:\Users\<user>" + (name == "!!!" ? "" : name[^1].ToString()) + @"\x"));
        foreach (var shared in new[] { @"C:\Users\Public\Desktop", @"C:\Users\Default User\x" })
            Exact(other, shared, shared);
        foreach (var name in new[] { "Alice!", "!!!" })
            Exact(new BugRedactor(@"C:\Users\" + name, name, "GAMER-PC"), @"C:\Users\" + name + @"\x", @"%USERPROFILE%\x");
        const string ownName = "Émile";
        var own = new BugRedactor(@"C:\Users\" + ownName, ownName, "GAMER-PC");
        var nested = @"C:\Users\" + ownName + @"\x";
        for (var depth = 0; depth <= 5; depth++)
        {
            var actual = own.Redact(nested);
            try
            {
                var decoded = actual;
                for (var level = 0; level < depth; level++) decoded = JsonSerializer.Deserialize<string>(decoded)!;
                check(decoded == @"%USERPROFILE%\x" && own.Redact(actual) == actual,
                    "An exact accented own component maps safely through JSON depth " + depth + ": " + actual);
            }
            catch (JsonException error)
            {
                check(false, "Nested own profile JSON depth " + depth + " is invalid: " + error.Message);
            }
            nested = JsonSerializer.Serialize(nested);
        }
        var relaxed = new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        foreach (var name in literalNames.Append(ownName))
        foreach (var drive in new[] { "C", "D" })
        foreach (var tail in new[] { "", @"\x" })
        foreach (var isOwn in new[] { false, true })
        foreach (var options in new JsonSerializerOptions?[] { null, relaxed })
        {
            var redactor = isOwn ? new BugRedactor(@"C:\Users\" + name, name, "GAMER-PC") : other;
            var input = drive + @":\Users\" + name + tail;
            var expected = isOwn && drive == "C" ? "%USERPROFILE%" + tail : drive + @":\Users\<user>" + tail;
            var encoder = options is null ? "default" : "relaxed";
            for (var depth = 0; depth <= (options is null ? 5 : 3); depth++)
            {
                var actual = redactor.Redact(input);
                try
                {
                    var decoded = actual;
                    for (var level = 0; level < depth; level++) decoded = JsonSerializer.Deserialize<string>(decoded)!;
                    check(decoded == expected && redactor.Redact(actual) == actual,
                        "Literal-u or Unicode component " + encoder + " depth " + depth + " own=" + isOwn + " " + JsonSerializer.Serialize(input) + " => " + JsonSerializer.Serialize(decoded));
                }
                catch (JsonException error)
                {
                    check(false, "Invalid nested " + encoder + " JSON depth " + depth + " own=" + isOwn + " for " + JsonSerializer.Serialize(input) + ": " + error.Message);
                }
                input = JsonSerializer.Serialize(input, options);
            }
        }
        var jsonCases = new[]
        {
            (other, @"""C:\\Users\\Bob\u005cx""", @"""C:\\Users\\<user>\u005cx"""),
            (other, @"""C:\\Users\\Bob\u0022: denied""", @"""C:\\Users\\<user>\u0022: denied"""),
            (other, @"""C:\\Users\\Bob\u003e: denied""", @"""C:\\Users\\<user>\u003e: denied"""),
            (other, @"""C:\\Users\\O\u0027Connor\\x""", @"""C:\\Users\\<user>\\x"""),
            (new BugRedactor(@"N:\Users\Alice", "Alice", "GAMER-PC"), @"""\n:\\Users\\Alice\\x""", @"""\n:\\Users\\<user>\\x"""),
            (other, @"""\u003C:\\Users\\Alice\\x""", @"""\u003C:\\Users\\<user>\\x"""),
        };
        transports.AddRange(jsonCases);
        var separatorStart = transports.Count;
        var separatorCases = new List<(BugRedactor Redactor, string Input, string Expected)>();
        foreach (var control in new[] { "\n", "\r", "\t", "\b", "\f", "\r\n" })
        {
            foreach (var profileRoot in new[] { @"C:\Users\", @"D:/Users\" })
            {
                var input = "Scanning " + profileRoot + control + "Found 3 profiles";
                separatorCases.Add((other, input, input));
            }
            separatorCases.Add((other, @"C:\Users\Alice\" + control + "next line", @"%USERPROFILE%\" + control + "next line"));
        }
        var listing = @"Source : C:\Users\" + "\r\n" + @"Dest : D:\Backup\";
        separatorCases.Add((other, listing, listing));
        transports.AddRange(separatorCases);
        foreach (var shared in new[] { "Public", "Default", "Default User", "All Users", "" })
        foreach (var drive in new[] { "C", "D" })
            transports.Add((other, @"C:\Users\" + shared + drive + @":\Users\Alice",
                @"C:\Users\<user>" + (drive == "C" && shared.Length != 0 ? "%USERPROFILE%" : drive + @":\Users\<user>")));
        foreach (var profileRoot in new[] { @"C:\Users\", "D:/Users/" })
            transports.Add((other, profileRoot, profileRoot));
        foreach (var name in new[] { "%USERPROFILE%", "Private%USERPROFILE%Suffix" })
            transports.Add((other, @"C:\Users\" + name + @"\x", @"C:\Users\<user>\x"));
        var separatorTransports = transports.Skip(separatorStart).ToHashSet();
        foreach (var name in new[] { "nFound", "rRunner", "tTester", "bBob", "fFixture" })
        foreach (var profileRoot in new[] { @"C:\Users\", @"D:/Users\" })
            separatorCases.Add((other, profileRoot + name + @"\x", profileRoot + @"<user>\x"));
        foreach (var (redactor, raw, expected) in separatorCases)
        foreach (var options in new JsonSerializerOptions?[] { null, relaxed })
        {
            var input = raw;
            var encoder = options is null ? "default" : "relaxed";
            for (var depth = 0; depth <= (options is null ? 5 : 3); depth++)
            {
                var actual = redactor.Redact(input);
                try
                {
                    var decoded = actual;
                    for (var level = 0; level < depth; level++) decoded = JsonSerializer.Deserialize<string>(decoded)!;
                    check(decoded == expected && redactor.Redact(actual) == actual,
                        "Root separator " + encoder + " depth " + depth + " " + JsonSerializer.Serialize(raw) + " => " + JsonSerializer.Serialize(decoded));
                }
                catch (JsonException error)
                {
                    check(false, "Invalid root separator " + encoder + " JSON depth " + depth + " for " + JsonSerializer.Serialize(raw) + ": " + error.Message);
                }
                input = JsonSerializer.Serialize(input, options);
            }
        }
        foreach (var (redactor, input, expected) in transports)
        {
            Exact(redactor, input, expected);
            var sender = new FakeSender { Result = new(false, 404) };
            var service = new BugReportService(Webhook, sender, Path.Combine(root, "component-" + Guid.NewGuid().ToString("N")), logs, redactor);
            BugSpec[] specs = [new("cpu", "Processor", input)];
            var attachment = service.CreateAttachment(specs, BugReportService.TweakSummaryJson([], false, null, [input]));
            using (var zip = ZipFile.OpenRead(attachment.FilePath))
            {
                try
                {
                    using var summary = JsonDocument.Parse(Read(zip, "tweak-state.json"));
                    using var values = JsonDocument.Parse(Read(zip, "specs.json"));
                    var error = summary.RootElement.GetProperty("lastErrors")[0].GetString();
                    check(error == expected && values.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == expected,
                        "Attachment component privacy and valid JSON for " + JsonSerializer.Serialize(input));
                    if (input.StartsWith('"'))
                    {
                        using var original = JsonDocument.Parse(input);
                        using var redacted = JsonDocument.Parse(error!);
                        using var expectedValue = JsonDocument.Parse(expected);
                        check(redacted.RootElement.GetString() == expectedValue.RootElement.GetString(),
                            "An attached serialized error remains valid inner JSON for " + JsonSerializer.Serialize(input));
                    }
                }
                catch (JsonException error)
                {
                    check(false, "Attachment JSON is invalid for " + JsonSerializer.Serialize(input) + ": " + error.Message);
                }
            }
            var report = new BugReport("fixture", specs, "fixture#1", input);
            var outcome = await service.SendAsync(report, attachment);
            using (var payload = JsonDocument.Parse(sender.Calls.Single().Payload))
            {
                var embed = payload.RootElement.GetProperty("embeds")[0];
                var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
                check(outcome.Status == BugSendStatus.Rejected && sender.Calls.Count == 1
                    && embed.GetProperty("description").GetString() == expected && fields[0].GetProperty("value").GetString() == expected
                    && fields[1].GetProperty("value").GetString() == "fixture#1",
                    "A fake send redacts the complete typed description and specs for " + JsonSerializer.Serialize(input));
            }
            using var saved = ZipFile.OpenRead(service.SaveReport(report, attachment));
            check(Read(saved, "report.txt").Contains("What went wrong:" + Environment.NewLine + expected + Environment.NewLine, StringComparison.Ordinal),
                "A saved report redacts the complete typed description for " + JsonSerializer.Serialize(input));
            if (separatorTransports.Contains((redactor, input, expected)))
            {
                try
                {
                    using var summary = JsonDocument.Parse(Read(saved, "tweak-state.json"));
                    using var values = JsonDocument.Parse(Read(saved, "specs.json"));
                    check(summary.RootElement.GetProperty("lastErrors")[0].GetString() == expected
                        && values.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == expected,
                        "Saved report component privacy and valid JSON for " + JsonSerializer.Serialize(input));
                }
                catch (JsonException error)
                {
                    check(false, "Saved report component JSON is invalid for " + JsonSerializer.Serialize(input) + ": " + error.Message);
                }
            }
        }
        const string partialProfile = @"C:\Users\" + "John Sm";
        var cut = new string('x', 2000 - partialProfile.Length - 3) + @"C:\Users\John Smith\file";
        var truncated = BugReportService.Truncate(cut, 2000);
        var truncatedSender = new FakeSender();
        var truncatedService = new BugReportService(null, truncatedSender, Path.Combine(root, "truncated-component"), logs, other);
        var truncatedAttachment = truncatedService.CreateAttachment([], BugReportService.TweakSummaryJson([], false, null, [cut]));
        using (var zip = ZipFile.OpenRead(truncatedAttachment.FilePath))
        {
            using var summary = JsonDocument.Parse(Read(zip, "tweak-state.json"));
            var actual = summary.RootElement.GetProperty("lastErrors")[0].GetString();
            check(truncated.EndsWith(partialProfile + "...", StringComparison.Ordinal) && actual == other.Redact(truncated)
                && actual!.EndsWith(@"C:\Users\<user>...", StringComparison.Ordinal) && !actual.Contains("John", StringComparison.Ordinal) && !actual.Contains("Sm", StringComparison.Ordinal),
                "A profile cut at the 2000-character summary boundary keeps no partial account name");
        }
        check(truncatedSender.Calls.Count == 0, "Truncated component attachment checks never send a report");
        var longRoot = @"C:\Users" + new string('\\', 7 * 1024 * 1024);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var redaction = Task.Run(() => other.Redact(longRoot + "Fixture"));
        var completed = await Task.WhenAny(redaction, Task.Delay(TimeSpan.FromSeconds(5)));
        check(completed == redaction && redaction.IsCompletedSuccessfully && redaction.Result == longRoot + "<user>",
            "A 7 MB profile separator run preserves every separator and redacts within five seconds: completed="
                + (completed == redaction) + " elapsedMs=" + clock.Elapsed.TotalMilliseconds.ToString("F2"));
        var width = 1 << 18;
        var wideRoot = @"C:\Users" + new string('\\', width);
        var wideUnit = new string('\\', width - 1) + "u0041";
        var wideRun = new System.Text.StringBuilder("a");
        var wideLength = 7 * 1024 * 1024 - wideRoot.Length;
        while (wideRun.Length + wideUnit.Length <= wideLength) wideRun.Append(wideUnit);
        wideRun.Append('a', wideLength - wideRun.Length);
        var wideInput = wideRoot + wideRun;
        var wideClock = System.Diagnostics.Stopwatch.StartNew();
        var wideRedaction = Task.Run(() => other.Redact(wideInput));
        var wideCompleted = await Task.WhenAny(wideRedaction, Task.Delay(TimeSpan.FromSeconds(5)));
        check(wideCompleted == wideRedaction && wideRedaction.IsCompletedSuccessfully && wideRedaction.Result == wideRoot + "<user>",
            "A 7 MB almost-matching profile separator run redacts within five seconds: width=" + width + " length=" + wideInput.Length
                + " completed=" + (wideCompleted == wideRedaction) + " elapsedMs=" + wideClock.Elapsed.TotalMilliseconds.ToString("F2"));
        var markerMacroInput = new System.Text.StringBuilder("C:/Users/<user>");
        const string encodedMarkerTail = @"\u003Cpc-name\u003E" + "Zqxlong/x";
        while (markerMacroInput.Length + 13 + encodedMarkerTail.Length <= 7 * 1024 * 1024) markerMacroInput.Append("%USERPROFILE%");
        var markerPadding = 7 * 1024 * 1024 - markerMacroInput.Length - encodedMarkerTail.Length;
        markerMacroInput.Append(@"\u003Cpc-name\u003E").Append('A', markerPadding).Append("Zqxlong/x");
        var markerClock = System.Diagnostics.Stopwatch.StartNew();
        var markerRedaction = Task.Run(() => other.Redact(markerMacroInput.ToString()));
        var markerCompleted = await Task.WhenAny(markerRedaction, Task.Delay(TimeSpan.FromSeconds(5)));
        check(markerCompleted == markerRedaction && markerRedaction.IsCompletedSuccessfully && markerRedaction.Result == "C:/Users/<user>/x",
            "A 7 MB marker and macro chain before an encoded marker stays private within five seconds: completed="
                + (markerCompleted == markerRedaction) + " elapsedMs=" + markerClock.Elapsed.TotalMilliseconds.ToString("F2"));
        await LegacyComponentBoundariesAsync(check, root);
    }

    private static async Task LegacyComponentBoundariesAsync(Action<bool, string> check, string root)
    {
        var redactor = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
        var relaxed = new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        var cases = new List<(string Input, string Expected, bool DefaultEncoder)>();
        foreach (var profileRoot in new[] { @"C:\Users\", "C:/Users/" })
        {
            var separator = profileRoot[^1].ToString();
            foreach (var marker in new[] { "<user>", "<USER>", "<pc-name>", "<Pc-Name>", "<sid>", "<SID>" })
            foreach (var suffix in new[] { ".Zqxsmith", "-Zqxsmith", "(Zqxold)", " Zqxsmith" })
                cases.Add((profileRoot + marker + suffix + separator + "x", profileRoot + "<user>" + (suffix.EndsWith(')') ? ")" : "") + separator + "x", false));
            cases.Add((profileRoot + "<pc-name>.Zqxadmin" + separator + "x", profileRoot + "<user>" + separator + "x", false));
            foreach (var suffix in new[] { "%USERPROFILE%Zqxsmith", "%USERPROFILE%.Zqxsmith" })
                cases.Add((profileRoot + "<user>" + suffix + separator + "x", profileRoot + "<user>" + separator + "x", false));
            cases.Add((profileRoot + @"<user>%USERPROFILE% C:\Users\Carol\x", profileRoot + @"<user> C:\Users\<user>\x", false));
            foreach (var marker in new[] { "<user>", "<pc-name>", "<sid>" })
            foreach (var suffix in new[] { "", ".", ")", ",;!)]}' " })
                cases.Add((profileRoot + marker + suffix, profileRoot + marker + suffix, false));
            foreach (var suffix in new[] { "", separator + "x", @"C:\Users\Carol\x" })
                cases.Add((profileRoot + "<user>%USERPROFILE%" + suffix,
                    profileRoot + "<user>%USERPROFILE%" + suffix.Replace("Carol", "<user>", StringComparison.Ordinal), false));
        }
        foreach (var original in new[] { @"C:\\Users\\" + "Alice.Zqxsmith" + @"\\x", "C:/Users/" + "Alice.Zqxsmith" + "/x" })
        {
            var legacy = original.Replace(@"C:\Users\Alice", "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
            legacy = System.Text.RegularExpressions.Regex.Replace(legacy, @"(?<![\p{L}\p{N}_])Alice(?![\p{L}\p{N}_])", "<user>", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
            check(legacy.Contains("<user>.Zqxsmith", StringComparison.Ordinal), "The legacy log fixture applies the previous profile and whole-word identity rules before serialization");
            cases.Add((legacy, original.Replace("Alice.Zqxsmith", "<user>", StringComparison.Ordinal), false));
        }
        foreach (var drive in new[] { "C", "D" })
        foreach (var separator in new[] { @"\", "/" })
        {
            var profileRoot = drive + ":" + separator + "Users" + separator;
            foreach (var (prefix, suffix) in new[] { ("Pub", @"\u006Cic"), ("Defaul", @"\u0074"), ("All Us", @"\u0065rs") })
                cases.Add((profileRoot + prefix + suffix + separator + "x",
                    profileRoot + "<user>" + (separator == @"\" ? suffix : "") + separator + "x", true));
            foreach (var nextDrive in new[] { "C", "D" })
            foreach (var nextSeparator in new[] { @"\", "/" })
            {
                var nextRoot = @"\u002" + nextDrive + ":" + nextSeparator + "Users" + nextSeparator;
                var retainedRoot = separator == "/" && nextDrive == "D" ? ":" + nextSeparator + "Users" + nextSeparator : nextRoot;
                cases.Add((profileRoot + "Bob" + nextRoot + "Carol" + nextSeparator + "x",
                    profileRoot + "<user>" + retainedRoot + "<user>" + nextSeparator + "x", true));
            }
            foreach (var name in new[] { "Bob", "Émile", "O'Connor", "uFace" })
                cases.Add((profileRoot + name + separator + "x", profileRoot + "<user>" + separator + "x", true));
            foreach (var shared in new[] { "Public", "Default", "Default User", "All Users" })
                cases.Add((profileRoot + shared + separator + "x", profileRoot + shared + separator + "x", true));
        }
        cases.Add((@"C:\Users\Bob\Ubeda\x", @"C:\Users\<user>\Ubeda\x", true));
        foreach (var (name, escape) in new[] { ("Public", @"Pub\u006Cic"), ("Default", @"Defaul\u0074"), ("Default User", @"Defaul\u0074 User"), ("All Users", @"All Us\u0065rs") })
        {
            var encoded = @"""C:\\Users\\" + escape + @"\\x""";
            check(JsonSerializer.Deserialize<string>(encoded) == @"C:\Users\" + name + @"\x", "The shared-name Unicode fixture has a provably shorter escape than its profile separator: " + name);
            cases.Add((encoded, @"""C:\\Users\\<user>\\x""", true));
            cases.Add((@"""C:/Users/" + escape + @"/x""", @"""C:/Users/<user>/x""", true));
        }
        cases.Add((@"""C:\\Users\\B\u006Fb\\x""", @"""C:\\Users\\<user>\\x""", true));
        var spanStart = cases.Count;
        foreach (var suffix in new[] { @"\u003Cusername\u003E\x", @"\u0001\x", @"\<user>\x", @"\u003Cuser\\u003E\x" })
            cases.Add((@"C:\Users\" + "Zqxother" + suffix, @"C:\Users\<user>" + suffix, true));
        cases.Add((@"C:\Users\" + "Zqxother<user>" + @"\x", @"C:\Users\<user>\x", true));
        foreach (var drive in new[] { "C", "D" })
        foreach (var separator in new[] { @"\", "/" })
        foreach (var emoji in new[] { "😀", "😌" })
        {
            var profileRoot = drive + ":" + separator + "Users" + separator;
            cases.Add((profileRoot + "Bob" + emoji + ":" + separator + "x", profileRoot + "<user>:" + separator + "x", true));
            foreach (var nextDrive in new[] { "C", "D" })
            foreach (var nextSeparator in new[] { @"\", "/" })
            {
                var nextRoot = nextDrive + ":" + nextSeparator + "Users" + nextSeparator;
                cases.Add((profileRoot + "Bob" + emoji + nextRoot + "Carol" + nextSeparator + "x",
                    profileRoot + "<user>" + nextRoot + "<user>" + nextSeparator + "x", true));
            }
        }
        foreach (var value in Enumerable.Range(0, 32).Where(value => value is not (1 or 2 or 3)))
        {
            var control = ((char)value).ToString();
            cases.Add((@"C:\Users\" + "Public" + @"C:\Users\Alice" + control, @"C:\Users\<user>%USERPROFILE%" + control, true));
            var chain = @"C:\Users\<user>%USERPROFILE%%USERPROFILE%" + control;
            cases.Add((chain, chain, false));
        }
        foreach (var profileRoot in new[] { @"C:\Users\", "C:/Users/" })
        foreach (var suffix in new[] { "", profileRoot[^1] + "x", ".Zqxsmith" + profileRoot[^1] + "x" })
        {
            var chain = profileRoot + "<user>%USERPROFILE%%USERPROFILE%" + suffix;
            cases.Add((chain, suffix.StartsWith('.') ? profileRoot + "<user>" + profileRoot[^1] + "x" : chain, false));
        }
        foreach (var profileRoot in new[] { @"C:\Users\", "C:/Users/" })
        foreach (var marker in new[] { "<user>", "<USER>", "<pc-name>", "<Pc-Name>", "<sid>", "<SID>" })
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
        {
            var separator = profileRoot[^1].ToString();
            foreach (var suffix in new[] { marker + "Zqxsmith", "'Zqxsmith", "😀Zqxsmith", "\u007FZqxsmith", "AZqxsmith" })
                cases.Add((profileRoot + marker + macro + suffix + separator + "x", profileRoot + "<user>" + separator + "x", false));
            var encodedRoot = profileRoot.Replace(@"\", @"\\", StringComparison.Ordinal);
            var encodedSeparator = separator.Replace(@"\", @"\\", StringComparison.Ordinal);
            foreach (var suffix in new[] { @"\u0027", @"\uD83D\uDE00", @"\u007F", @"\u0041" })
                cases.Add(("\"" + encodedRoot + marker + macro + suffix + "Zqxsmith" + encodedSeparator + "x\"",
                    "\"" + encodedRoot + "<user>" + encodedSeparator + "x\"", false));
            foreach (var delimiter in new[] { @"\u0001", @"\u005c", @"\u0022", @"\u003A" })
            {
                var input = "\"" + encodedRoot + marker + macro + delimiter + "tail\"";
                var expected = "\"" + encodedRoot + marker.ToLowerInvariant() + macro + delimiter + "tail\"";
                cases.Add((input, expected, false));
            }
            var colon = profileRoot + marker + macro + ": denied";
            cases.Add((colon, profileRoot + marker.ToLowerInvariant() + macro + ": denied", false));
        }
        var reviewerSuffix = "Sm" + "ith";
        cases.Add((@"C:\Users\<user>%USERPROFILE%<user>" + reviewerSuffix + @"\x", @"C:\Users\<user>\x", false));
        cases.Add((@"""C:\\Users\\<user>%USERPROFILE%\u0027" + reviewerSuffix + @"\\x""", @"""C:\\Users\\<user>\\x""", false));
        cases.Add((@"C:/Users/<user>%USERPROFILE%\uD83D\uDE00" + reviewerSuffix + "/x", "C:/Users/<user>/x", false));
        cases.Add((@"Z://Users//<sid>Qx%USERPROFILE%\\u007F\\u007FZv", "Z://Users//<user>", false));
        var postMacroMarkers = new[] { "<user>", "<USER>", "<pc-name>", "<Pc-Name>", "<sid>", "<SID>" };
        foreach (var profileRoot in new[] { @"C:\Users\", "C:/Users/" })
        foreach (var marker in postMacroMarkers)
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
        {
            var separator = profileRoot[^1].ToString();
            foreach (var suffix in new[] { marker + "Zqxsmith", "'Zqxsmith", "😀Zqxsmith", "\u007FZqxsmith", "AZqxsmith" })
                cases.Add((profileRoot + marker + macro + suffix + separator + "x", profileRoot + "<user>" + separator + "x", true));
        }
        foreach (var (open, close) in new[] { ("003C", "003E"), ("003c", "003e") })
        foreach (var marker in postMacroMarkers)
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
        {
            var escapedMarker = @"\u" + open + marker[1..^1] + @"\u" + close;
            var escapedUser = @"\u" + open + "user" + @"\u" + close;
            cases.Add(("C:/Users/<user>" + macro + escapedMarker + "Zqxbob/x", "C:/Users/<user>/x", true));
            cases.Add(("C:/Users/" + escapedUser + macro + escapedMarker + "Zqx Bob O'Neil/x", "C:/Users/<user>/x", true));
            cases.Add((@"C:\\Users\\" + escapedUser + macro + escapedMarker + "Zqx Bob O'Neil" + @"\\x", @"C:\\Users\\<user>\\x", true));
        }
        var defaultPostMacroInput = JsonSerializer.Serialize("C:/Users/<user>%USERPROFILE%<user>" + "Zqxbob/x");
        cases.Add((defaultPostMacroInput, JsonSerializer.Serialize("C:/Users/<user>/x", relaxed), true));
        foreach (var marker in postMacroMarkers)
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
            cases.Add((JsonSerializer.Serialize(@"C:\Users\<user>" + macro + marker + "Zqx Bob O'Neil" + @"\x"),
                JsonSerializer.Serialize(@"C:\Users\<user>\x", relaxed), true));
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
        foreach (var suffix in new[] { @"\u003Cusername\u003EZqxtail/x", @"\u003Cusers\u003EZqxtail/x", @"\u003Cuser", @"\u003Cuser\\u003EZqxtail/x",
            @"\u003Cpc-nam\u003EZqxtail/x", @"\u0001Zqxtail/x", @"\u0022Zqxtail/x", @"\u003AZqxtail/x", @"\u005cZqxtail/x", @"\u002fZqxtail/x",
            @"\u000AZqxtail/x", ": denied", "\"quoted", "/x", "\tline", "\nline" })
        {
            var input = "C:/Users/<user>" + macro + suffix;
            cases.Add((input, input, true));
        }
        foreach (var profileRoot in new[] { @"C:\Users\\", @"C:/Users\\", @"C:\\Users\\", "C://Users//" })
        {
            var separator = profileRoot.EndsWith('/') ? "//" : @"\";
            foreach (var component in new[] { @"Pub\u006Cic", @"Defaul\u0074", @"Defaul\u0074 User", @"All Us\u0065rs" })
                cases.Add((profileRoot + component + separator + "x", profileRoot + "<user>" + separator + "x", true));
            foreach (var shared in new[] { "Public", "Default", "Default User", "All Users" })
                cases.Add((profileRoot + shared + separator + "x", profileRoot + shared + separator + "x", true));
        }
        var emissionStart = cases.Count;
        var emissionOwners = new Dictionary<string, BugRedactor>(StringComparer.Ordinal);
        var joinedName = "Zqxown " + "Smith";
        var joinedOwn = @"C:\Users\" + joinedName;
        var emissionRedactor = new BugRedactor(joinedOwn, joinedName, "GAMER-PC");
        var emissionExact = new[]
        {
            @"C:/Users/" + joinedOwn + @"\u0041pp",
            @"C:\Users/" + @"u0012345\u0041ppé." + joinedOwn + @"\Ubedau0041"
        };
        cases.Add((emissionExact[0], @"C:/Users/<user>C:\Users\<user>\u0041pp", true));
        cases.Add((emissionExact[1], @"C:\Users/<user>.C:\Users\<user>\Ubedau0041", true));
        foreach (var profileRoot in new[] { "C:/Users/", @"C:\\Users\\", @"C:\Users/" })
        foreach (var punctuation in new[] { "", ".", "'" })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uFace", @"\x" })
        {
            cases.Add((profileRoot + "Zqxother" + punctuation + profileRoot + joinedName + joinedOwn + tail,
                profileRoot + "<user>" + punctuation + "%USERPROFILE%" + @"C:\Users\<user>" + tail, true));
            cases.Add((profileRoot + "Zqxother" + punctuation + profileRoot + joinedName + profileRoot + joinedName + joinedOwn + tail,
                profileRoot + "<user>" + punctuation + "%USERPROFILE%%USERPROFILE%" + @"C:\Users\<user>" + tail, true));
        }
        foreach (var profileRoot in new[] { "C:/Users/", @"C:\\Users\\", @"C:\Users/" })
        foreach (var marker in new[] { "<user>", "<pc-name>", "<sid>", "<USER>", "<Pc-Name>", "<SID>" })
        foreach (var punctuation in new[] { "", ".", "'" })
        foreach (var macro in new[] { "%USERPROFILE%", "%USERPROFILE%%USERPROFILE%" })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uFace", @"\x" })
            cases.Add((profileRoot + marker + punctuation + macro + joinedOwn + tail,
                profileRoot + marker.ToLowerInvariant() + punctuation + macro + @"C:\Users\<user>" + tail, true));
        var quotedChainInput = "C:/Users/<user>'%USERPROFILE%" + joinedOwn + @"\u0041pp";
        var quotedChainExpected = @"C:/Users/<user>'%USERPROFILE%C:\Users\<user>\u0041pp";
        cases.Add((JsonSerializer.Serialize(quotedChainInput, relaxed).Replace("'", @"\u0027", StringComparison.Ordinal),
            JsonSerializer.Serialize(quotedChainExpected, relaxed).Replace("'", @"\u0027", StringComparison.Ordinal), true));
        foreach (var profileRoot in new[] { "C:/Users/", @"C:\\Users\\", @"C:\Users/" })
        foreach (var marker in new[] { "<user>", "<USER>", "<pc-name>", "<Pc-Name>", "<sid>", "<SID>" })
        foreach (var punctuation in new[] { "", " ", ".", "'", ",;!)]}' " })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uFace" })
            cases.Add((profileRoot + marker + punctuation + joinedOwn + tail,
                profileRoot + marker.ToLowerInvariant() + punctuation + @"C:\Users\<user>" + tail, true));
        foreach (var marker in new[] { "<user>", "<USER>", "<pc-name>", "<Pc-Name>", "<sid>", "<SID>" })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uFace" })
            cases.Add((@"C:\Users\" + marker + joinedOwn + tail,
                @"C:\Users\" + marker.ToLowerInvariant() + "%USERPROFILE%" + tail, true));
        foreach (var prefix in new[] { @"\\?\", @"\\.\", @"\??\" })
        {
            cases.Add((prefix + joinedOwn + @"\AppData\x", prefix + @"%USERPROFILE%\AppData\x", true));
            cases.Add((prefix + @"C:\Users\" + "Zqxother" + @"\x", prefix + @"C:\Users\<user>\x", true));
        }
        foreach (var profileRoot in new[] { "C:/Users/", @"C:\Users/", "C://Users//" })
        foreach (var (prefix, punctuation) in new[] { ("", ""), ("Zqxother", ""), ("Zqxother.", "."), ("Zqxother;", ";"), ("Zqxother'", "'"), ("Zqxother')", "')") })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uD83D\uDE00x", @"\x", "/x" })
        {
            var input = profileRoot + prefix + joinedOwn + tail;
            var expected = profileRoot + "<user>" + punctuation + @"C:\Users\<user>" + tail;
            cases.Add((input, expected, true));
            cases.Add(("Scanning \"" + input + "\"", "Scanning \"" + expected + "\"", true));
            cases.Add(("Scanning '" + input + "'", "Scanning '" + expected + "'", true));
            if (punctuation == "'")
                cases.Add((JsonSerializer.Serialize(input, relaxed).Replace("'", @"\u0027", StringComparison.Ordinal),
                    JsonSerializer.Serialize(expected, relaxed).Replace("'", @"\u0027", StringComparison.Ordinal), true));
        }
        foreach (var punctuation in new[] { "", ".", ";", "'" })
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\uD83D\uDE00x", @"\x", "/x" })
        {
            var input = @"C:/Users/" + @"ZqxotherC:\\Users\\" + joinedName + punctuation + joinedOwn + tail;
            var expected = @"C:/Users/<user>C:\\Users\\<user>" + punctuation + @"C:\Users\<user>" + tail;
            cases.Add((input, expected, true));
            var fourthRoot = @"C:\\Users\\";
            var fourthTail = tail.Replace(@"\", @"\\", StringComparison.Ordinal);
            cases.Add((@"C:/Users/" + @"ZqxotherC:\\Users\\" + joinedName + punctuation + joinedOwn + punctuation + fourthRoot + joinedName + fourthTail,
                @"C:/Users/<user>C:\\Users\\<user>" + punctuation + @"C:\Users\<user>" + punctuation + fourthRoot + "<user>" + fourthTail, true));
            if (punctuation.Length > 0)
            {
                var escape = punctuation == "." ? @"\u002E" : punctuation == ";" ? @"\u003B" : @"\u0027";
                cases.Add((JsonSerializer.Serialize(input, relaxed).Replace(punctuation, escape, StringComparison.Ordinal),
                    JsonSerializer.Serialize(expected, relaxed).Replace(punctuation, escape, StringComparison.Ordinal), true));
            }
        }
        foreach (var tail in new[] { @"\u0041pp", @"\Ubeda", @"\x", "/x" })
        {
            cases.Add((@"C:\Users\" + @"Zqxother" + joinedOwn + tail, @"C:\Users\<user>%USERPROFILE%" + tail, true));
            cases.Add((joinedOwn + tail, "%USERPROFILE%" + tail, true));
            cases.Add((@"C:/Users/" + @"Zqxother""" + joinedOwn + tail, @"C:/Users/<user>""%USERPROFILE%" + tail, true));
        }
        foreach (var shared in new[] { "Public", "Default", "Default User", "All Users" })
            cases.Add((@"C:\Users\" + shared + @"\boundary-control", @"C:\Users\" + shared + @"\boundary-control", true));
        foreach (var ownName in new[] { "Émile", "😀Fixture", "u0012345", "O'Connor" })
        {
            var profile = @"C:\Users\" + ownName;
            var owner = new BugRedactor(profile, ownName, "GAMER-PC");
            var unicodeCases = new List<(string Input, string Expected)>
            {
                ("C:/Users/" + "Zqxother" + "C:/Users/" + ownName + profile + @"\u0041pp", @"C:/Users/<user>%USERPROFILE%C:\Users\<user>\u0041pp"),
                (@"C:/Users/<pc-name>%USERPROFILE%%USERPROFILE%" + profile + @"\u0041pp", @"C:/Users/<pc-name>%USERPROFILE%%USERPROFILE%C:\Users\<user>\u0041pp"),
                (@"C:/Users/<user>" + profile + @"\u0041pp", @"C:/Users/<user>C:\Users\<user>\u0041pp"),
                (@"C:\\Users\\<pc-name>." + profile + @"\uFace", @"C:\\Users\\<pc-name>.C:\Users\<user>\uFace"),
                (@"C:/Users/" + @"Zqxother" + profile + @"\x", @"C:/Users/<user>C:\Users\<user>\x"),
                (@"C:\Users\" + @"Zqxother" + profile + @"\x", @"C:\Users\<user>%USERPROFILE%\x"),
                (profile + @"\u0041pp", @"%USERPROFILE%\u0041pp"),
                (@"C:/Users/" + @"Zqxother" + profile + @"\u0041pp", @"C:/Users/<user>C:\Users\<user>\u0041pp"),
                (@"C:\Users/" + @"u0012345\u0041ppé." + profile + @"\Ubedau0041", @"C:\Users/<user>.C:\Users\<user>\Ubedau0041"),
                (@"C:/Users/" + @"ZqxotherC:\\Users\\" + ownName + profile + @"\u0041pp", @"C:/Users/<user>C:\\Users\\<user>C:\Users\<user>\u0041pp"),
                (@"C:/Users/" + @"ZqxotherC:\\Users\\" + ownName + "." + profile + @"\x", @"C:/Users/<user>C:\\Users\\<user>.C:\Users\<user>\x"),
                (@"C:/Users/" + @"ZqxotherC:\\Users\\" + ownName + profile + @"C:\\Users\\" + ownName + @"\\x", @"C:/Users/<user>C:\\Users\\<user>C:\Users\<user>C:\\Users\\<user>\\x")
            };
            foreach (var prefix in new[] { @"\\?\", @"\\.\", @"\??\" })
                unicodeCases.Add((prefix + profile + @"\x", prefix + @"%USERPROFILE%\x"));
            unicodeCases.Add((JsonSerializer.Serialize(@"C:\Users/" + @"Zqxother'" + profile + @"\x", relaxed).Replace("'", @"\u0027", StringComparison.Ordinal),
                JsonSerializer.Serialize(@"C:\Users/<user>'C:\Users\<user>\x", relaxed).Replace("'", @"\u0027", StringComparison.Ordinal)));
            foreach (var (input, expected) in unicodeCases)
            {
                cases.Add((input, expected, true));
                emissionOwners.Add(input, owner);
            }
        }
        var emissionInputs = cases.Skip(emissionStart).Select(item => item.Input).ToHashSet(StringComparer.Ordinal);
        bool WholeUnicode(string value)
        {
            for (var index = 0; index < value.Length; index++)
            {
                if (char.IsHighSurrogate(value[index]))
                {
                    if (++index >= value.Length || !char.IsLowSurrogate(value[index])) return false;
                }
                else if (char.IsLowSurrogate(value[index])) return false;
            }
            return true;
        }
        var spanInputs = cases.Skip(spanStart).Select(item => item.Input).ToHashSet(StringComparer.Ordinal);
        foreach (var (raw, expected, defaultEncoder) in cases)
        {
            var activeRedactor = emissionOwners.TryGetValue(raw, out var ownRedactor) ? ownRedactor : emissionInputs.Contains(raw) ? emissionRedactor : redactor;
            foreach (var options in defaultEncoder ? new JsonSerializerOptions?[] { null, relaxed } : new JsonSerializerOptions?[] { relaxed })
            {
                var input = raw;
                var encoder = options is null ? "default" : "relaxed";
                for (var depth = 0; depth <= 5; depth++)
                {
                    var actual = activeRedactor.Redact(input);
                    try
                    {
                        var decoded = actual;
                        for (var level = 0; level < depth; level++) decoded = JsonSerializer.Deserialize<string>(decoded)!;
                        check(decoded == expected && activeRedactor.Redact(actual) == actual,
                            (emissionInputs.Contains(raw) ? "Joined profile emission " : "Legacy component boundary ") + encoder + " depth " + depth + " " + JsonSerializer.Serialize(raw) + " => " + JsonSerializer.Serialize(decoded));
                        if (emissionInputs.Contains(raw))
                            check(WholeUnicode(actual) && WholeUnicode(decoded!), "Joined profile emission keeps complete Unicode scalars at " + encoder + " depth " + depth + " for " + JsonSerializer.Serialize(raw));
                        if (spanInputs.Contains(raw) && raw.StartsWith('"'))
                            check(JsonSerializer.Deserialize<string>(decoded!) == JsonSerializer.Deserialize<string>(expected),
                                "An encoded macro component remains valid inner JSON at " + encoder + " depth " + depth + " for " + JsonSerializer.Serialize(raw));
                    }
                    catch (Exception error) when (error is JsonException or InvalidOperationException)
                    {
                        check(false, "Invalid legacy component JSON " + encoder + " depth " + depth + " for " + JsonSerializer.Serialize(raw) + ": " + error.Message);
                    }
                    input = JsonSerializer.Serialize(input, options);
                }
            }
            var fixture = Path.Combine(root, "legacy-boundary-" + Guid.NewGuid().ToString("N"));
            var logs = Directory.CreateDirectory(Path.Combine(fixture, "logs")).FullName;
            try
            {
                File.WriteAllText(Path.Combine(logs, "app.log.old"), raw + Environment.NewLine);
                var sender = new FakeSender { Result = new(false, 404) };
                var service = new BugReportService(Webhook, sender, Path.Combine(fixture, "reports"), logs, activeRedactor);
                BugSpec[] specs = [new("cpu", "Processor", raw)];
                var attachment = service.CreateAttachment(specs, BugReportService.TweakSummaryJson([], false, null, [raw]));
                var report = new BugReport("fixture", specs, "fixture#1", raw);
                var saved = service.SaveReport(report, attachment);
                foreach (var (path, isSaved) in new[] { (attachment.FilePath, false), (saved, true) })
                {
                    using var zip = ZipFile.OpenRead(path);
                    try
                    {
                        using var values = JsonDocument.Parse(Read(zip, "specs.json"));
                        using var summary = JsonDocument.Parse(Read(zip, "tweak-state.json"));
                        check(values.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == expected
                            && summary.RootElement.GetProperty("lastErrors")[0].GetString() == expected,
                            "Legacy boundary " + (isSaved ? "saved" : "attachment") + " specs and lastErrors are private valid JSON for " + JsonSerializer.Serialize(raw));
                        if (spanInputs.Contains(raw))
                        {
                            check(activeRedactor.Redact(values.RootElement.GetProperty("specs").GetProperty("cpu").GetString()!) == expected
                                && activeRedactor.Redact(summary.RootElement.GetProperty("lastErrors")[0].GetString()!) == expected,
                                "Span boundary decoded specs and lastErrors stay private and stable after another pass for " + JsonSerializer.Serialize(raw));
                            if (raw.StartsWith('"'))
                                check(JsonSerializer.Deserialize<string>(values.RootElement.GetProperty("specs").GetProperty("cpu").GetString()!) == JsonSerializer.Deserialize<string>(expected)
                                    && JsonSerializer.Deserialize<string>(summary.RootElement.GetProperty("lastErrors")[0].GetString()!) == JsonSerializer.Deserialize<string>(expected),
                                    "An attached encoded macro component has valid inner specs and lastErrors JSON for " + JsonSerializer.Serialize(raw));
                        }
                    }
                    catch (Exception error) when (error is JsonException or InvalidOperationException)
                    {
                        check(false, "Invalid legacy boundary attachment JSON for " + JsonSerializer.Serialize(raw) + ": " + error.Message);
                    }
                    check(Read(zip, "logs/app.log.old") == expected + Environment.NewLine,
                        "Legacy boundary " + (isSaved ? "saved" : "attachment") + " log has exact private output for " + JsonSerializer.Serialize(raw));
                    if (spanInputs.Contains(raw))
                        check(activeRedactor.Redact(Read(zip, "logs/app.log.old")) == expected + Environment.NewLine,
                            "Span boundary attached log stays private and stable after another pass for " + JsonSerializer.Serialize(raw));
                    if (isSaved)
                        check(Read(zip, "report.txt").Contains("What went wrong:" + Environment.NewLine + expected.Trim() + Environment.NewLine, StringComparison.Ordinal)
                            && Read(zip, "report.txt").Contains("Discord or email: fixture#1", StringComparison.Ordinal),
                            "Legacy boundary saved report has private text and unchanged contact for " + JsonSerializer.Serialize(raw));
                }
                var outcome = await service.SendAsync(report, attachment);
                using var payload = JsonDocument.Parse(sender.Calls.Single().Payload);
                var embed = payload.RootElement.GetProperty("embeds")[0];
                var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
                check(outcome.Status == BugSendStatus.Rejected && sender.Calls.Count == 1
                    && embed.GetProperty("description").GetString() == expected.Trim() && fields[0].GetProperty("value").GetString() == expected.Trim()
                    && fields[1].GetProperty("value").GetString() == "fixture#1",
                    "Legacy boundary fake send has private typed fields and unchanged contact for " + JsonSerializer.Serialize(raw));
            }
            finally { Directory.Delete(fixture, true); }
            check(!Directory.Exists(fixture), "Legacy boundary fixture is removed for " + JsonSerializer.Serialize(raw));
        }
    }

    public static async Task AccountFormsAsync(Action<bool, string> check, string root)
    {
        var relaxed = new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        var own = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC");
        var moved = new BugRedactor(@"D:\Profiles\Alice", "Alice", "GAMER-PC", [@"D:\Profiles\Bob", @"\\fs01\profiles$\Carol.V6", @"E:\Client", @"\\nas\Fixture", @"D:\Profiles\Public", @"D:\Profiles\Default"]);
        var single = new BugRedactor(@"C:\Users\A", "A", "X");
        var direct = new BugRedactor(@"E:\Client", "Alice", "GAMER-PC", [@"\\nas\Fixture"]);
        var escapeLetter = new BugRedactor(@"C:\Users\n", "n", "GAMER-PC");
        var cases = new List<(string Issue, BugRedactor Redactor, string Input, string Expected, string[] Private)>
        {
            ("Entra SID", own, @"Signed in as S-1-12-1-111-222-333-444 under HKEY_USERS\s-1-12-1-111-222-333-444\Software", @"Signed in as <sid> under HKEY_USERS\<sid>\Software", ["111-222-333-444"]),
            ("Entra SID", own, "System S-1-5-18, Administrators S-1-5-32-544, Everyone S-1-1-0 and S-1-12-1 stay", "System S-1-5-18, Administrators S-1-5-32-544, Everyone S-1-1-0 and S-1-12-1 stay", []),
            ("Relocated profile", moved, @"D:\Profiles\Bob\AppData\x.log and D:\Profiles\Zqxnew\y", @"D:\Profiles\<user>\AppData\x.log and D:\Profiles\<user>\y", ["Bob", "Zqxnew"]),
            ("Relocated profile", moved, @"D:\Profiles\Alice\AppData\x.log, D:\Profiles\Public\p and D:\ProfilesOld\q", @"%USERPROFILE%\AppData\x.log, D:\Profiles\Public\p and D:\ProfilesOld\q", []),
            ("Relocated profile", moved, @"D:\Profiles\Alice Smith\x and d:/PROFILES/bobby/y", @"D:\Profiles\<user>\x and d:/PROFILES/<user>/y", ["Smith", "bobby"]),
            ("Relocated profile", moved, @"\\fs01\profiles$\Carol.V6\x and \\?\UNC\fs01\profiles$\Zqxroam.V6\y", @"\\fs01\profiles$\<user>\x and \\?\UNC\fs01\profiles$\<user>\y", ["Carol", "Zqxroam"]),
            ("Relocated profile", moved, @"E:\Client\x, \\nas\Fixture\y, E:\Games\z and \\nas\share\w", @"E:\<user>\x, \\nas\<user>\y, E:\Games\z and \\nas\share\w", ["Client", "Fixture"]),
            ("Relocated profile", moved, @"E:\ClientGames\x and \\nas\FixtureBackup\y", @"E:\ClientGames\x and \\nas\FixtureBackup\y", []),
            ("Relocated profile", direct, @"E:\ClientGames\x and \\nas\FixtureBackup\y", @"E:\ClientGames\x and \\nas\FixtureBackup\y", []),
            ("Relocated profile", direct, @"E:\Client\x", @"%USERPROFILE%\x", []),
            ("Old log suffix", own, @"%USERPROFILE%.Zqxsmith\AppData\x and %USERPROFILE% Zqxsmith\AppData\y", @"<user>\AppData\x and <user>\AppData\y", ["Zqxsmith"]),
            ("Old log suffix", own, @"%userprofile%Zqxsmith", "<user>", ["Zqxsmith"]),
            ("Old log suffix", own, @"Moved %USERPROFILE%%USERPROFILE%-Zqxold\x", @"Moved <user>\x", ["Zqxold"]),
            ("Old log suffix", own, @"{""p"":""%USERPROFILE%\u00E9mile\\x"",""q"":""%USERPROFILE% Zqxsmith\\y""}", @"{""p"":""<user>\\x"",""q"":""<user>\\y""}", ["mile", "Zqxsmith"]),
            ("Old log suffix", own, @"Saved to %USERPROFILE% then restarted. %USERPROFILE%. %USERPROFILE%: denied (%USERPROFILE%) %USERPROFILE%\x", @"Saved to %USERPROFILE% then restarted. %USERPROFILE%. %USERPROFILE%: denied (%USERPROFILE%) %USERPROFILE%\x", []),
            ("Separator form", own, @"C:\\Users\\/Bob\\x and C:\Users\/Carol\x and C:/\Users/\Client/x", @"C:\\Users\\/<user>\\x and C:\Users\/<user>\x and C:/\Users/\<user>/x", ["Bob", "Carol", "Client"]),
            ("Separator form", own, @"C:\Users\.\Bob\x and C:\\Users\\.\\Carol\\x and C:\Users\" + @"..\Users\Client\x and C:\Users\" + @"..\Program Files\x", @"C:\Users\.\<user>\x and C:\\Users\\.\\<user>\\x and C:\Users\" + @"..\Users\<user>\x and C:\Users\" + @"..\Program Files\x", ["Bob", "Carol", "Client"]),
            ("Separator form", own, @"Scanning C:\\Users\\\" + @"nFound 3 profiles\nDone and Source : C:\\Users\\\r\nDest : D:\\Backup\\", @"Scanning C:\\Users\\\" + @"nFound 3 profiles\nDone and Source : C:\\Users\\\r\nDest : D:\\Backup\\", []),
            ("JSON spelling", own, @"C:/Users/<user>\u003C\u0075ser\u003EZqxbob/x and C:/Users/<user>\u003C\u0070c-\u006Eame\u003EZqxcarol/y", "C:/Users/<user>/x and C:/Users/<user>/y", ["Zqxbob", "Zqxcarol"]),
            ("JSON spelling", own, @"{""p"":""C:\/Users\/Bob\/x"",""q"":""C:\/Users\/Alice\/y""}", @"{""p"":""C:\/Users\/<user>\/x"",""q"":""%USERPROFILE%\/y""}", ["Bob"]),
            ("JSON spelling", own, @"{""p"":""C:\\\u0055sers\\Zqxother\\x"",""q"":""C:\\Us\u0065rs\\Alice\\y""}", @"{""p"":""C:\\\u0055sers\\<user>\\x"",""q"":""%USERPROFILE%\\y""}", ["Zqxother"]),
            ("JSON spelling", moved, @"{""p"":""D:\\Pro\u0066iles\\Zqxmoved\\x"",""q"":""\\\\fs01\\pro\u0066iles$\\Zqxroam\\y""}", @"{""p"":""D:\\Pro\u0066iles\\<user>\\x"",""q"":""\\\\fs01\\pro\u0066iles$\\<user>\\y""}", ["Zqxmoved", "Zqxroam"]),
            ("JSON spelling", own, @"C:/\u0055sers/Zqxother/x and C:/\u0055sersBackup/Games/y", @"C:/\u0055sers/<user>/x and C:/\u0055sersBackup/Games/y", ["Zqxother"]),
            ("JSON spelling", own, @"{""p"":""\u0043:\u005cUsers\u005cZqxother\u005cx"",""q"":""\u0043:\u005cUsers\u005cAlice\u005cy""}", @"{""p"":""\u0043:\u005cUsers\u005c<user>\u005cx"",""q"":""%USERPROFILE%\u005cy""}", ["Zqxother"]),
            ("JSON spelling", own, @"C:/\u0055sers/\u003Cuser\u003EZqxother/x and C:/\u0055sers/Public/y", @"C:/\u0055sers/<user>/x and C:/\u0055sers/Public/y", ["Zqxother"]),
            ("Entra SID", own, @"\u0053-1-12-1-111-222-333-444 and \u0053-1-5-21-111-222-333-1001; system \u0053-1-5-18", @"<sid> and <sid>; system \u0053-1-5-18", ["111-222-333"]),
            ("Device path", own, @"\Device\HarddiskVolume3\Users\Bob\x and \\?\GLOBALROOT\Device\HarddiskVolume3\Users\Carol\y", @"\Device\HarddiskVolume3\Users\<user>\x and \\?\GLOBALROOT\Device\HarddiskVolume3\Users\<user>\y", ["Bob", "Carol"]),
            ("Device path", own, @"\\.\HarddiskVolume3\Users\Bob\x, \\?\Volume{0a1b2c3d-0000-0000-0000-000000000000}\Users\Carol\y and \\GAMER-PC\C$\Users\Client\z", @"\\.\HarddiskVolume3\Users\<user>\x, \\?\Volume{0a1b2c3d-0000-0000-0000-000000000000}\Users\<user>\y and \\<pc-name>\C$\Users\<user>\z", ["Bob", "Carol", "Client"]),
            ("Device path", own, @"\??\C:\Users\Bob\x, \\?\C:\Users\Carol\y and \\.\C:\Users\Alice\z", @"\??\C:\Users\<user>\x, \\?\C:\Users\<user>\y and \\.\%USERPROFILE%\z", ["Bob", "Carol"]),
            ("Device path", own, @"%SystemDrive%\Users\Bob\x and C:\Documents and Settings\Carol\y", @"%SystemDrive%\Users\<user>\x and C:\Documents and Settings\<user>\y", ["Bob", "Carol"]),
            ("Device path", own, @"https://example.com/users/fixture, HKEY_USERS\.DEFAULT and Users\Groups stay", @"https://example.com/users/fixture, HKEY_USERS\.DEFAULT and Users\Groups stay", []),
            ("One-letter name", single, @"A setting failed on X. X\A signed in, AzureAD\A synced, \\X\share\x and C:\Users\A\y. Drive A: ok", @"A setting failed on X. <pc-name>\<user> signed in, AzureAD\<user> synced, \\<pc-name>\share\x and %USERPROFILE%\y. Drive A: ok", []),
        };
        check(escapeLetter.Redact(@"{""m"":""on GAMER-PC\n""} and GAMER-PC\\n") == @"{""m"":""on <pc-name>\n""} and <pc-name>\\<user>",
            "A one-letter account named like a JSON escape keeps JSON newlines valid and is redacted after an escaped backslash");
        foreach (var suffix in new[] { "Data", ".Backup", "-cache", " Games" })
        {
            var input = @"E:\Client" + suffix + @"\x and \\nas\Fixture" + suffix + @"\y";
            cases.Add(("Relocated profile", moved, input, input, []));
            cases.Add(("Relocated profile", direct, input, input, []));
        }
        check(moved.Redact(@"\nas\Fixture\x") == @"\nas\Fixture\x", "An unquoted single-rooted local path is not a UNC profile");
        cases.Add(("Ambiguous UNC JSON", moved, @"""\\nas\\Fixture\\x""", @"""\\nas\\<user>\\x""", ["Fixture"]));
        foreach (var input in new[] { @"C:\nas\Fixture\x", "C:/nas/Fixture/x", @"nas\Fixture\x",
            "https://host/nas/Fixture/x", "https://nas/Fixture/x", "https://fs01/profiles$/Bob/x", "https://host/fs01/profiles$/Bob/x",
            "https://host//nas/Fixture/x", @"https:\/\/fs01\/profiles$\/Bob\/x" })
            cases.Add(("Relocated profile", moved, input, input, []));
        cases.Add(("Relocated profile", moved, @"\\.\UNC\fs01\profiles$\Zqxroam\x and //fs01/profiles$/Zqxroam/y and \/\/fs01\/profiles$\/Zqxroam\/z",
            @"\\.\UNC\fs01\profiles$\<user>\x and //fs01/profiles$/<user>/y and \/\/fs01\/profiles$\/<user>\/z", ["Zqxroam"]));
        cases.Add(("Windows path in URL", own, "https://host/?file=C:/Users/Bob/x", "https://host/?file=C:/Users/<user>/x", ["Bob"]));
        cases.Add(("UNC after URL", moved, "https://host/x\n" + @"\\fs01\profiles$\Zqxroam\x", "https://host/x\n" + @"\\fs01\profiles$\<user>\x", ["Zqxroam"]));
        foreach (var letter in new[] { "n", "r", "t", "b", "f" })
        {
            cases.Add(("Separator form", own, @"C:\\Users\\\" + letter + "Zqxname" + @"\\x", @"C:\\Users\\<user>\\x", ["Zqxname"]));
            cases.Add(("Separator form", own, @"C:\Users\\\" + letter + "Zqxname" + @"\x", @"C:\Users\\<user>\x", ["Zqxname"]));
        }
        foreach (var (issue, redactor, raw, expected, secrets) in cases)
        {
            var name = issue + " " + JsonSerializer.Serialize(raw);
            foreach (var options in new JsonSerializerOptions?[] { null, relaxed })
            {
                var input = raw;
                for (var depth = 0; depth <= 3; depth++)
                {
                    var actual = redactor.Redact(input);
                    try
                    {
                        var decoded = actual;
                        for (var level = 0; level < depth; level++) decoded = JsonSerializer.Deserialize<string>(decoded)!;
                        check(decoded == expected && redactor.Redact(actual) == actual && !secrets.Any(secret => decoded.Contains(secret, StringComparison.OrdinalIgnoreCase)),
                            "Account form " + (options is null ? "default" : "relaxed") + " depth " + depth + " " + name + " => " + JsonSerializer.Serialize(decoded));
                    }
                    catch (JsonException error)
                    {
                        check(false, "Account form JSON is invalid at depth " + depth + " for " + name + ": " + error.Message);
                    }
                    input = JsonSerializer.Serialize(input, options);
                }
            }
            var fixture = Path.Combine(root, "account-form-" + Guid.NewGuid().ToString("N"));
            var logs = Directory.CreateDirectory(Path.Combine(fixture, "logs")).FullName;
            try
            {
                File.WriteAllText(Path.Combine(logs, "app.log.old"), raw + Environment.NewLine);
                var sender = new FakeSender { Result = new(false, 404) };
                var service = new BugReportService(Webhook, sender, Path.Combine(fixture, "reports"), logs, redactor);
                BugSpec[] specs = [new("cpu", "Processor", raw)];
                var attachment = service.CreateAttachment(specs, BugReportService.TweakSummaryJson([], false, null, [raw]));
                var report = new BugReport("fixture", specs, "alice#1 alice@example.com", raw);
                var outcome = await service.SendAsync(report, attachment);
                using (var payload = JsonDocument.Parse(sender.Calls.Single().Payload))
                {
                    var embed = payload.RootElement.GetProperty("embeds")[0];
                    var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
                    check(outcome.Status == BugSendStatus.Rejected && embed.GetProperty("description").GetString() == expected.Trim()
                        && fields[0].GetProperty("value").GetString() == expected.Trim() && fields[1].GetProperty("value").GetString() == "alice#1 alice@example.com",
                        "Sending redacts the typed description and specs and keeps the contact for " + name);
                }
                var saved = service.SaveReport(report, attachment);
                foreach (var (path, kind) in new[] { (sender.Calls[0].ZipPath, "sent"), (saved, "saved") })
                {
                    using var zip = ZipFile.OpenRead(path);
                    try
                    {
                        using var values = JsonDocument.Parse(Read(zip, "specs.json"));
                        using var summary = JsonDocument.Parse(Read(zip, "tweak-state.json"));
                        var log = Read(zip, "logs/app.log.old");
                        check(values.RootElement.GetProperty("specs").GetProperty("cpu").GetString() == expected
                            && summary.RootElement.GetProperty("lastErrors")[0].GetString() == expected && log == expected + Environment.NewLine
                            && !secrets.Any(secret => log.Contains(secret, StringComparison.OrdinalIgnoreCase)),
                            "The " + kind + " zip redacts specs, last errors and old log lines for " + name);
                    }
                    catch (JsonException error)
                    {
                        check(false, "The " + kind + " zip JSON is invalid for " + name + ": " + error.Message);
                    }
                    if (kind == "saved")
                        check(Read(zip, "report.txt").Contains("What went wrong:" + Environment.NewLine + expected.Trim() + Environment.NewLine, StringComparison.Ordinal)
                            && Read(zip, "report.txt").Contains("Discord or email: alice#1 alice@example.com", StringComparison.Ordinal),
                            "The saved report text redacts the description and keeps the contact for " + name);
                }
            }
            finally { Directory.Delete(fixture, true); }
            check(!Directory.Exists(fixture), "The account form fixture is removed for " + name);
        }
        await AccountFormsViewAsync(check, root, moved);
        await AccountFormsLargeAsync(check, moved);
        if (OperatingSystem.IsWindows()) RegisteredProfilesChecks(check);
    }

    private static async Task AccountFormsViewAsync(Action<bool, string> check, string root, BugRedactor redactor)
    {
        var fixture = Path.Combine(root, "account-form-view");
        var logs = Directory.CreateDirectory(Path.Combine(fixture, "logs")).FullName;
        var savedService = RooIndustries.OptimizationSuite.App.BugReports;
        var savedError = RooIndustries.OptimizationSuite.App.Live.LastError;
        var sender = new FakeSender { Result = new(false, 404) };
        try
        {
            File.WriteAllText(Path.Combine(logs, "app.log.old"), @"2026-09-26 [backend] %USERPROFILE%.Zqxsmith\AppData failed for S-1-12-1-111-222-333-444" + Environment.NewLine);
            RooIndustries.OptimizationSuite.App.BugReports = new(Webhook, sender, Path.Combine(fixture, "reports"), logs, redactor);
            RooIndustries.OptimizationSuite.App.Live.LastError = @"Access denied: \\fs01\profiles$\Carol.V6\NTUSER.DAT";
            var view = new RooIndustries.OptimizationSuite.ViewModels.BugReportViewModel
            {
                Description = @"Crash reading D:\Profiles\Bob\AppData and \Device\HarddiskVolume3\Users\Zqxdevice\x",
                Contact = "alice#1",
            };
            await view.LoadAsync();
            view.Specs[0].Value = @"Copied from E:\Client\specs.txt";
            await view.AttachAsync();
            await view.SendAsync();
            await view.SaveAsync();
            var secrets = new[] { "Zqxsmith", "111-222-333-444", "Carol", "Bob", "Zqxdevice", "Client" };
            using (var payload = JsonDocument.Parse(sender.Calls.Single().Payload))
            {
                var embed = payload.RootElement.GetProperty("embeds")[0];
                var fields = embed.GetProperty("fields").EnumerateArray().ToArray();
                check(embed.GetProperty("description").GetString() == @"Crash reading D:\Profiles\<user>\AppData and \Device\HarddiskVolume3\Users\<user>\x"
                    && fields[0].GetProperty("value").GetString() == @"Copied from E:\<user>\specs.txt" && fields[^1].GetProperty("value").GetString() == "alice#1",
                    "The bug report screen sends the typed description and edited specs redacted, with the contact as typed");
            }
            foreach (var (path, kind) in new[] { (sender.Calls[0].ZipPath, "sent"), (view.SavedPath!, "saved") })
            {
                using var zip = ZipFile.OpenRead(path);
                var all = string.Concat(zip.Entries.Select(entry => Read(zip, entry.FullName)));
                check(!secrets.Any(secret => all.Contains(secret, StringComparison.OrdinalIgnoreCase)) && all.Contains(@"\\fs01\\profiles$\\<user>\\NTUSER.DAT", StringComparison.Ordinal)
                    && all.Contains(@"<user>\AppData failed for <sid>", StringComparison.Ordinal),
                    "The bug report screen's " + kind + " zip hides relocated, network, device and old-log account names");
            }
        }
        finally
        {
            RooIndustries.OptimizationSuite.App.BugReports = savedService;
            RooIndustries.OptimizationSuite.App.Live.LastError = savedError;
            Directory.Delete(fixture, true);
        }
        check(!Directory.Exists(fixture), "The bug report screen fixture is removed");
    }

    private static async Task AccountFormsLargeAsync(Action<bool, string> check, BugRedactor redactor)
    {
        var mixed = new StringBuilder();
        while (mixed.Length < 7 * 1024 * 1024) mixed.Append(@"\Device\HarddiskVolume3\Users\Zqxbob\x %USERPROFILE%.Zqxsmith\y D:\Profiles\Zqxmoved\z S-1-12-1-111-222-333-444 %USERPROFILE% a ");
        var spaced = new StringBuilder();
        while (spaced.Length < 7 * 1024 * 1024) spaced.Append("%USERPROFILE% a");
        var encoded = new StringBuilder();
        while (encoded.Length < 7 * 1024 * 1024) encoded.Append(@"C:/\u0055sers/Zqxother/x D:/Pro\u0066iles/Zqxmoved/y \u0053-1-12-1-111-222-333-444 ");
        var inputs = new (string Name, string Input, Func<string, bool> Expected)[]
        {
            ("repeated new account forms", mixed.ToString(), output => !output.Contains("Zqx", StringComparison.Ordinal) && !output.Contains("111-222", StringComparison.Ordinal)),
            ("macros followed by prose", spaced.ToString(), output => output == spaced.ToString()),
            ("encoded profile roots and account SIDs", encoded.ToString(), output => !output.Contains("Zqx", StringComparison.Ordinal) && !output.Contains("111-222", StringComparison.Ordinal)),
            ("a mixed separator run", @"C:\Users" + string.Concat(Enumerable.Repeat(@"\/", 3 * 1024 * 1024)) + "Fixture", output => output.EndsWith(@"\/<user>", StringComparison.Ordinal) && !output.Contains("Fixture", StringComparison.Ordinal)),
            ("a backslash run before a Users word", "x" + new string('\\', 7 * 1024 * 1024) + "Usersy", output => output.EndsWith("Usersy", StringComparison.Ordinal)),
            ("a three-backslash control before a long run", @"C:\\Users\\\r" + "Zqxname" + new string('\\', 7 * 1024 * 1024) + "x", output => !output.Contains("Zqxname", StringComparison.Ordinal)),
        };
        foreach (var (name, input, expected) in inputs)
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var redaction = Task.Run(() => redactor.Redact(input));
            var completed = await Task.WhenAny(redaction, Task.Delay(TimeSpan.FromSeconds(5)));
            check(completed == redaction && redaction.IsCompletedSuccessfully && expected(redaction.Result),
                "A 7 MB log of " + name + " is redacted within five seconds: completed=" + (completed == redaction) + " elapsedMs=" + clock.Elapsed.TotalMilliseconds.ToString("F2"));
        }
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static void RegisteredProfilesChecks(Action<bool, string> check)
    {
        var name = @"Software\RooIndustriesRedactionFixture-" + Guid.NewGuid().ToString("N");
        var drive = Environment.GetEnvironmentVariable("SystemDrive") ?? "C:";
        const string lockedName = "S-1-5-21-111111111-222222222-333333333-1005";
        var deny = new System.Security.AccessControl.RegistryAccessRule(System.Security.Principal.WindowsIdentity.GetCurrent().User!,
            System.Security.AccessControl.RegistryRights.QueryValues, System.Security.AccessControl.AccessControlType.Deny);
        try
        {
            using (var list = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(name + @"\ProfileList"))
            {
                list.SetValue("Default", @"D:\Profiles\Default", Microsoft.Win32.RegistryValueKind.ExpandString);
                list.SetValue("Public", @"%SystemDrive%\Users\Public", Microsoft.Win32.RegistryValueKind.ExpandString);
                using (var account = list.CreateSubKey("S-1-5-21-111111111-222222222-333333333-1001")) account.SetValue("ProfileImagePath", @"D:\Profiles\Bob", Microsoft.Win32.RegistryValueKind.ExpandString);
                using (var account = list.CreateSubKey("S-1-5-21-111111111-222222222-333333333-1002.bak")) account.SetValue("ProfileImagePath", @"E:\Client");
                using (var account = list.CreateSubKey("S-1-12-1-111-222-333-444"))
                {
                    account.SetValue("ProfileImagePath", @"%SystemDrive%\Users\Fixture", Microsoft.Win32.RegistryValueKind.ExpandString);
                    account.SetValue("CentralProfile", @"\\fs01\profiles$\Carol.V6");
                }
                using (var account = list.CreateSubKey("S-1-5-18")) account.SetValue("ProfileImagePath", @"%systemroot%\system32\config\systemprofile", Microsoft.Win32.RegistryValueKind.ExpandString);
                using (var account = list.CreateSubKey("S-1-5-21-111111111-222222222-333333333-1003")) account.SetValue("ProfileImagePath", 7, Microsoft.Win32.RegistryValueKind.DWord);
                list.CreateSubKey("S-1-5-21-111111111-222222222-333333333-1004").Dispose();
                using var locked = list.CreateSubKey(lockedName);
                locked.SetValue("ProfileImagePath", @"D:\Locked\Zqxlocked");
                var security = locked.GetAccessControl();
                security.AddAccessRule(deny);
                locked.SetAccessControl(security);
            }
            using (var probe = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(name + @"\ProfileList"))
            {
                var refused = false;
                try { probe!.OpenSubKey(lockedName)?.Dispose(); }
                catch (System.Security.SecurityException) { refused = true; }
                check(refused, "The disposable profile list has one entry this account cannot read");
            }
            using var read = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(name + @"\ProfileList");
            var paths = BugRedactor.RegisteredProfiles(read);
            var expected = new[] { @"D:\Profiles\Default", drive + @"\Users\Public", @"D:\Profiles\Bob", @"E:\Client", drive + @"\Users\Fixture", @"\\fs01\profiles$\Carol.V6" };
            check(paths.Count == expected.Length && expected.All(path => paths.Contains(path, StringComparer.Ordinal)),
                "The profile list reader returns expanded account, backup, roaming, Default and Public paths and skips system, mistyped, empty and unreadable entries: " + paths.Count);
            var redactor = new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC", paths);
            var output = redactor.Redact(@"D:\Profiles\Bob\x D:\Profiles\Zqxnew\y D:\Profiles\Default\d E:\Client\z E:\Games\g \\fs01\profiles$\Carol.V6\c C:\Windows\system32\config\SAM %SystemRoot%\system32\config\systemprofile\s");
            check(output == @"D:\Profiles\<user>\x D:\Profiles\<user>\y D:\Profiles\Default\d E:\<user>\z E:\Games\g \\fs01\profiles$\<user>\c C:\Windows\system32\config\SAM %SystemRoot%\system32\config\systemprofile\s",
                "Profiles read from a disposable profile list are redacted while system and shared folders stay readable");
            check(BugRedactor.RegisteredProfiles(null).Count == 0 && new BugRedactor(@"C:\Users\Alice", "Alice", "GAMER-PC", BugRedactor.RegisteredProfiles(null)).Redact(@"C:\Users\Bob\x") == @"C:\Users\<user>\x",
                "A missing profile list falls back to the Users folder rules");
        }
        finally
        {
            using (var locked = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(name + @"\ProfileList\" + lockedName, Microsoft.Win32.RegistryKeyPermissionCheck.ReadWriteSubTree,
                System.Security.AccessControl.RegistryRights.ReadPermissions | System.Security.AccessControl.RegistryRights.ChangePermissions))
            {
                if (locked is not null)
                {
                    var security = locked.GetAccessControl();
                    security.RemoveAccessRuleSpecific(deny);
                    locked.SetAccessControl(security);
                }
            }
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(name, false);
        }
        check(Microsoft.Win32.Registry.CurrentUser.OpenSubKey(name) is null, "The disposable profile list key is removed");
        var real = BugRedactor.RegisteredProfiles();
        var current = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\');
        check(real.Any(path => string.Equals(path.TrimEnd('\\'), current, StringComparison.OrdinalIgnoreCase)), "The real profile list includes the signed-in account's profile");
        var live = BugRedactor.Current();
        var index = 0;
        foreach (var path in real)
        {
            index++;
            var folder = Path.GetFileName(path.TrimEnd('\\'));
            if (folder is "Public" or "Default" || folder.Length == 0) continue;
            var plain = live.Redact(path + @"\AppData\x.log");
            var json = JsonSerializer.Deserialize<string>(live.Redact(JsonSerializer.Serialize(path + @"\AppData\x.log")))!;
            var isOwn = string.Equals(path.TrimEnd('\\'), current, StringComparison.OrdinalIgnoreCase);
            check(isOwn ? plain == @"%USERPROFILE%\AppData\x.log" && json == plain
                : !plain.Split('\\', '/').Contains(folder, StringComparer.OrdinalIgnoreCase) && !json.Split('\\', '/').Contains(folder, StringComparer.OrdinalIgnoreCase),
                "Registered profile " + index + " of " + real.Count + " on this PC is redacted in plain and JSON paths");
        }
    }

    private static string Read(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name) ?? throw new InvalidDataException(name + " is missing from the report zip.");
        using var reader = new StreamReader(entry.Open());
        return reader.ReadToEnd();
    }
}
