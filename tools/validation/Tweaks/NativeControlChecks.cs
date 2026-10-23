using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class NativeControlChecks
{
    private const string TaskName = "RooIndustriesTweakProbe_ec3d917cb672498785218eb3d0aa790f";
    private const string RuleName = "RooIndustries-Block-ec3d917cb67249878";
    private const string FixtureOwner = "NativeControlChecks-v1";
    public static void RecoverFixture()
    {
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var user = users.OpenSubKey(OperationOwner.Current().UserSid, true) ?? throw new InvalidDataException("The current user hive is unavailable.");
        RequireFixtureOwner(user);
        var store = new RegistryTweakStore(new("CurrentUser", "Registry64", RegistryTweakChecks.Root + @"\Recovery", "value", "State"));
        var recovery = store.Recovery();
        if (recovery.Pending is not null) store.Recover(recovery.PendingHash!);
        if (store.Recovery().State?.Profiles.Length > 0) throw new InvalidDataException("Fixture profiles still require restoration.");
        if (Command("sc.exe", "query", ServiceProbe.Name).Exit != 1060) throw new InvalidDataException("The fixture service still exists.");
        if (new WindowsControlStore().Read(new("firewall-blocklist", RuleName, "rule")).Value.ValueKind != JsonValueKind.Null) throw new InvalidDataException("The fixture firewall rule still exists.");
        RequireFixtureOwner(user);
        user.DeleteSubKeyTree(RegistryTweakChecks.Root, false);
        using var remaining = user.OpenSubKey(RegistryTweakChecks.Root);
        if (remaining is not null) throw new InvalidDataException("Fixture recovery data remains.");
        Console.WriteLine("Recovered interrupted fixture and removed its rule and receipt.");
    }
    public static void RecoveryChecks(Action<bool, string> check)
    {
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var hive = users.OpenSubKey(OperationOwner.Current().UserSid, true) ?? throw new InvalidDataException("The current user hive is unavailable.");
        using (var existing = hive.OpenSubKey(RegistryTweakChecks.Root)) if (existing is not null) throw new InvalidDataException("The test registry root already exists.");
        var native = new WindowsControlStore();
        var firewall = new ControlAddress("firewall-blocklist", RuleName, "rule");
        if (Command("sc.exe", "query", ServiceProbe.Name).Exit != 1060 || native.Read(firewall).Value.ValueKind != JsonValueKind.Null)
            throw new InvalidDataException("The recovery test needs an absent fixture service and firewall rule.");
        bool parentExisted;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var owned = false;
        var createdRule = false;
        try
        {
            using (var key = CreateFixtureRoot(hive)) { owned = true; key.SetValue("Sentinel", "unrelated", RegistryValueKind.String); }
            void Refuses(string name)
            {
                var message = "";
                try { RecoverFixture(); } catch (InvalidDataException error) { message = error.Message; }
                using var key = hive.OpenSubKey(RegistryTweakChecks.Root);
                using var recovery = key?.OpenSubKey("Recovery");
                check(message.Contains("ownership receipt", StringComparison.Ordinal) && Equals(key?.GetValue("Sentinel"), "unrelated") &&
                    recovery?.GetValue("State") is null && recovery?.GetValue("Pending") is null, name);
            }
            Refuses("Recovery keeps an unrelated sentinel tree with no ownership receipt, State or Pending and reports the refusal");
            var refused = false;
            try { using var existing = CreateFixtureRoot(hive); } catch (InvalidDataException) { refused = true; }
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root))
                check(refused && Equals(key?.GetValue("Sentinel"), "unrelated") && key?.GetValue("FixtureOwner") is null, "Atomic fixture creation refuses an existing tree without adding a receipt");
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root, true)!) key.SetValue("FixtureOwner", "another-fixture", RegistryValueKind.String);
            Refuses("Recovery keeps a tree with another fixture's ownership receipt");
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root, true)!) key.SetValue("FixtureOwner", FixtureOwner, RegistryValueKind.ExpandString);
            Refuses("Recovery keeps a tree whose ownership receipt has the wrong registry kind");
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root, true)!) { key.SetValue("FixtureOwner", FixtureOwner, RegistryValueKind.String); key.Flush(); }
            var address = new RegistryAddress("CurrentUser", "Registry64", RegistryTweakChecks.Root + @"\Recovery", "value", "State");
            var store = new RegistryTweakStore(address);
            var blocked = ControlValues.From(new { enabled = true, addresses = new[] { "203.0.113.254" } });
            var catalog = new TweakCatalog(1, "native-recovery", [new("block", "Block", "Fixture", "Disposable firewall rule", 10240, 26200, ["*"], "none",
                [new("set", "Set", [], Controls: [new(firewall, blocked)])], [new("Roo Industries", "native fixture", "isolated Windows execution")])], []);
            var plan = new TweakEngine(catalog, store).Preview("interrupted", [new("block", "set")]);
            using (var key = hive.CreateSubKey(address.KeyPath))
            {
                key.SetValue("Pending", JsonSerializer.SerializeToUtf8Bytes(new ControlJournal(plan, "fixture-interruption", 1), OperationFiles.Json), RegistryValueKind.Binary);
                key.Flush();
            }
            native.Write(plan.Controls!.Changes.Single().Before, blocked);
            createdRule = true;
            check(store.Recovery().Pending is not null && ControlValues.Equal(native.Read(firewall).Value, blocked), "The recorded interrupted fixture has a pending journal and its own firewall rule");
            RecoverFixture();
            owned = false;
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root))
                check(key is null && native.Read(firewall).Value.ValueKind == JsonValueKind.Null, "Recovery restores a recorded interrupted fixture's firewall absence and removes its owned tree");
            var missing = "";
            try { RecoverFixture(); } catch (InvalidDataException error) { missing = error.Message; }
            using (var key = hive.OpenSubKey(RegistryTweakChecks.Root))
                check(missing.Contains("ownership receipt", StringComparison.Ordinal) && key is null, "Recovery refuses a missing receipt without creating a registry tree");
        }
        finally
        {
            if (owned)
            {
                var rule = native.Read(firewall);
                if (rule.Value.ValueKind != JsonValueKind.Null)
                {
                    if (!createdRule) throw new InvalidDataException("The recovery test did not create this firewall rule; the registry receipt was kept.");
                    RequireFixtureOwner(hive);
                    if (!ControlValues.Equal(rule.Value, ControlValues.From(new { enabled = true, addresses = new[] { "203.0.113.254" } }))) throw new InvalidDataException("The test rule was changed externally.");
                    native.Write(rule, ControlValues.From<object?>(null));
                }
                hive.DeleteSubKeyTree(RegistryTweakChecks.Root, false);
            }
            if (!parentExisted)
            {
                using var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests");
                if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); hive.DeleteSubKey(@"Software\RooIndustriesTweakTests", false); }
            }
        }
    }
    public static void Run(string files, Action<bool, string> check, Action<Action, string> reject)
    {
        RecoveryChecks(check);
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var hive = users.OpenSubKey(OperationOwner.Current().UserSid, true) ?? throw new InvalidDataException("The current user hive is unavailable.");
        using (var existing = hive.OpenSubKey(RegistryTweakChecks.Root)) if (existing is not null) throw new InvalidDataException("The test registry root already exists.");
        bool parentExisted;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var native = new WindowsControlStore();
        var startup = new ControlAddress("service", ServiceProbe.Name, "startup");
        var running = startup with { Property = "running" };
        var task = new ControlAddress("scheduled-task", "\\" + TaskName, "enabled");
        var firewall = new ControlAddress("firewall-blocklist", RuleName, "rule");
        if (Command("sc.exe", "query", ServiceProbe.Name).Exit != 1060) throw new InvalidDataException("The test service already exists or its absence is unknown.");
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        scheduler.Connect(); dynamic folder = scheduler.GetFolder(@"\");
        foreach (dynamic existing in folder.GetTasks(1)) if (((string)existing.Name).Equals(TaskName, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The test task already exists.");
        if (native.Read(firewall).Value.ValueKind != JsonValueKind.Null) throw new InvalidDataException("The test firewall rule already exists.");
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using (var existing = machine.OpenSubKey(RegistryTweakChecks.Root)) if (existing is not null) throw new InvalidDataException("The machine test registry root already exists.");
        using (var key = CreateFixtureRoot(hive)) { key.SetValue("FixtureOwner", FixtureOwner, RegistryValueKind.String); key.Flush(); }
        var createdService = false; var createdTask = false;
        try
        {
            var executable = Path.Combine(new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!.FullName, "dotnet.exe");
            if (!File.Exists(executable)) throw new FileNotFoundException("The fixture service requires an absolute .NET host path.", executable);
            var binary = Quote(executable) + " " + Quote(typeof(NativeControlChecks).Assembly.Location) + " --service-probe";
            var creation = Command("sc.exe", "create", ServiceProbe.Name, "binPath=", binary, "start=", "demand", "DisplayName=", "Roo Industries temporary settings test");
            if (creation.Exit != 0) throw new IOException("Service fixture creation failed: " + creation.Output);
            createdService = true;
            dynamic definition = scheduler.NewTask(0);
            definition.RegistrationInfo.Description = "Roo Industries temporary settings test; removed after validation";
            definition.Principal.UserId = OperationOwner.Current().UserSid;
            definition.Principal.LogonType = 3;
            definition.Settings.Enabled = false;
            definition.Settings.ExecutionTimeLimit = "PT1M";
            dynamic action = definition.Actions.Create(0);
            action.Path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            action.Arguments = "/d /c exit 0";
            folder.RegisterTaskDefinition(TaskName, definition, 2, OperationOwner.Current().UserSid, null, 3, null);
            createdTask = true;
            var recovery = new RegistryAddress("CurrentUser", "Registry64", RegistryTweakChecks.Root + @"\Recovery", "value", "State");
            var store = new RegistryTweakStore(recovery);
            var machineAddress = new RegistryAddress("LocalMachine", "Registry64", RegistryTweakChecks.Root + @"\Machine", "value", "Enabled");
            TweakDefinition Setting(string id, ControlAddress address, object? value) => new(id, id, "Fixture", "Disposable native Windows setting", 10240, 26200, ["*"], "none",
                [new("set", "Set", [], Controls: [new(address, ControlValues.From(value))])], [new("Roo Industries", "native fixture", "isolated Windows execution")]);
            var catalog = new TweakCatalog(1, "native-fixture", [Setting("automatic", startup, 2), Setting("disabled", startup, 4), Setting("run", running, true), Setting("stop", running, false),
                Setting("task", task, true), Setting("block", firewall, new { enabled = true, addresses = new[] { "203.0.113.254" } }),
                new("machine", "Machine fixture", "Fixture", "Disposable HKLM write", 10240, 26200, ["*"], "none", [new("set", "Set", [new(machineAddress, 1)])], [new("Roo Industries", "fixture", "isolated HKLM write")])], []);
            var engine = new TweakEngine(catalog, store);
            TweakState Apply(string profile, params TweakSelection[] choices)
            {
                var plan = engine.Preview(profile, choices); var review = Path.Combine(files, plan.OperationId + ".json"); OperationFiles.Write(review, plan);
                return engine.Apply(review, OperationFiles.HashFile(review)).State;
            }
            var driverRefused = false;
            try { native.Read(new ControlAddress("service", "NetBT", "running")); }
            catch (InvalidDataException error) when (error.Message.Contains("Windows driver", StringComparison.Ordinal)) { driverRefused = true; }
            check(driverRefused && native.Read(new ControlAddress("service", "NetBT", "startup")).Value.ValueKind == System.Text.Json.JsonValueKind.Number,
                "A Windows driver's running state is refused before any change while its startup type stays readable");
            var originalStartup = native.Read(startup); var originalRunning = native.Read(running); var originalTask = native.Read(task); var originalFirewall = native.Read(firewall);
            check(originalStartup.Value.GetInt32() == 3 && !originalRunning.Value.GetBoolean() && !originalTask.Value.GetBoolean(), "Disposable service and task have independently observed initial states");
            Apply("service", new TweakSelection("automatic", "set"), new TweakSelection("run", "set"));
            check(native.Read(startup).Value.GetInt32() == 2 && native.Read(running).Value.GetBoolean(), "Native service startup and running changes survive direct API readback");
            Apply("service", new TweakSelection("disabled", "set"), new TweakSelection("stop", "set"));
            check(native.Read(startup).Value.GetInt32() == 4 && !native.Read(running).Value.GetBoolean(), "Native service stop occurs before disabling startup");
            Apply("service");
            check(native.Read(startup).Same(originalStartup) && native.Read(running).Same(originalRunning), "Native service restore returns its original configuration and running state");
            Apply("flip", new TweakSelection("disabled", "set")); native.Write(native.Read(startup), ControlValues.From(2));
            var flipPlan = engine.Preview("flip", []); native.Write(native.Read(startup), ControlValues.From(3));
            store.Commit(flipPlan, "flip");
            check(native.Read(startup).Value.GetInt32() == 3 && store.ReadState()!.Profiles.All(profile => profile.Id != "flip") && store.Recovery().Pending is null,
                "The Windows store finishes an undo when a released service changes again during it");
            Apply("flip", new TweakSelection("disabled", "set")); native.Write(native.Read(startup), ControlValues.From(2));
            var retakePlan = engine.Preview("flip", []); native.Write(native.Read(startup), ControlValues.From(4));
            reject(() => store.Commit(retakePlan, "flip-retake"), "The Windows store refuses an undo when a released service went back to the tweaked value");
            check(store.Recovery().Pending is null && store.ReadState()!.Profiles.Any(profile => profile.Id == "flip"), "The refused undo keeps ownership and leaves no pending journal");
            Apply("flip");
            check(native.Read(startup).Same(originalStartup) && store.ReadState()!.Profiles.All(profile => profile.Id != "flip"), "The undo reviewed again restores the original service startup");
            Apply("task-one", new TweakSelection("task", "set")); Apply("task-two", new TweakSelection("task", "set")); Apply("task-one");
            check(native.Read(task).Value.GetBoolean(), "Task enabled state remains while a second profile owns it");
            Apply("task-two"); check(native.Read(task).Same(originalTask), "Task restoration retains the original definition and disabled state");
            Apply("firewall", new TweakSelection("block", "set"));
            check(native.Read(firewall).Value.GetProperty("addresses")[0].GetString() == "203.0.113.254", "The disposable outbound block targets only the documentation address");
            Apply("firewall"); check(native.Read(firewall).Same(originalFirewall), "Firewall restoration removes the newly created rule");
            Apply("mixed", new TweakSelection("machine", "set"), new TweakSelection("task", "set"));
            using (var key = machine.OpenSubKey(machineAddress.KeyPath)) check(Equals(key?.GetValue("Enabled"), 1), "The approved HKLM root fix writes through the real machine registry transaction");
            Apply("mixed");
            using (var key = machine.OpenSubKey(RegistryTweakChecks.Root)) check(key is null, "Machine-wide original absence and created-key cleanup are restored");
            var fault = engine.Preview("fault", [new("machine", "set"), new("task", "set")]);
            var broken = fault with { Changes = fault.Changes.Select(change => change with { After = new("Enabled", 4, [1]) }).ToArray() };
            reject(() => store.Commit(broken, "fixture-failure"), "A registry-phase failure rolls back preceding real task changes");
            check(native.Read(task).Same(originalTask) && store.Recovery().Pending is null, "Failed compound apply restores the task and clears its pending journal");
            var interrupted = engine.Preview("interrupted", [new("task", "set")]);
            var journal = new ControlJournal(interrupted, "fixture-interruption", 1);
            using (var key = hive.CreateSubKey(recovery.KeyPath)) key.SetValue("Pending", JsonSerializer.SerializeToUtf8Bytes(journal, OperationFiles.Json), RegistryValueKind.Binary);
            native.Write(originalTask, ControlValues.From(true));
            reject(() => new RegistryTweakStore(recovery).ReadState(), "A recreated backend detects a durable interrupted-operation journal");
            var resumed = new RegistryTweakStore(recovery);
            resumed.Recover(resumed.Recovery().PendingHash!);
            check(native.Read(task).Same(originalTask) && resumed.Recovery().Pending is null, "Recovery after a simulated interruption restores the real task from its journal");
            check(store.ReadState()!.Profiles.Length == 0 && store.Recovery().Pending is null, "Completed native operations leave no pending journal or active fixture profiles");
        }
        finally
        {
            var errors = new List<string>();
            void Cleanup(string name, Action action)
            {
                try { action(); } catch (Exception error) { errors.Add(name + ": " + error.Message); }
            }
            Cleanup("task", () => { if (createdTask) folder.DeleteTask(TaskName, 0); });
            Cleanup("task handles", () => { Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler); });
            Cleanup("firewall", () =>
            {
                var rule = native.Read(firewall);
                if (rule.Value.ValueKind != JsonValueKind.Null)
                {
                    if (!ControlValues.Equal(rule.Value, ControlValues.From(new { enabled = true, addresses = new[] { "203.0.113.254" } }))) throw new InvalidDataException("The test rule was changed externally.");
                    native.Write(rule, ControlValues.From<object?>(null));
                }
            });
            Cleanup("service", () =>
            {
                if (!createdService) return;
                if (native.Read(running).Value.GetBoolean()) native.Write(native.Read(running), ControlValues.From(false));
                var deletion = Command("sc.exe", "delete", ServiceProbe.Name);
                if (deletion.Exit != 0) throw new IOException("Service fixture cleanup failed: " + deletion.Output);
                check(Command("sc.exe", "query", ServiceProbe.Name).Exit == 1060, "Disposable service registration and service process are removed");
            });
            if (errors.Count > 0) throw new IOException("Fixture cleanup needs recovery; registry receipts were retained: " + string.Join("; ", errors));
            using (var remainingMachine = machine.OpenSubKey(RegistryTweakChecks.Root))
                if (remainingMachine is not null) throw new InvalidDataException("The machine fixture needs restoration; its recovery record was retained.");
            RequireFixtureOwner(hive);
            hive.DeleteSubKeyTree(RegistryTweakChecks.Root, false);
            if (!parentExisted)
            {
                using var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests");
                if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); hive.DeleteSubKey(@"Software\RooIndustriesTweakTests", false); }
            }
            using var remaining = hive.OpenSubKey(RegistryTweakChecks.Root);
            check(remaining is null && native.Read(firewall).Value.ValueKind == JsonValueKind.Null, "Disposable native recovery keys and firewall rule are removed");
        }
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(SafeRegistryHandle key, string subKey, int reserved, string? className, int options, int access, IntPtr security, out SafeRegistryHandle result, out int disposition);
    private static RegistryKey CreateFixtureRoot(RegistryKey hive)
    {
        var status = RegCreateKeyEx(hive.Handle, RegistryTweakChecks.Root, 0, null, 0, 0x2001f | (int)hive.View, IntPtr.Zero, out var handle, out var disposition);
        if (status != 0) { handle.Dispose(); throw new System.ComponentModel.Win32Exception(status); }
        if (disposition != 1) { handle.Dispose(); throw new InvalidDataException("The test registry root already exists; it will not be reused."); }
        return RegistryKey.FromHandle(handle, hive.View);
    }
    private static void RequireFixtureOwner(RegistryKey hive)
    {
        using var key = hive.OpenSubKey(RegistryTweakChecks.Root);
        if (key?.GetValue("FixtureOwner", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not string owner || owner != FixtureOwner || key.GetValueKind("FixtureOwner") != RegistryValueKind.String)
            throw new InvalidDataException("The fixture ownership receipt is missing or does not match; the registry tree was kept.");
    }
    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
    private static (int Exit, string Output) Command(string name, params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), name)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30000)) { process.Kill(true); throw new IOException("Fixture command timed out."); }
        Task.WaitAll(output, errors); return (process.ExitCode, output.Result + errors.Result);
    }
}
