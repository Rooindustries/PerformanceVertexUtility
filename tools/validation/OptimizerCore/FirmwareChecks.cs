using System.Text;
using System.Text.RegularExpressions;
using Roo.Optimizer;

static class FirmwareChecks
{
    internal const string ExportText = """
// Fixture export; no physical firmware is used.
HIICrc32 = A1B2C3D4

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
""";
    public static void Run(Action<bool, string> check)
    {
        void Reject(Action action, string message)
        {
            var rejected = false;
            try { action(); } catch (Exception e) when (e is InvalidDataException or IOException) { rejected = true; }
            check(rejected, message);
        }
        var script = new FirmwareScript(Encoding.UTF8.GetBytes(ExportText));
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

        var root = Path.Combine(Path.GetTempPath(), "roo-firmware-" + Guid.NewGuid().ToString("N"));
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
