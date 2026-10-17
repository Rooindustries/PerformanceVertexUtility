using System.Text;
using System.Text.RegularExpressions;
using RooIndustries.Optimizer;

static class FirmwareChecks
{
    internal static readonly string ExportText = """
// Fixture export; no physical firmware is used.
HIICrc32 = A1B2C3D4

// FORM SET
// GUID = 11111111-1111-1111-1111-111111111111
// Title = Setup
// FORM
// GUID = 22222222-2222-2222-2222-222222222222
// Variable = Setup
Setup Question = Performance mode
Help String = Select the platform mode.
Token =10 // Do NOT change this line
Offset =20
Width =01
BIOS Default =[00]Balanced
Options =*[00]Balanced // Move selection to an option
         [01]Performance
         [02]Quiet

Setup Question = Startup delay
Help String = Delay in seconds.
Token =11 // Do NOT change this line
Offset =21
Width =01
Value =<5>

Setup Question = Cache limit
Help String = Numeric hexadecimal field.
Token =12 // Do NOT change this line
Offset =22
Width =02
Value =0A

// Setup Question = Suppressed setting
// Token =13
// Offset =23
// Width =01
// Options =*[00]Off
// [01]On
""".ReplaceLineEndings("\n");
    internal static string VcoreExport(string crc, string vcore, string value = "0", string mode = "00", string offset = "1044", string twin = "1.079V", string twinValue = "0")
        => "// Script File Name : fixture.txt\n// Created on fixture\n\nHIICrc32= " + crc + "\n\n// FORM SET\n// GUID = 11111111-1111-1111-1111-111111111111\n// Title = Setup\n// FORM\n// GUID = 22222222-2222-2222-2222-222222222222\n// Title = Voltage\n\n"
            + "// GUID = ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\n// Variable = Setup\nSetup Question = Vcore Voltage Mode\nHelp String = Vcore Voltage Mode\nToken =2A9A // Do NOT change this line\nOffset =104C\nWidth =01\nBIOS Default =[00]Auto\nOptions =" + (mode == "00" ? "*" : "") + "[00]Auto // Move \"*\" to the desired Option\n         " + (mode == "01" ? "*" : "") + "[01]Adaptive Vcore\n\n"
            + "// GUID = ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\n// Variable = Setup\nSetup Question = Internal CPU Vcore " + vcore + "\nHelp String = Adjust the Internal CPU Vcore voltage.\nToken =2A9B // Do NOT change this line\nOffset =" + offset + "\nWidth =02\nBIOS Default =<0>\nValue =<" + value + ">\n\n"
            + "// GUID = ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\n// Variable = Setup\nSetup Question = Internal CPU Vcore " + twin + "\nHelp String = Adjust the Internal CPU Vcore voltage.\nToken =2A9D // Do NOT change this line\nOffset =1048\nWidth =02\nBIOS Default =<0>\nValue =<" + twinValue + ">\n";
    public static void Run(Action<bool, string> check)
    {
        void Reject(Action action, string message)
        {
            var rejected = false;
            try { action(); } catch (Exception e) when (e is InvalidDataException or IOException) { rejected = true; }
            check(rejected, message);
        }
        var script = new FirmwareScript(Encoding.UTF8.GetBytes(ExportText));
        const string diagnostic = "AMISCE Utility. Ver 5.05.01.0002\r\nWARNING: Duplicate questions found. Only one question will be enabled in the script.\r\nScript file exported successfully.\r\n";
        check(new FirmwareCommandResult(0, "", diagnostic).Succeeded, "A successful SCEWIN export may report its banner and warning on stderr");
        check(!new FirmwareCommandResult(23, "", diagnostic).Succeeded, "Success text cannot override a nonzero SCEWIN exit status");
        foreach (var error in new[] { "ERROR: variable update failed", "13 - Error: invalid script", "Failed to load driver", "Failure: checksum differs" })
            check(!new FirmwareCommandResult(0, error, diagnostic).Succeeded && !new FirmwareCommandResult(0, "Script file exported successfully.", error).Succeeded,
                "Reported errors on either stream independently reject a zero exit: " + error);
        foreach (var incomplete in new[] { "{\"output\":\"\",\"error\":\"\"}", "{\"exitCode\":0,\"error\":\"\"}", "{\"exitCode\":0,\"output\":\"\"}" })
        {
            var rejected = false;
            try { _ = System.Text.Json.JsonSerializer.Deserialize<FirmwareCommandResult>(incomplete, OperationFiles.Json); }
            catch (System.Text.Json.JsonException) { rejected = true; }
            check(rejected, "A saved firmware result cannot infer success from a missing exit status or output stream");
        }
        check(!new FirmwareCommandResult(0, null!, "").Succeeded && !new FirmwareCommandResult(0, "", null!).Succeeded,
            "Null command output remains unknown rather than a successful firmware operation");
        var doubled = ExportText.Replace("HIICrc32 = A1B2C3D4\n", "HIICrc32= A1B2C3D4\r\r\n", StringComparison.Ordinal);
        var actualFormat = new FirmwareScript(Encoding.Latin1.GetBytes(doubled));
        check(actualFormat.Crc == "A1B2C3D4" && actualFormat.Text == doubled && actualFormat.SameValues(script),
            "The actual SCEWIN doubled-carriage-return checksum line parses without rewriting the original export");
        foreach (var digits in new[] { "A", "A1B", "A1B2C3", "A1B2C3D", "A1B2C3D4" })
        {
            var parsed = new FirmwareScript(Encoding.Latin1.GetBytes(ExportText.Replace("A1B2C3D4", digits, StringComparison.Ordinal)));
            check(parsed.Crc == digits.PadLeft(8, '0'), "A " + digits.Length + "-digit SCEWIN checksum is normalized without rewriting the export");
        }
        Reject(() => new FirmwareScript(Encoding.Latin1.GetBytes(ExportText.Replace("A1B2C3D4", "", StringComparison.Ordinal))), "An empty checksum is rejected");
        Reject(() => new FirmwareScript(Encoding.Latin1.GetBytes(ExportText.Replace("A1B2C3D4", "G123", StringComparison.Ordinal))), "A non-hex checksum is rejected");
        Reject(() => new FirmwareScript(Encoding.Latin1.GetBytes(ExportText.Replace("A1B2C3D4", "A1B2C3D45", StringComparison.Ordinal))), "A checksum longer than eight digits is rejected");
        Reject(() => new FirmwareScript(Encoding.Latin1.GetBytes(doubled + "\nHIICrc32= 12345678\r\r\n")),
            "Accepting SCEWIN line endings does not permit a second checksum");
        Reject(() => new FirmwareScript(Encoding.Latin1.GetBytes(doubled.Replace("A1B2C3D4", "A1B2C3D4extra", StringComparison.Ordinal))),
            "Accepting SCEWIN line endings does not permit trailing checksum data");
        check(script.Questions.Count == 3 && script.Questions[0].Options.Length == 3, "BIOS parser reads choices and decimal/hex fields while leaving commented questions untouched");
        var mode = script.Questions.Single(q => q.Name == "Performance mode");
        var delay = script.Questions.Single(q => q.Name == "Startup delay");
        var cache = script.Questions.Single(q => q.Name == "Cache limit");
        check(script.Validate(delay, "005") == "5" && script.Validate(cache, "a") == "A", "Equivalent numeric values normalize without inventing a change");
        Reject(() => script.Changes(new Dictionary<string, string> { [mode.Id] = "03" }), "An unlisted BIOS option cannot be imported");
        Reject(() => script.Changes(new Dictionary<string, string> { [delay.Id] = "256" }), "Numeric values outside the exported byte width are rejected");
        Reject(() => script.Changes(new Dictionary<string, string> { [cache.Id] = "0A\nToken=FF" }), "Numeric input cannot inject a script field");
        Reject(() => script.Changes(new Dictionary<string, string> { [delay.Id] = "5" }), "Unchanged selections cannot masquerade as an apply");
        Reject(() => new FirmwareScript(Encoding.UTF8.GetBytes(ExportText.Replace("HIICrc32 = A1B2C3D4", ""))), "Missing firmware checksum prevents import preparation");
        Reject(() => new FirmwareScript(Encoding.UTF8.GetBytes(ExportText + "\n" + ExportText[(ExportText.IndexOf("Setup Question = Performance", StringComparison.Ordinal))..])), "Duplicate question identity is rejected");
        Reject(() => script.Validate(delay, null), "A missing selection remains unknown and cannot be imported");
        var edits = new Dictionary<string, string> { [mode.Id] = "01", [delay.Id] = "7" };
        var bytes = script.Changes(edits); var text = Encoding.UTF8.GetString(bytes);
        check(text.Contains("HIICrc32 = A1B2C3D4") && text.Contains("*[01]Performance") && text.Contains("Value =<7>")
            && !text.Contains("Cache limit") && !text.Contains("Suppressed setting") && !text.Contains("*[00]"), "Import script contains only reviewed fields and retains the firmware checksum");
        var unicode = new FirmwareScript(Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes(ExportText.Replace("\n", "\r\n"))).ToArray());
        check(unicode.Changes(edits).AsSpan().StartsWith(Encoding.Unicode.GetPreamble()), "UTF-16 exports retain their encoding during import preparation");
        var contextText = "// FORM SET\n// GUID = aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n// Title = Main\n// FORM\n// FORM ID = 01\n// Title = General\n";
        var withContext = ExportText.Replace("Setup Question = Performance mode", contextText + "Setup Question = Performance mode");
        var contextual = new FirmwareScript(Encoding.UTF8.GetBytes(withContext));
        var selectedContext = contextual.Questions.First();
        check(new FirmwareScript(contextual.Changes(new Dictionary<string, string> { [selectedContext.Id] = "01" })).Questions[0].Id == selectedContext.Id,
            "Question identity is stable when a reviewed question is exported into a minimal script");

