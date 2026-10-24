using System.Reflection;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class UpdateInstallChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        GameSessionEntry Session(bool? running, string? error = null) => new(@"C:\fixture\game-session-1\session", new ProtectedSessionStatus(null, running, error));
        GameSessionEntry[] sessions = [];
        string? gameTune = "{\"active\":false}";
        var timer = false;
        Exception? timerError = null;
        var free = 2L << 30;
        var gate = new InstallGate(() => Task.FromResult(sessions), () => Task.FromResult(new LiveDataResult<string>(gameTune, gameTune is null ? "Controlled Game Tune read failure" : null)),
            () => timerError is null ? timer : throw timerError, () => (@"C:\", free));
        var ready = new UpdateState("Version 9.9.9-beta is ready to install", "Fixture release notes.", Ready: true, Banner: "Version 9.9.9-beta is ready to install", BannerKind: "ready");
        UpdateState Refused(string reason) => ready with { Status = reason, Refused = true };
        void Shown(string? reason, string expected, string what)
        {
            var state = Refused(reason ?? "");
            check(reason == expected && state.BannerMessage == expected && state.Status == expected && state.CanInstall,
                what + ": the banner and Settings both say \"" + expected + "\" and Install stays available to retry");
        }

        check(await gate.ReasonAsync() is null && ready.BannerMessage == "Fixture release notes." && ready.CanInstall, "With nothing running, Install opens the confirmation and the banner shows the release notes");

        sessions = [Session(true)];
        Shown(await gate.ReasonAsync(), InstallGate.Blocked, "A running game session");
        sessions = [Session(false, "The worker exited; saved state requires recovery.")];
        Shown(await gate.ReasonAsync(), "Couldn't install the update. Couldn't confirm that all game sessions have stopped. Check Games and Undo changes first.", "An old game session that can't be read");
        sessions = [Session(null)];
        Shown(await gate.ReasonAsync(), "Couldn't install the update. Couldn't confirm that all game sessions have stopped. Check Games and Undo changes first.", "A game session with no worker state");
        sessions = [];
        gameTune = "{\"active\":true}";
        Shown(await gate.ReasonAsync(), InstallGate.Blocked, "A running game priority session");
        gameTune = null;
        Shown(await gate.ReasonAsync(), "Couldn't install the update. Couldn't read the game priority session. Check Games first.", "A game priority session that can't be read");
        gameTune = "{\"active\":false}";
        timer = true;
        Shown(await gate.ReasonAsync(), InstallGate.Blocked, "The timer setting turned on");
        timer = false;
        timerError = new InvalidOperationException("Fixture timer interval cannot be read.");
        check(await gate.ReasonAsync() is null, "A timer read failure still counts as stopped, as before");
        timerError = null;
        free = (1L << 30) - 1;
        Shown(await gate.ReasonAsync(), "Free at least 1 GB on drive C: and try again.", "Less than 1 GB free on the install drive");
        free = 1L << 30;
        check(await gate.ReasonAsync() is null, "Exactly 1 GB free is enough to install");

        var finished = 0;
        void OnFinished() => finished++;
        RunningChanges.Finished += OnFinished;
        try
        {
            string? reason;
            using (DataGeneration.BeginChange())
            {
                reason = await gate.ReasonAsync();
                var waiting = Refused(reason ?? "");
                check(reason == InstallGate.ChangeRunning && waiting.Waiting && !waiting.CanInstall && waiting.BannerMessage == InstallGate.ChangeRunning && waiting.Status == InstallGate.ChangeRunning,
                    "A removal, Windows settings apply or cleanup running: Install waits, disabled, and the banner and Settings say a change is still running");
                free = 1;
                check(await gate.ReasonAsync() == InstallGate.ChangeRunning, "A running change is named before other blockers");
                free = 1L << 30;
                check(RunningChanges.TryHold() is null, "A change that starts after the first check still stops setup from launching");
            }
            check(finished == 1 && !RunningChanges.Any && await gate.ReasonAsync() is null, "When the change finishes, install becomes available again");

            using (RunningChanges.Begin())
                check(await gate.ReasonAsync() == InstallGate.ChangeRunning && !DataGeneration.Changing, "A BIOS write running blocks Install without marking page data stale");
            check(finished == 2, "A finished BIOS write also makes install available again");

            var first = DataGeneration.BeginChange();
            var second = RunningChanges.Begin();
            first.Dispose();
            check(RunningChanges.Any && finished == 2 && await gate.ReasonAsync() == InstallGate.ChangeRunning, "With two changes running, Install keeps waiting until the last one finishes");
            second.Dispose();
            second.Dispose();
            check(!RunningChanges.Any && finished == 3, "The last change finishing reopens Install exactly once");

            var hold = RunningChanges.TryHold();
            check(hold is not null && RunningChanges.TryHold() is null, "Setup launch holds new changes while nothing is running");
            var refused = false;
            try { DataGeneration.BeginChange().Dispose(); }
            catch (InvalidOperationException error) { refused = error.Message == RunningChanges.Installing; }
            var biosRefused = false;
            try { RunningChanges.Begin().Dispose(); }
            catch (InvalidOperationException error) { biosRefused = error.Message == RunningChanges.Installing; }
            check(refused && biosRefused && !RunningChanges.Any && !DataGeneration.Changing && finished == 3, "A change can't start in the moment setup launches, and nothing is left marked running");
            hold!.Dispose();
            using (DataGeneration.BeginChange()) check(RunningChanges.Any, "If setup can't start, changes can run again");
            check(!RunningChanges.Any && finished == 4, "That change finishes normally");
        }
        finally { RunningChanges.Finished -= OnFinished; }

        check(!(ready with { Busy = true }).CanInstall && !(ready with { Ready = false }).CanInstall, "Install stays unavailable while an update check or download runs, or before an update is ready");
        check((ready with { Status = "Checking for updates...", Refused = false }).BannerMessage == "Fixture release notes.", "A later status without a refusal puts the release notes back on the banner");
        await OperationsAsync(check);
    }

    static void Set(object target, string name, object? value) => target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(target, value);

    sealed record Command(string Name, string[] Helpers, string Saved, Func<Task> Run, Func<bool> Kept, Func<bool> Refused, Func<bool> Unchanged);

    static async Task OperationsAsync(Action<bool, string> check)
    {
        var steps = new List<string>();
        var entered = new Dictionary<string, TaskCompletionSource>();
        var release = new Dictionary<string, TaskCompletionSource>();
        var order = new List<string>();
        var closed = new List<bool>();
        Func<bool> kept = () => false;
        void CloseWhenDone() { if (!RunningChanges.Any) closed.Add(kept()); }
        void Pause(params string[] helpers)
        {
            steps.Clear(); closed.Clear(); entered.Clear(); release.Clear(); order.Clear(); ServiceSteps.Written.Clear();
            foreach (var name in helpers.SelectMany(helper => new[] { helper + " starts", helper, helper + " returned" }))
            {
                order.Add(name);
                entered[name] = new(TaskCreationOptions.RunContinuationsAsynchronously);
                release[name] = new(TaskCreationOptions.RunContinuationsAsynchronously);
            }
        }
        WindowsTweaksViewModel Reviewed(bool restoring)
        {
            var model = new WindowsTweaksViewModel { ProfileId = "fixture-profile" };
            Set(model, "_review", new WindowsTweakReview(new TweakPlan
            {
                SchemaVersion = 1, OperationId = "fixture-operation", CreatedAtUtc = DateTime.UtcNow, Context = FakeOptimizerService.WindowsContext, CatalogHash = "fixture-catalog",
                BeforeRevision = null, AfterRevision = "fixture-revision", ProfileId = "fixture-profile", Selections = [], Expected = [], Changes = [], Profiles = [], Held = [],
            }, "fixture-plan.json", "fixture-hash"));
            Set(model, "_reviewedChoices", restoring ? Array.Empty<TweakSelection>() : new[] { new TweakSelection("setting", "on") });
            Set(model, "_restoringChoices", restoring);
            model.Approved = true;
            if (!model.CanApply) throw new InvalidOperationException("The reviewed Windows settings fixture is not ready to apply.");
            return model;
        }

        var root = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "roo-industries-close-when-done-" + Guid.NewGuid().ToString("N"))).FullName;
        var backup = Path.Combine(root, "process-backup.json");
        File.WriteAllText(backup, JsonSerializer.Serialize(new { actionId = "performance.applyProfile", backupId = "close-when-done", profileId = "fixture-profile", dryRun = false, snapshots = new[] { new { processId = 123, processStartTimeUtc = "2026-09-20T00:00:00Z" } } }));
        App.Live.ProcessApplyText = JsonSerializer.Serialize(new
        {
            actionId = "performance.applyProfile", dryRun = false, status = "success",
            backup = new { backupId = "close-when-done", location = backup, rollbackSupported = true },
            result = new { status = "success", summary = "One change applied.", changedItems = new[] { new { name = "fixture" } } },
        });
        App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "success", backup = new { location = backup, backupId = "close-when-done" }, result = new { status = "success", changedItems = Array.Empty<object>() } });
        App.Live.ProcessProfileRecovery = null; App.Live.OperationError = null; App.Live.LastError = null; App.Live.NvidiaApplyError = null; App.Live.NvidiaRestoreError = null;
        var profiles = new PerformanceProfilesViewModel();
        var drivers = new DriversProfilesViewModel { HasNvidia = true, HasNvidiaProfiles = true, NvidiaExportReviewed = true, NvidiaProfileApproved = true, NvidiaBenchmarkReady = true };
        App.Live.NvidiaRecovery = null;
        App.Live.NvidiaApplyRecovery = new(drivers.NvidiaProfileId, Path.Combine(root, "rollback.json"), Path.Combine(root, "before.nip"));
        App.Live.ClearNvidiaRecoveryOnRestore = true;
        var files = (RemovalCleanupReview)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(RemovalCleanupReview));
        var removal = new BulkRemovalViewModel();
        var cpu = new CpuSetsViewModel();
        var cpuJournal = Path.Combine(root, "cpu-journal.json");
        var rule = GovernorChecks.Rule("0123456789abcdef0123456789abcdef", "Fixture rule", @"C:\fixture\game.exe", true);
        App.Operations.Governor = new(new PolicySummary(false, "missing", false, 0, 0, null), new PolicyWorkerStatus(null, false, null), [rule], new());
        App.Operations.RuleSaved = null; App.Operations.RuleDeleted = null; App.Operations.PolicyWorkerError = null;
        var controls = new ProcessControlsViewModel();
        var controlsJournal = Path.Combine(root, "controls-journal.json");
        var governor = new ProcessControlsViewModel();
        var damaged = new ProcessControlsViewModel();
        WindowsTweaksViewModel? windows = null;
        var removing = new BulkRemovalViewModel();
        var removalJournal = Path.Combine(root, "removal-journal.json");
        UninstallCleanupViewModel? cleanup = null;
        string? cleanupInputs = null;
        bool Refused(string? detail) => detail == RunningChanges.Installing;

        Command[] commands =
        [
            new("Background priorities apply", ["background priorities"], "its recovery reference", () => profiles.ApplyProfileCommand.ExecuteAsync(null),
                () => App.Live.ProcessProfileRecovery is not null, () => Refused(profiles.ActionDetail), () => App.Live.ProcessProfileRecovery is null),
            new("Background priorities restore", ["background restore"], "the cleared recovery reference", () => profiles.RestoreProfileCommand.ExecuteAsync(null),
                () => App.Live.ProcessProfileRecovery is null, () => Refused(profiles.ActionDetail), () => App.Live.ProcessProfileRecovery is not null),
            new("NVIDIA profile apply", ["NVIDIA profile"], "its recovery reference", () => drivers.ApplyNvidiaProfileCommand.ExecuteAsync(null),
                () => App.Live.NvidiaRecovery is not null, () => Refused(drivers.NvidiaActionDetail), () => App.Live.NvidiaRecovery is null),
            new("NVIDIA profile restore", ["NVIDIA restore"], "the cleared recovery reference", () => drivers.RestoreNvidiaProfileCommand.ExecuteAsync(null),
                () => App.Live.NvidiaRecovery is null, () => Refused(drivers.NvidiaActionDetail), () => App.Live.NvidiaRecovery is not null),
            new("Earlier file backup restore", ["earlier files restore"], "the removed restore pointer", () => removal.RestoreLegacyFilesCommand.ExecuteAsync(null),
                () => App.Operations.FileRestore is null, () => Refused(removal.FileSummary), () => App.Operations.FileRestore == files),
            new("CPU selection apply", ["CPU selection"], "its restore pointer", () => cpu.ApplyCommand.ExecuteAsync(null),
                () => App.Operations.CpuPointer == cpuJournal, () => Refused(cpu.Detail), () => App.Operations.CpuPointer is null),
            new("CPU selection restore", ["CPU restore"], "the removed restore pointer", () => cpu.RestoreCommand.ExecuteAsync(null),
                () => App.Operations.CpuPointer is null, () => Refused(cpu.Detail), () => App.Operations.CpuPointer == cpuJournal),
            new("Process controls apply", ["process controls"], "its restore pointer", () => controls.ApplyCommand.ExecuteAsync(null),
                () => App.Operations.ProcessPointer == controlsJournal, () => Refused(controls.Detail), () => App.Operations.ProcessPointer is null),
            new("Process controls restore", ["process controls restore"], "the removed restore pointer", () => controls.RestoreCommand.ExecuteAsync(null),
                () => App.Operations.ProcessPointer is null, () => Refused(controls.Detail), () => App.Operations.ProcessPointer == controlsJournal),
            new("Governor rule turn off", ["rule save", "governor Sync"], "the governor sync", () => governor.ToggleRuleCommand.ExecuteAsync(null),
                () => true, () => Refused(governor.Detail), () => true),
            new("Governor rule delete", ["rule delete", "governor Sync"], "the governor sync", () => governor.DeleteRuleCommand.ExecuteAsync(null),
                () => App.Operations.DeletedRules.SequenceEqual([rule.RuleId]), () => Refused(governor.Detail), () => App.Operations.DeletedRules.Count == 0),
            new("Damaged rule removal", ["rule delete", "governor Sync"], "the governor sync", () => damaged.RemoveDamagedRuleCommand.ExecuteAsync(null),
                () => App.Operations.DeletedRules.SequenceEqual([rule.RuleId]), () => Refused(damaged.Detail), () => App.Operations.DeletedRules.Count == 0),
            new("Saved Windows settings restore", ["Windows helper", "remove saved choices"], "the removed saved choices", () => (windows = Reviewed(restoring: true)).ApplyCommand.ExecuteAsync(null),
                () => true, () => windows!.Status == "Settings were not confirmed" && Refused(windows.Detail), () => true),
            new("Windows settings apply", ["save choices", "Windows helper"], "the Windows apply", () => (windows = Reviewed(restoring: false)).ApplyCommand.ExecuteAsync(null),
                () => true, () => windows!.Status == "Settings were not confirmed" && Refused(windows.Detail), () => true),
            new("Remove selected apps", ["removal"], "the removal result", () => removing.ApplyCommand.ExecuteAsync(null),
                () => App.Operations.RemovalPointer == removalJournal, () => removing.Status == "Removal didn't start." && Refused(removing.Detail) && removing.CanApply, () => App.Operations.RemovalPointer is null),
            new("Reviewed cleanup apply", ["cleanup"], "the cleanup result", () => cleanup!.ApplyCleanupCommand.ExecuteAsync(null),
                () => cleanupInputs == "registry:Editor" && cleanup!.CleanupExecutionState != "Applying reviewed cleanup...",
                () => cleanup!.CleanupExecutionState == "Cleanup didn't start." && Refused(cleanup.CleanupExecutionDetail) && cleanup.CanApplyCleanup, () => cleanupInputs is null),
        ];

        ServiceSteps.Pause = async step =>
        {
            steps.Add(step);
            if (!entered.TryGetValue(step, out var reached)) throw new InvalidOperationException("Unexpected step: " + step);
            reached.SetResult();
            await release[step].Task;
        };
        RunningChanges.Finished += CloseWhenDone;
        try
        {
            foreach (var command in commands)
            {
                switch (command.Name)
                {
                    case "Earlier file backup restore":
                        App.Operations.FileRestore = files;
                        Set(removal, "_restoreReview", files);
                        removal.FileRestoreAvailable = true;
                        break;
                    case "CPU selection apply":
                        Set(cpu, "_review", new CpuSetReview(new CpuSetPlan(), Path.Combine(root, "cpu-preview.json"), "fixture-hash", cpuJournal));
                        cpu.HasReview = true;
                        break;
                    case "Process controls apply":
                        App.Operations.ControlsJournal = GovernorChecks.Journal(GovernorChecks.Process(123, @"C:\fixture\game.exe"), GovernorChecks.Owner);
                        Set(controls, "_review", new ProcessControlReview(App.Operations.ControlsJournal.Preview, Path.Combine(root, "controls-preview.json"), "fixture-hash", controlsJournal));
                        break;
                    case "Governor rule turn off":
                        await governor.RefreshRulesCommand.ExecuteAsync(null);
                        governor.SelectedRule = governor.Rules.Single();
                        break;
                    case "Governor rule delete":
                        App.Operations.DeletedRules.Clear();
                        governor.SelectedRule = governor.Rules.Single();
                        break;
                    case "Damaged rule removal":
                        App.Operations.DeletedRules.Clear();
                        damaged.SelectedDamagedRule = new DamagedRuleChoice(rule.RuleId, "The JSON is incomplete.");
                        break;
                    case "Remove selected apps":
                        Set(removing, "_review", new BulkRemovalReview(new BulkRemovalPlan(), Path.Combine(root, "removal-preview.json"), "fixture-hash", removalJournal));
                        Set(removing, "_phase", "preview");
                        break;
                    case "Reviewed cleanup apply":
                        App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
                        App.Live.InstalledApps = new() { Apps = [new InstalledApp { AppId = "registry:Editor", DisplayName = "Roo Industries Fixture Editor", SourceType = "registry" }], Complete = true };
                        cleanup = new UninstallCleanupViewModel();
                        await cleanup.InitializeAsync();
                        cleanup.SelectedApp = cleanup.Apps.Single();
                        cleanup.RemovalPathReviewed = true; cleanup.LeftoverScanCompleted = true; cleanup.CleanupPlanReady = true;
                        cleanup.RemovalApproved = true;
                        cleanup.FinalCheckPassed = true;
                        App.Live.CleanupApply = (id, _, _, _) => ServiceSteps.Then<string?>("cleanup",
                            () => JsonSerializer.Serialize(new { actionId = "apps.invokeUninstallCleanupApplyPackage", appId = id, dryRun = false, status = "success", executionMode = "real", summary = new { deletedCount = 1 } }),
                            () => cleanupInputs = id);
                        break;
                }

                Pause();
                var hold = RunningChanges.TryHold();
                try { await command.Run(); }
                catch (Exception error) { steps.Add("threw: " + error.Message); }
                finally { hold?.Dispose(); }
                check(hold is not null && steps.Count == 0 && ServiceSteps.Written.Count == 0 && closed.Count == 0 && !RunningChanges.Any && command.Refused() && command.Unchanged(),
                    command.Name + " that starts while setup launches is refused with its reason before anything is written" + (steps.Count > 0 ? " | " + string.Join(", ", steps) : ""));

                Pause(command.Helpers);
                kept = () => command.Kept() && ServiceSteps.Written.SequenceEqual(command.Helpers);
                var run = command.Run();
                var counted = new List<string>();
                foreach (var step in order)
                {
                    if (await Task.WhenAny(entered[step].Task, run) != entered[step].Task) { counted.Add(step + " never ran"); break; }
                    if (!RunningChanges.Any || closed.Count > 0) counted.Add(step);
                    release[step].SetResult();
                }
                try { await run; }
                catch (Exception error) { counted.Add("threw: " + error.Message); }
                check(counted.Count == 0, command.Name + " counts as running at every step, also after each helper returns and before its result is saved"
                    + (counted.Count > 0 ? " | not counted at: " + string.Join(", ", counted) : ""));
                check(!RunningChanges.Any && closed.SequenceEqual([true]),
                    command.Name + ": Close when done fires once, only after " + command.Saved + " is saved" + (closed.Count != 1 ? " | fired " + closed.Count + " times" : closed[0] ? "" : " | fired before it was saved"));
            }

            Pause();
            var firmware = new FirmwareViewModel { Stage = "review" };
            Set(firmware, "_sessionDirectory", Path.Combine(Path.GetTempPath(), "roo-industries-firmware-fixture-not-created"));
            Set(firmware, "_reviewHash", "fixture-review-hash");
            kept = () => true;
            var gate = typeof(RunningChanges).GetField("Gate", BindingFlags.NonPublic | BindingFlags.Static)!.GetValue(null)!;
            Task write;
            bool queued;
            lock (gate)
            {
                write = firmware.ApplyAsync();
                queued = RunningChanges.Any;
            }
            check(queued, "A confirmed BIOS write counts as running before its worker starts, so the window X and Install both wait for it");
            await write;
            check(!RunningChanges.Any && closed.SequenceEqual([true]) && firmware.Message == "Load settings to set up SCEWIN first." && !firmware.Busy,
                "The fixture BIOS write has no SCEWIN package, so nothing is written, and Close when done fires once when it ends");

            Pause();
            var biosHold = RunningChanges.TryHold();
            try { await firmware.ApplyAsync(); }
            finally { biosHold?.Dispose(); }
            check(biosHold is not null && closed.Count == 0 && firmware.Message == RunningChanges.Installing && firmware.CanApply && !RunningChanges.Any,
                "A BIOS write that starts while setup launches is refused with its reason, and the review stays ready to retry");

            Pause();
            ServiceSteps.Pause = null;
            Set(removing, "_phase", "preview");
            cleanup!.RemovalPathReviewed = true; cleanup.LeftoverScanCompleted = true; cleanup.CleanupPlanReady = true;
            cleanup.RemovalApproved = true;
            cleanup.FinalCheckPassed = true;
            App.Live.CleanupApply = (_, _, _, _) => throw new IOException("Controlled cleanup input write failure");
            await removing.ApplyCommand.ExecuteAsync(null);
            await cleanup.ApplyCleanupCommand.ExecuteAsync(null);
            check(!RunningChanges.Any && closed.SequenceEqual([true, true]) && removing.Status == "Removal needs checking." && cleanup.CleanupExecutionDetail == "Controlled cleanup input write failure",
                "A removal or cleanup that fails while preparing its files stops counting as running, and Close when done fires for each");
        }
        finally
        {
            RunningChanges.Finished -= CloseWhenDone;
            ServiceSteps.Pause = null;
            ServiceSteps.Written.Clear();
            Directory.Delete(root, recursive: true);
        }
    }
}
