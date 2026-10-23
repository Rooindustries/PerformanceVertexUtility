using RooIndustries.OptimizationSuite.Services;
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
    }
}
