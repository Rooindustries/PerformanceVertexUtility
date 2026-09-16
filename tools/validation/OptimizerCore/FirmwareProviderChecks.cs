using Roo.Optimizer;
using System.Diagnostics;

static class FirmwareProviderChecks
{
    public static void Run(Action<bool, string> check, string fixture)
    {
        var authority = Path.Combine(fixture, "fixture-authority.txt");
        if (!File.Exists(authority) || File.ReadAllText(authority) != "roo-firmware-cli-fixture/v1") throw new InvalidDataException("A disposable fixture directory is required.");
        var root = Path.Combine(Path.GetTempPath(), "roo-firmware-provider-" + Guid.NewGuid().ToString("N"));
        try
        {
            var package = ScewinProvider.Inspect(fixture);
            check(package.Executable == "SCEWIN64.exe" && package.Signature == "NotSigned", "The adapter reports fixture package identity and signature without running it");
            var directory = ScewinProvider.SetUp(fixture, package, Path.Combine(root, "packages"));
            // The fixture refuses to run without this explicit marker, which is never a provider feature.
            File.WriteAllText(Path.Combine(directory, "fixture-authority.txt"), "roo-firmware-cli-fixture/v1");
            var provider = new ScewinProvider(directory);
            using (var held = Process.Start(new ProcessStartInfo(Path.Combine(directory, "SCEWIN64.exe"), "--hold") { UseShellExecute = false, CreateNoWindow = true })!)
            {
                try
                {
                    var blocked = false;
                    try { provider.Export(directory); } catch (InvalidOperationException error) { blocked = error.Message.Contains("Another SCEWIN operation"); }
                    check(blocked && !File.Exists(Path.Combine(directory, "calls.log")), "An existing helper process prevents a second adapter command, including after an interrupted app session");
                }
                finally { if (!held.HasExited) held.Kill(); held.WaitForExit(); }
            }
            var identity = provider.ReadIdentity();
            check(!string.IsNullOrWhiteSpace(identity.Board) && !string.IsNullOrWhiteSpace(identity.Bios), "The Windows adapter reads actual motherboard and BIOS identity");
            var flow = new FirmwareWorkflow(provider, Path.Combine(root, "sessions"));
            var session = flow.Load();
            var question = flow.Read(session).Questions.Single(q => q.Name == "Fixture option");
            var hash = flow.Review(session, new Dictionary<string, string> { [question.Id] = "01" });
            check(flow.Apply(session, hash).Status == "restartRequired" && File.ReadAllText(Path.Combine(directory, "fixture-state.txt")) == "01|5", "Production SCEWIN adapter executes setup, export, reviewed import and verification against a disposable CLI");
            var calls = File.ReadAllLines(Path.Combine(directory, "calls.log"));
            check(calls.Count(c => c.StartsWith("/i|", StringComparison.Ordinal)) == 1
                && calls.Single(c => c.StartsWith("/i|", StringComparison.Ordinal)).EndsWith("|/r", StringComparison.Ordinal)
                && calls.All(c => !c.Contains("|/d") && !c.Contains("|/reboot") && !c.Contains("|/shutdown")), "The adapter keeps CRC verification enabled and never embeds bypass or reboot switches");
            var replay = flow.Apply(session, hash);
            check(replay.Status == "restartRequired" && File.ReadAllLines(Path.Combine(directory, "calls.log")).Length == calls.Length, "Adapter-level duplicate apply launches no second helper process");
            var inverse = flow.ReviewUndo(session);
            check(flow.Apply(inverse, OperationFiles.HashFile(Path.Combine(inverse, "review.json"))).Status == "restartRequired"
                && File.ReadAllText(Path.Combine(directory, "fixture-state.txt")) == "00|5", "The same real CLI adapter restores the disposable setting through a fresh undo review");
            File.AppendAllText(Path.Combine(directory, "SCEWIN64.exe"), "tamper");
            var rejected = false;
            try { _ = provider.PackageFingerprint; } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Changing the helper binary after setup is detected before another invocation");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
        check(!Directory.Exists(root), "CLI adapter verification removes all disposable package and recovery files");
    }
}
