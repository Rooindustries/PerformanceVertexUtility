using System.ComponentModel;
using RooIndustries.Optimizer;

static class RestartChecks
{
    public static void Run(Action<bool, string> check)
    {
        const string system = @"C:\Windows\System32";
        var commands = SystemRestart.Commands(system);
        check(commands.Length == 2
            && commands[0] is { FileName: @"C:\Windows\System32\bcdedit.exe", Optional: true } && commands[0].Arguments.SequenceEqual(["/set", "{fwbootmgr}", "bootsequence", "{bootmgr}"])
            && commands[1] is { FileName: @"C:\Windows\System32\shutdown.exe", Optional: false } && commands[1].Arguments.SequenceEqual(["/r", "/t", "0"]),
            "Restart sets the one-time firmware boot target to Windows Boot Manager before it restarts");

        foreach (var failure in new Exception[] { new Win32Exception(2, "bcdedit.exe was not found"), new InvalidOperationException("bcdedit.exe returned 1."), new TimeoutException("bcdedit.exe did not finish.") })
        {
            var ran = new List<string>();
            Exception? skipped = null;
            SystemRestart.Restart(system, command =>
            {
                ran.Add(Path.GetFileName(command.FileName));
                if (command.FileName.EndsWith("bcdedit.exe", StringComparison.Ordinal)) throw failure;
            }, (_, error) => skipped = error);
            check(ran.SequenceEqual(["bcdedit.exe", "shutdown.exe"]) && ReferenceEquals(skipped, failure), "Restart still runs and reports the skipped boot target after: " + failure.Message);
        }

        var refused = false;
        foreach (var failBootTarget in new[] { false, true })
        {
            var sequence = new List<string>();
            SystemRestart.Restart(system, command =>
            {
                sequence.Add("run " + Path.GetFileName(command.FileName));
                if (failBootTarget && command.Optional) throw new InvalidOperationException("fixture boot target failure");
            }, log: message => sequence.Add("log " + message));
            check(sequence.SequenceEqual([
                "log Running bcdedit.exe /set {fwbootmgr} bootsequence {bootmgr}", "run bcdedit.exe",
                "log Running shutdown.exe /r /t 0", "run shutdown.exe"]),
                "Restart logs each command before running it" + (failBootTarget ? " when bcdedit fails" : ""));
        }

        try { SystemRestart.Restart(system, command => { if (command.FileName.EndsWith("shutdown.exe", StringComparison.Ordinal)) throw new InvalidOperationException("shutdown.exe returned 5."); }); }
        catch (InvalidOperationException) { refused = true; }
        check(refused, "A failed restart is reported instead of hidden");

        var root = Path.Combine(Path.GetTempPath(), "roo-industries-restart-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var reached = new List<string>();
            void Recorded(RestartCommand command) { reached.Add(Path.GetFileName(command.FileName)); SystemRestart.Run(command); }
            var missing = false;
            try { SystemRestart.Restart(root, Recorded); }
            catch (Win32Exception) { missing = true; }
            check(missing && reached.SequenceEqual(["bcdedit.exe", "shutdown.exe"]), "With bcdedit.exe missing the real runner still reaches shutdown.exe");
            File.Copy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "where.exe"), Path.Combine(root, "bcdedit.exe"));
            reached.Clear();
            var failed = false;
            try { SystemRestart.Restart(root, Recorded); }
            catch (Win32Exception) { failed = true; }
            check(failed && reached.SequenceEqual(["bcdedit.exe", "shutdown.exe"]), "A boot target command that exits with an error is ignored and the real runner goes on to shutdown.exe");
        }
        finally { Directory.Delete(root, recursive: true); }
        check(!Directory.Exists(root), "Restart fixtures leave no files behind");
    }
}
