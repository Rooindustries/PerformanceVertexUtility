using System.Diagnostics;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class KillApplyChecks
{
    const string Root = @"Software\RooIndustriesTweakTests\5e1b3c7a9d2f4e60b8a1c3d5e7f90a2b";
    public const string ServiceName = "RooIndustriesBoundsProbe_5e1b3c7a9d2f4e60b8a1c3d5e7f90a2b";
    const int StopDelay = 14000;
    static readonly RegistryAddress Recovery = new("CurrentUser", "Registry64", Root + @"\Recovery", "value", "State");
    static readonly ControlAddress Startup = new("service", ServiceName, "startup");
    static readonly ControlAddress Running = Startup with { Property = "running" };

    static TweakCatalog Catalog()
    {
        TweakDefinition Setting(string id, ControlAddress address, object value) => new(id, id, "Fixture", "Disposable service", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(address, ControlValues.From(value))])], [new("Roo Industries", "kill fixture", "isolated Windows execution")]);
        return new TweakCatalog(1, "kill-apply", [Setting("stop", Running, false), Setting("disable", Startup, 4)], []);
    }

    public static void Child(string files)
    {
        var engine = new TweakEngine(Catalog(), new RegistryTweakStore(Recovery));
        var plan = engine.Preview("kill", [new("stop", "set"), new("disable", "set")]);
        var path = Path.Combine(files, plan.OperationId + ".json");
        OperationFiles.Write(path, plan);
        Console.WriteLine("APPLYING"); Console.Out.Flush();
        engine.Apply(path, OperationFiles.HashFile(path));
        Console.WriteLine("APPLIED");
    }

    static (int Exit, string Output) Command(string name, params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), name)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30000)) { process.Kill(true); throw new IOException("Fixture command timed out."); }
        Task.WaitAll(output, errors); return (process.ExitCode, output.Result + errors.Result);
    }

    static string State() => Command("sc.exe", "query", ServiceName).Output;

    static bool WaitFor(Func<bool> ready, int seconds)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(seconds)) { if (ready()) return true; Thread.Sleep(100); }
        return false;
    }

    public static void Run(string files, Action<bool, string> check)
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var existing = hive.OpenSubKey(Root)) if (existing is not null) throw new InvalidDataException("The kill fixture registry root already exists; it will not be reused.");
        if (Command("sc.exe", "query", ServiceName).Exit != 1060) throw new InvalidDataException("The kill fixture service already exists or its absence is unknown.");
        bool parentExisted;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var store = new RegistryTweakStore(Recovery);
        Process? child = null;
        var created = false;
        try
        {
            var executable = Path.Combine(new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!.FullName, "dotnet.exe");
            var binary = "\"" + executable + "\" \"" + typeof(KillApplyChecks).Assembly.Location + "\" --service-probe-slow " + ServiceName + " " + StopDelay;
            var creation = Command("sc.exe", "create", ServiceName, "binPath=", binary, "start=", "demand", "DisplayName=", "Roo Industries temporary kill test");
            if (creation.Exit != 0) throw new IOException("Service fixture creation failed: " + creation.Output);
            created = true;
            var started = Command("sc.exe", "start", ServiceName);
            check(started.Exit == 0 && WaitFor(() => State().Contains("RUNNING"), 30), "The disposable service starts and is running before the apply");
            var original = new WindowsControlStore().Read(Startup).Value.GetInt32();
            check(original == 3, "The disposable service starts with startup type Manual");

            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet") start.ArgumentList.Add(System.Reflection.Assembly.GetEntryAssembly()!.Location);
            start.ArgumentList.Add("--kill-apply-child"); start.ArgumentList.Add(files);
            child = Process.Start(start)!;
            var output = child.StandardOutput.ReadToEndAsync(); var errors = child.StandardError.ReadToEndAsync();
            var mid = WaitFor(() => store.Recovery().Pending is { Attempted: >= 1 } && State().Contains("STOP_PENDING"), 60);
            check(mid && !child.HasExited, "The apply child is blocked mid-write: its journal records the attempted write while the service is still stopping");
            child.Kill(entireProcessTree: true); child.WaitForExit();
            check(child.ExitCode != 0, "The apply child is killed before it finishes");

            var pending = store.Recovery();
            check(pending.Pending is { Phase: "applying", Attempted: 1 } && pending.PendingHash is not null && pending.State is null, "The killed apply leaves a readable journal with its attempted write and no committed state");
            var refused = "";
            try { new RegistryTweakStore(Recovery).ReadState(); } catch (InvalidDataException error) { refused = error.Message; }
            check(refused.Contains("interrupted", StringComparison.OrdinalIgnoreCase), "New work is refused until the interrupted apply is recovered: " + refused);

            string firstAttempt;
            try { new RegistryTweakStore(Recovery).Recover(pending.PendingHash!); firstAttempt = "recovered immediately"; }
            catch (Exception error) { firstAttempt = error.Message; }
            Console.WriteLine("First recovery attempt while the service was still stopping: " + firstAttempt);
            var recovered = false;
            var watch = Stopwatch.StartNew();
            while (!recovered && watch.Elapsed < TimeSpan.FromSeconds(90))
            {
                var attempt = new RegistryTweakStore(Recovery);
                if (attempt.Recovery().Pending is null) { recovered = true; break; }
                try { recovered = attempt.Recover(attempt.Recovery().PendingHash!); }
                catch (Exception error) when (error is InvalidOperationException or InvalidDataException) { Thread.Sleep(1000); }
            }
            check(recovered && new RegistryTweakStore(Recovery).Recovery().Pending is null, "Recovery from the journal finishes once the stopping service settles and clears the journal");
            var qc = Command("sc.exe", "qc", ServiceName).Output;
            check(State().Contains("RUNNING") && qc.Contains("DEMAND_START", StringComparison.Ordinal) && new RegistryTweakStore(Recovery).Recovery().State is null,
                "Recovery returns the service to running with startup Manual and leaves no profile or journal");
        }
        finally
        {
            var errors = new List<string>();
            void Cleanup(string name, Action action)
            {
                try { action(); } catch (Exception error) { errors.Add(name + ": " + error.Message); }
            }
            Cleanup("child", () => { if (child is { HasExited: false }) child.Kill(entireProcessTree: true); });
            Cleanup("service", () =>
            {
                if (!created) return;
                Command("sc.exe", "stop", ServiceName);
                WaitFor(() => State().Contains("STOPPED"), 40);
                var deletion = Command("sc.exe", "delete", ServiceName);
                if (deletion.Exit != 0) throw new IOException("Service fixture cleanup failed: " + deletion.Output);
            });
            Cleanup("registry", () =>
            {
                hive.DeleteSubKeyTree(Root, false);
                if (!parentExisted)
                {
                    using var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests");
                    if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); hive.DeleteSubKey(@"Software\RooIndustriesTweakTests", false); }
                }
            });
            if (errors.Count > 0) throw new IOException("Kill fixture cleanup needs attention: " + string.Join("; ", errors));
            check(Command("sc.exe", "query", ServiceName).Exit == 1060, "The disposable service and its recovery key are removed");
        }
    }
}