        static FirmwareScript Vcore(string text) => new(Encoding.Latin1.GetBytes(text));
        var loaded = Vcore(VcoreExport("0983808B", "1.079V"));
        var drifted = VcoreExport("91DA1C04", "1.078V", twin: "1.078V");
        check(loaded.SameValues(Vcore(drifted)), "A restart that only changes the live voltage in two same-named questions and the HII checksum keeps every value matched");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "1.078V", value: "5", twin: "1.078V"))), "A changed value on the question whose name drifted is detected");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "1.078V", mode: "01", twin: "1.078V"))), "A changed value on another question is detected while a name drifted");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "1.078V", twin: "1.078V", twinValue: "5"))), "A changed value on the second same-named question is detected");
        check(!Vcore(VcoreExport("0983808B", "1.079V", value: "5")).SameValues(Vcore(VcoreExport("91DA1C04", "1.078V", twin: "1.078V", twinValue: "5"))), "Swapped values between same-named questions are detected");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "1.079V"))), "A checksum change without any question name change is a different firmware layout");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "Override"))), "A question renamed beyond its numbers is a different firmware layout");
        check(!loaded.SameValues(Vcore(VcoreExport("91DA1C04", "1.078V", offset: "1050"))), "A drifted question that moved offset is a different firmware layout");
        check(!loaded.SameValues(Vcore(VcoreExport("0983808B", "1.079V", offset: "1050"))), "A question that moved offset under the same checksum is not matched");
        check(!loaded.SameValues(Vcore(drifted.Replace("[01]Adaptive Vcore", "[01]Adaptive", StringComparison.Ordinal))), "A changed option label is a different firmware layout even when a name drifted");
        check(!loaded.SameValues(Vcore(drifted.Replace("Token =2A9D", "Token =2A9E", StringComparison.Ordinal))), "A changed token is a different firmware layout even when a name drifted");
        check(!loaded.SameValues(Vcore(drifted + "\nSetup Question = Added 1.0V\nHelp String = Added\nToken =2AA0 // Do NOT change this line\nOffset =1050\nWidth =01\nValue =<0>\n")), "An added question is a different firmware layout even when a name drifted");
        check(!loaded.SameValues(Vcore(drifted.Replace("Help String = Vcore Voltage Mode", "Help String = Voltage mode", StringComparison.Ordinal))), "Changed help text is a different firmware layout even when a name drifted");
        check(!loaded.SameValues(Vcore(drifted.Replace("// Variable = Setup\nSetup Question = Internal CPU Vcore 1.078V\nHelp", "// Variable = OtherSetup\nSetup Question = Internal CPU Vcore 1.078V\nHelp", StringComparison.Ordinal))), "A changed storage variable is a different firmware layout even when a name drifted");

        var root = Path.Combine(Path.GetTempPath(), "roo-industries-firmware-" + Guid.NewGuid().ToString("N"));
        try
        {
            var provider = new FixtureProvider(); var flow = new FirmwareWorkflow(provider, root);
            (string Directory, string Hash) Prepared()
            {
                provider.Mode = "00"; provider.Delay = "5"; provider.Cache = "0A"; provider.FailImport = false; provider.ReportError = false; provider.Partial = false; provider.ThrowAfterWrite = false; provider.FailExport = false;
                var directory = flow.Load(); return (directory, flow.Review(directory, edits));
            }
            var ready = Prepared();
            check(File.ReadAllText(Path.Combine(ready.Directory, "original.txt")) == ExportText, "Loading firmware saves the exact original bytes before preparing changes");
            Reject(() => flow.Apply(ready.Directory, ""), "Import requires the exact review identity");
            var calls = provider.ImportCalls;
            provider.Delay = "9";
            Reject(() => flow.Apply(ready.Directory, ready.Hash), "A concurrent BIOS setting change invalidates the old review");
            check(provider.ImportCalls == calls && provider.Delay == "9", "Stale-state rejection leaves the intervening BIOS change untouched");
            provider.Delay = "5";
            var before = provider.Identity;
            foreach (var changed in new[] { before with { MachineId = "another-pc" }, before with { Board = "another-board" }, before with { Bios = "F9" }, before with { Boot = "boot-2" } })
            {
                provider.Identity = changed;
                Reject(() => flow.Apply(ready.Directory, ready.Hash), "PC, board, BIOS and boot bindings each independently prevent stale import");
            }
            provider.Identity = before;
            provider.Fingerprint = "changed-package";
            Reject(() => flow.Apply(ready.Directory, ready.Hash), "Changing the helper package invalidates the review");
            provider.Fingerprint = "fixture-package";
            var originalPath = Path.Combine(ready.Directory, "original.txt");
            File.AppendAllText(originalPath, "\nmodified");
            Reject(() => flow.Apply(ready.Directory, ready.Hash), "An altered original export cannot authorize an import");
            File.WriteAllText(originalPath, ExportText);
            var changesPath = Path.Combine(ready.Directory, "changes.txt"); var intended = File.ReadAllBytes(changesPath);
            File.AppendAllText(changesPath, "\nmodified");
            Reject(() => flow.Apply(ready.Directory, ready.Hash), "An altered import script cannot bypass the review");
            File.WriteAllBytes(changesPath, intended);
            check(flow.Apply(ready.Directory, ready.Hash).Status == "restartRequired" && provider.Mode == "01" && provider.Delay == "7" && provider.Cache == "0A", "Reviewed choice and numeric changes reach the provider while an unselected setting stays unchanged");
            calls = provider.ImportCalls;
            check(flow.Apply(ready.Directory, ready.Hash).Status == "restartRequired" && provider.ImportCalls == calls, "Duplicate apply returns the recorded result without importing twice");
            check(flow.Verify(ready.Directory).Status == "restartRequired", "Matching values before a restart are not described as verified after restart");
            provider.Identity = before with { Boot = "boot-2" };
            check(flow.Verify(ready.Directory).Status == "applied", "Verification requires a changed boot identity and matching values");
            provider.Mode = "02";
            Reject(() => flow.ReviewUndo(ready.Directory), "Undo does not overwrite a setting changed again by someone else");
            provider.Mode = "01";
            var inverse = flow.ReviewUndo(ready.Directory);
            var inverseHash = OperationFiles.HashFile(Path.Combine(inverse, "review.json"));
            check(flow.Apply(inverse, inverseHash).Status == "restartRequired" && provider.Mode == "00" && provider.Delay == "5", "Undo creates a fresh review and restores only settings still owned by the earlier change");
            check(File.ReadAllText(originalPath) == ExportText, "Apply, verification and undo retain the original export unchanged");

            foreach (var failure in new[] { "nonzero", "partial", "exception", "export", "reportedError" })
            {
                var attempt = Prepared();
                provider.FailImport = failure == "nonzero"; provider.Partial = failure == "partial"; provider.ThrowAfterWrite = failure == "exception"; provider.ReportError = failure == "reportedError";
                provider.FailExportAfterImport = failure == "export";
                var result = flow.Apply(attempt.Directory, attempt.Hash);
                check(result.Status == "needsAttention", "A " + failure + " import outcome never reports success");
                var count = provider.ImportCalls;
                check(flow.Apply(attempt.Directory, attempt.Hash).Status == "needsAttention" && provider.ImportCalls == count, "Retry after " + failure + " does not repeat an uncertain write");
                provider.FailExport = false; provider.FailExportAfterImport = false;
                check(flow.Verify(attempt.Directory).Status == "needsAttention", "Later matching values do not erase the independent " + failure + " import failure");
            }
            var interrupted = Prepared();
            OperationFiles.Write(Path.Combine(interrupted.Directory, "journal.json"), new FirmwareJournal(interrupted.Hash, "importing", "Interrupted", null, DateTimeOffset.UtcNow));
            calls = provider.ImportCalls;
            check(flow.Apply(interrupted.Directory, interrupted.Hash).Status == "importing" && provider.ImportCalls == calls, "An interrupted journal prevents redispatch after app restart");
            check(flow.Verify(interrupted.Directory).Status == "needsAttention", "Interrupted import remains explicit during recovery");

            var vcoreProvider = new VcoreProvider(); var vcoreFlow = new FirmwareWorkflow(vcoreProvider, Path.Combine(root, "vcore"));
            var vcoreLoad = vcoreFlow.Load();
            var vcoreQuestion = vcoreFlow.Read(vcoreLoad).Questions.Single(q => q.Name == "Internal CPU Vcore 1.079V" && q.Text.Contains("Token =2A9B", StringComparison.Ordinal));
            var vcoreHash = vcoreFlow.Review(vcoreLoad, new Dictionary<string, string> { [vcoreQuestion.Id] = "5" });
            vcoreProvider.Vcore = "1.078V"; vcoreProvider.Crc = "91DA1C04";
            var driftMessage = "";
            try { vcoreFlow.Apply(vcoreLoad, vcoreHash); } catch (InvalidDataException error) { driftMessage = error.Message; }
            check(driftMessage.Contains("checksum changed", StringComparison.Ordinal) && !driftMessage.Contains("settings changed", StringComparison.Ordinal)
                && vcoreProvider.ImportCalls == 0 && !File.Exists(Path.Combine(vcoreLoad, "journal.json")),
                "A live voltage name drift before apply asks for a reload without claiming a changed setting or sending a script SCEWIN would reject");
            vcoreLoad = vcoreFlow.Load();
            vcoreQuestion = vcoreFlow.Read(vcoreLoad).Questions.Single(q => q.Name == "Internal CPU Vcore 1.078V" && q.Text.Contains("Token =2A9B", StringComparison.Ordinal));
            vcoreHash = vcoreFlow.Review(vcoreLoad, new Dictionary<string, string> { [vcoreQuestion.Id] = "5" });
            check(vcoreFlow.Apply(vcoreLoad, vcoreHash).Status == "restartRequired" && vcoreProvider.Value == "5", "The reloaded review applies the drifted question");
            string AppliedVcore()
            {
                vcoreProvider.Identity = vcoreProvider.Identity with { Boot = "boot-1" }; vcoreProvider.Crc = "0983808B"; vcoreProvider.Vcore = "1.079V"; vcoreProvider.Value = "0"; vcoreProvider.Mode = "00";
                var directory = vcoreFlow.Load();
                var target = vcoreFlow.Read(directory).Questions.Single(q => q.Name == "Internal CPU Vcore 1.079V" && q.Text.Contains("Token =2A9B", StringComparison.Ordinal));
                if (vcoreFlow.Apply(directory, vcoreFlow.Review(directory, new Dictionary<string, string> { [target.Id] = "5" })).Status != "restartRequired" || vcoreProvider.Value != "5")
                    throw new InvalidOperationException("The Vcore fixture did not apply.");
                vcoreProvider.Identity = vcoreProvider.Identity with { Boot = "boot-2" }; vcoreProvider.Vcore = "1.078V"; vcoreProvider.Crc = "91DA1C04";
                return directory;
            }
            check(vcoreFlow.Verify(AppliedVcore()).Status == "applied", "Verify after restart passes when only the live voltage names and HII checksum changed");
            var reverted = AppliedVcore(); vcoreProvider.Value = "0";
            check(vcoreFlow.Verify(reverted).Status == "needsAttention", "Verify after restart detects a reverted value on the question whose name drifted");
            var otherChanged = AppliedVcore(); vcoreProvider.Mode = "01";
            check(vcoreFlow.Verify(otherChanged).Status == "needsAttention", "Verify after restart detects another changed value while a name drifted");
            var checksumOnly = AppliedVcore(); vcoreProvider.Vcore = "1.079V";
            var checksumOnlyResult = vcoreFlow.Verify(checksumOnly);
            check(checksumOnlyResult.Status == "needsAttention" && checksumOnlyResult.Message.Contains("layout no longer matches", StringComparison.Ordinal),
                "Verify after restart rejects a changed HII checksum with no name drift as a layout change");
            var vcoreUndo = vcoreFlow.ReviewUndo(AppliedVcore());
            check(vcoreFlow.Apply(vcoreUndo, OperationFiles.HashFile(Path.Combine(vcoreUndo, "review.json"))).Status == "restartRequired" && vcoreProvider.Value == "0",
                "Undo finds the reviewed question after its live voltage name drifted");
            var staleLoad = vcoreFlow.Load();
            var staleQuestion = vcoreFlow.Read(staleLoad).Questions.Single(q => q.Name == "Vcore Voltage Mode");
            var staleHash = vcoreFlow.Review(staleLoad, new Dictionary<string, string> { [staleQuestion.Id] = "01" });
            vcoreProvider.Vcore = "1.076V"; vcoreProvider.Crc = "6B6B6B6B"; vcoreProvider.Value = "3";
            var staleCalls = vcoreProvider.ImportCalls;
            Reject(() => vcoreFlow.Apply(staleLoad, staleHash), "A changed value is still reported as changed after load when a name also drifted");
            check(vcoreProvider.ImportCalls == staleCalls && vcoreProvider.Mode == "00", "The stale review with name drift and a changed value writes nothing");

            var parallel = Prepared();
            using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
            provider.BeforeImport = () => { entered.Set(); if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException(); };
            var task = Task.Run(() => flow.Apply(parallel.Directory, parallel.Hash));
            try
            {
                if (!entered.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Fixture import did not start.");
                Reject(() => flow.Apply(parallel.Directory, parallel.Hash), "A second firmware operation cannot run while another import is active");
            }
            finally { release.Set(); }
            check(task.GetAwaiter().GetResult().Status == "restartRequired", "The original import completes after the concurrent attempt is rejected");
            provider.BeforeImport = null;
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
        check(!Directory.Exists(root), "Firmware fixtures leave no helper, state or export behind");
        RestartChecks.Run(check);
    }

    private sealed class VcoreProvider : IFirmwareProvider
    {
        public FirmwareIdentity Identity = new("vcore-pc", "Gigabyte B760M DS3H", "F4", "boot-1");
        public string Crc = "0983808B", Vcore = "1.079V", Value = "0", Mode = "00";
        public int ImportCalls;
        public FirmwareIdentity ReadIdentity() => Identity;
        public string PackageFingerprint => "vcore-package";
        public byte[] Export(string directory) => Encoding.Latin1.GetBytes(VcoreExport(Crc, Vcore, Value, Mode, twin: Vcore));
        public FirmwareCommandResult Import(string path)
        {
            ImportCalls++;
            var content = File.ReadAllText(path);
            if (!content.Contains("HIICrc32= " + Crc, StringComparison.Ordinal)) return new(1, "", "ERROR: HII checksum does not match");
            var option = Regex.Match(content, @"\*\[(00|01)\]");
            var number = Regex.Match(content, @"Token =2A9B[\s\S]*?Value =<(\d+)>");
            if (option.Success) Mode = option.Groups[1].Value;
            if (number.Success) Value = number.Groups[1].Value;
            return new(0, "Fixture import finished", "");
        }
    }

    private sealed class FixtureProvider : IFirmwareProvider
    {
        public FirmwareIdentity Identity = new("fixture-pc", "fixture-board", "F4", "boot-1");
        public string Fingerprint = "fixture-package";
        public string Mode = "00", Delay = "5", Cache = "0A";
        public bool FailImport, ReportError, Partial, ThrowAfterWrite, FailExport, FailExportAfterImport;
        public int ImportCalls;
        public Action? BeforeImport;
        public FirmwareIdentity ReadIdentity() => Identity;
        public string PackageFingerprint => Fingerprint;
        public byte[] Export(string directory)
        {
            if (FailExport) throw new IOException("Fixture export unavailable");
            return Encoding.UTF8.GetBytes(ExportText.Replace("Options =*[00]Balanced", "Options =" + (Mode == "00" ? "*" : "") + "[00]Balanced")
                .Replace("         [01]Performance", "         " + (Mode == "01" ? "*" : "") + "[01]Performance")
                .Replace("         [02]Quiet", "         " + (Mode == "02" ? "*" : "") + "[02]Quiet")
                .Replace("Value =<5>", "Value =<" + Delay + ">").Replace("Value =0A", "Value =" + Cache));
        }
        public FirmwareCommandResult Import(string path)
        {
            BeforeImport?.Invoke(); ImportCalls++;
            var content = File.ReadAllText(path);
            if (!content.Contains("HIICrc32 = A1B2C3D4") || content.Contains("Token =12") || content.Contains("Token =13")) throw new InvalidDataException("Unexpected fields reached the fixture importer.");
            var option = Regex.Match(content, @"\*\[(00|01|02)\]");
            var number = Regex.Match(content, @"Value =<(\d+)>");
            if (option.Success) Mode = option.Groups[1].Value;
            if (number.Success && !Partial) Delay = number.Groups[1].Value;
            if (FailExportAfterImport) FailExport = true;
            if (ThrowAfterWrite) throw new IOException("Fixture communication interrupted after write");
            return new(FailImport ? 23 : 0, ReportError ? "ERROR: a variable could not be updated" : "Fixture import finished", "");
        }
    }
}
