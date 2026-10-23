using System.Reflection;
using RooIndustries.OptimizationSuite;
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

    static async Task OperationsAsync(Action<bool, string> check)
    {
        var steps = new List<string>();
        var entered = new Dictionary<string, TaskCompletionSource>();
        var release = new Dictionary<string, TaskCompletionSource>();
        var closed = new List<string>();
        void CloseWhenDone() { if (!RunningChanges.Any) closed.Add(string.Join(" then ", steps)); }
        void Pause(params string[] names)
        {
            steps.Clear(); closed.Clear(); entered.Clear(); release.Clear();
            foreach (var name in names) { entered[name] = new(TaskCreationOptions.RunContinuationsAsynchronously); release[name] = new(TaskCreationOptions.RunContinuationsAsynchronously); }
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

        var unexpected = App.Operations.WindowsStep;
        App.Operations.WindowsStep = async step => { steps.Add(step); entered[step].SetResult(); await release[step].Task; };
        RunningChanges.Finished += CloseWhenDone;
        try
        {
            Pause("Windows helper", "remove saved choices");
            var restore = Reviewed(restoring: true);
            var run = restore.ApplyCommand.ExecuteAsync(null);
            await entered["Windows helper"].Task;
            check(RunningChanges.Any, "Restoring a saved Windows settings profile counts as a running change while its helper works");
            release["Windows helper"].SetResult();
            await entered["remove saved choices"].Task;
            check(RunningChanges.Any && closed.Count == 0, "After the restore helper returns, Close when done keeps waiting until the profile's saved choices are removed");
            release["remove saved choices"].SetResult();
            await run;
            check(!RunningChanges.Any && closed.SequenceEqual(["Windows helper then remove saved choices"]) && restore.Status == "Settings saved; current values could not be reloaded.",
                "Close when done closes once, only after the restore and the saved-choice removal both finished");

            Pause("save choices", "Windows helper");
            var apply = Reviewed(restoring: false);
            run = apply.ApplyCommand.ExecuteAsync(null);
            await entered["save choices"].Task;
            release["save choices"].SetResult();
            await entered["Windows helper"].Task;
            check(RunningChanges.Any && closed.Count == 0, "Saving choices and applying them to Windows is one running change, with no gap between the two steps");
            release["Windows helper"].SetResult();
            await run;
            check(!RunningChanges.Any && closed.SequenceEqual(["save choices then Windows helper"]), "Close when done closes once, after the Windows apply finishes");

            Pause();
            var refused = Reviewed(restoring: false);
            var hold = RunningChanges.TryHold();
            try { await refused.ApplyCommand.ExecuteAsync(null); }
            finally { hold?.Dispose(); }
            check(hold is not null && steps.Count == 0 && closed.Count == 0 && refused.Status == "Settings were not confirmed" && refused.Detail == RunningChanges.Installing && !RunningChanges.Any,
                "A Windows settings apply that starts while setup launches is refused before any step and says why");

            Pause();
            var firmware = new FirmwareViewModel { Stage = "review" };
            Set(firmware, "_sessionDirectory", Path.Combine(Path.GetTempPath(), "roo-industries-firmware-fixture-not-created"));
            Set(firmware, "_reviewHash", "fixture-review-hash");
            var gate = typeof(RunningChanges).GetField("Gate", BindingFlags.NonPublic | BindingFlags.Static)!.GetValue(null)!;
            Task write;
            bool counted;
            lock (gate)
            {
                write = firmware.ApplyAsync();
                counted = RunningChanges.Any;
            }
            check(counted, "A confirmed BIOS write counts as running before its worker starts, so the window X and Install both wait for it");
            await write;
            check(!RunningChanges.Any && closed.Count == 1 && firmware.Message == "Load settings to set up SCEWIN first." && !firmware.Busy,
                "The fixture BIOS write has no SCEWIN package, so nothing is written, and Close when done fires once when it ends");

            Pause();
            hold = RunningChanges.TryHold();
            try { await firmware.ApplyAsync(); }
            finally { hold?.Dispose(); }
            check(hold is not null && closed.Count == 0 && firmware.Message == RunningChanges.Installing && firmware.CanApply && !RunningChanges.Any,
                "A BIOS write that starts while setup launches is refused with its reason, and the review stays ready to retry");
        }
        finally
        {
            RunningChanges.Finished -= CloseWhenDone;
            App.Operations.WindowsStep = unexpected;
        }
    }
}
