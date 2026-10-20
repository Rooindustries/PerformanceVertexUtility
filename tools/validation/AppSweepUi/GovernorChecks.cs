using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class GovernorChecks
{
    private static readonly OperationOwner Owner = new("FIXTURE", "S-1-5-21-1-2-3-1001");
    private static readonly string Chrome = OperatingSystem.IsWindows() ? @"C:\Fixture\chrome.exe" : "/fixture/chrome.exe";
    private static readonly string Game = OperatingSystem.IsWindows() ? @"C:\Fixture\game.exe" : "/fixture/game.exe";
    private static readonly string Legacy = OperatingSystem.IsWindows() ? @"C:\Fixture\legacy.exe" : "/fixture/legacy.exe";
    private const string RuleId = "11111111111111111111111111111111";
    private const string OtherRuleId = "22222222222222222222222222222222";
    private const string ChromeKey = "100|13300000000000000100";
    private const string Denied = "Windows denied access to this setting for this app";
    private const string Restarts = "The governor stopped. It starts again by itself within a minute, or press Start governor.";
    private const string Stays = "The governor stopped and won't start again by itself. Press Start governor to start it.";
    private const string Unknown = "The governor stopped. Press Start governor to start it.";
    private const string Retry = " Press Put settings back to try again.";
    private const string SignedIn = "The Governor is running. It keeps your rules active when this app is closed and starts when you sign in.";
    private const string NoSignIn = "The Governor is running and keeps your rules active when this app is closed, but it won't start when you sign in. Press Start governor to fix that.";
    private const string UnknownSignIn = "The Governor is running and keeps your rules active when this app is closed. The app couldn't confirm it starts when you sign in. Press Start governor to set that up again.";
    private const string RepairNote = " · press Start governor in Games > Processes";
    private const string Sid = "S-1-5-21-1-2-3-1001";
    private static readonly string Install = OperatingSystem.IsWindows() ? @"C:\Fixture\Install" : "/fixture/install";
    private static readonly string OtherInstall = OperatingSystem.IsWindows() ? @"C:\Fixture\Other" : "/fixture/other";
    private static readonly string Data = OperatingSystem.IsWindows() ? @"C:\Fixture\Data\process-rules" : "/fixture/data/process-rules";
    private static readonly string OtherData = OperatingSystem.IsWindows() ? @"C:\Fixture\Other\process-rules" : "/fixture/other/process-rules";
    private static readonly string System32 = OperatingSystem.IsWindows() ? @"C:\Windows\System32" : "/fixture/system32";

    private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);

    private static SavedProcessRule Rule(string id, string name, string path, bool enabled, OperationOwner? owner = null) => new()
    {
        SchemaVersion = 1, RuleId = id, Revision = id, Owner = owner ?? Owner, Name = name, Enabled = enabled, MatchMode = "filename", ExecutablePath = path, ExecutableHash = null,
        Controls = new() { ["cpuPriority"] = Value("High"), ["ioPriority"] = Value(2), ["gpuPriority"] = Value(4), ["memoryPriority"] = Value(5), ["priorityBoost"] = Value(false) },
        CpuSelection = null,
    };

    private static RunningProcess Process(int id, string path) => new(id, "13300000000000000" + id, path);

    private static PolicyInstance Instance(RunningProcess process, string? field, string status, string? errorKind = null, string? error = null, string? root = null) => new()
    {
        RuleId = RuleId, RuleHash = "hash", Process = process, PreviewPath = Path.Combine(root ?? "fixture", "operations", process.ProcessId + field, "preview.json"), ReviewHash = "review",
        JournalPath = Path.Combine(root ?? "fixture", "operations", process.ProcessId + field, "journal.json"), Status = status, Field = field, ErrorKind = errorKind, Error = error,
    };

    private static ProcessControlJournal Journal(RunningProcess process, OperationOwner owner, params (string Field, JsonElement Observed)[] changes) => new()
    {
        SchemaVersion = 1, ReviewHash = "review", PreviewPath = "preview.json", Status = "applied", UpdatedAtUtc = DateTime.UtcNow,
        Preview = new() { SchemaVersion = 1, OperationId = "op", Owner = owner, Identity = process, Original = new(), Desired = changes.ToDictionary(change => change.Field, change => change.Observed), TopologyHash = "topology" },
        Changes = changes.Select(change => new ControlChange { Name = change.Field, Original = Value("Normal"), Desired = change.Observed, Observed = change.Observed, Status = "applied" }).ToList(),
    };

    private static PolicyHostState Host(string status, PolicyInstance[] instances, PolicyIssue[]? issues = null, string[]? errors = null, OperationOwner? owner = null) => new()
    {
        SchemaVersion = 1, Owner = owner ?? Owner, Status = status, Host = status is "running" or "configurationError" ? new RunningProcess(4242, "133000000000000000", @"C:\Fixture\Optimizer.Host.exe") : null,
        Instances = instances.ToList(), Errors = (errors ?? []).ToList(), Issues = (issues ?? []).ToList(), UpdatedAtUtc = DateTime.UtcNow,
    };

    private static GovernorSnapshot Snapshot(bool paused, SavedProcessRule[] rules, PolicyWorkerStatus worker, Dictionary<string, ProcessControlJournal>? journals = null,
        GovernorTaskState? task = null, IReadOnlySet<string>? exited = null, IReadOnlySet<string>? unapplied = null, string? rulesError = null, string? securityProblem = null, string[]? unreadableRules = null,
        IReadOnlySet<string>? images = null)
        => new(new PolicySummary(securityProblem is null, securityProblem, paused, rules.Length, rules.Count(rule => rule.Enabled), rulesError, unreadableRules), worker, rules, journals ?? new(), task, exited, unapplied, images);

    private static async Task<(string[] View, ProcessControlsViewModel Panel)> Show(GovernorSnapshot snapshot)
    {
        App.Operations.Governor = snapshot;
        var panel = new ProcessControlsViewModel();
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        var history = new RestoreLogsViewModel();
        await history.InitializeAsync();
        var undo = history.RestoreRows.Single(row => row.Label == "Governor");
        var view = new[]
            {
                "State: " + panel.GovernorState, "Headline: " + panel.GovernorHeadline, "Detail: " + panel.GovernorDetail,
                "Buttons: pause=" + panel.CanPauseGovernor + " start=" + panel.CanStartGovernor,
            }
            .Concat(panel.GovernorRules.Select(row => "Rule " + row.Name + ": " + row.Observed.Replace("\n", " | ")))
            .Append("Undo: " + undo.Value + " (" + undo.State + ")")
            .Concat(history.HistoryRows.Where(row => row.Action == "Governor").Select(row => "History: " + row.Target + " · " + row.Change))
            .ToArray();
        return (view, panel);
    }

    private static async Task<string[]> View(GovernorSnapshot snapshot) => (await Show(snapshot)).View;

    private static void Expect(Action<bool, string> check, string[] view, string message, params string[] expected)
    {
        var keys = expected.Select(line => line[..line.IndexOf(": ", StringComparison.Ordinal)]).ToHashSet();
        var actual = view.Where(line => keys.Contains(line[..line.IndexOf(": ", StringComparison.Ordinal)])).ToArray();
        var ok = actual.SequenceEqual(expected);
        check(ok, ok ? message : message + "\n    expected:\n      " + string.Join("\n      ", expected) + "\n    got:\n      " + string.Join("\n      ", actual));
    }

    public static async Task LeftAsSetAsync(Action<bool, string> check)
    {
        var savedGovernor = App.Operations.Governor;
        var savedGame = App.Live.GameStatusModel;
        var savedRestraint = App.Live.GovernorStatusModel;
        App.Live.GameStatusModel = new GameTuneSessionStatus { Status = "notFound", Restorable = false };
        App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus { Status = "notFound", Restorable = false };
        try
        {
            var process = Process(100, Chrome);
            var rule = Rule(RuleId, "Chrome rule", Chrome, true);
            var left = Instance(process, "cpuPriority", "restored", "leftAsSet", "Left as another program set it.");
            var owned = Instance(process, "ioPriority", "restored");
            foreach (var paused in new[] { true, false })
            {
                var snapshot = Snapshot(paused, [rule], new(Host("stopped", [left, owned]), false, null));
                var view = await View(snapshot);
                Console.WriteLine(string.Join("\n", view));
                check(view.Any(line => line.StartsWith("Rule ", StringComparison.Ordinal) && line.Contains("Left as another program set it.", StringComparison.Ordinal)), "Processes shows the reason the terminal stepped-back field was left alone");
                check(view.Any(line => line.StartsWith("Undo: ", StringComparison.Ordinal) && line.Contains("Left as another program set it.", StringComparison.Ordinal)), "Undo reports the foreign value instead of claiming every setting was put back");
                check(view.Any(line => line.StartsWith("History: ", StringComparison.Ordinal) && line.Contains("Left as another program set it.", StringComparison.Ordinal)), "The closed governor history says Left as another program set it");
                check(GovernorDisplay.Changed(snapshot) == 0 && GovernorDisplay.Kept(snapshot) == 0, "A closed leftAsSet field is not counted as an owned setting needing recovery");
            }
            var denied = Snapshot(false, [rule], new(Host("running", [left], [new(RuleId, process.ProcessId, process.ExecutablePath, "Access is denied.") { Kind = "denied", Field = "cpuPriority" }]), true, null));
            var deniedView = await View(denied);
            check(deniedView.Any(line => line.StartsWith("Rule ", StringComparison.Ordinal) && line.Contains("CPU priority unavailable", StringComparison.Ordinal)), "A closed leftAsSet history row cannot hide a later denial for the same process and field");
            var legacy = Instance(process, null, "restored", "leftAsSet", "Left as another program set it.");
            var legacyJournal = Journal(process, Owner, ("cpuPriority", Value("High")), ("ioPriority", Value(2)));
            legacyJournal.Status = "restored"; legacyJournal.Changes[0].Status = "leftAsSet"; legacyJournal.Changes[1].Status = "restored";
            var legacySnapshot = Snapshot(true, [rule], new(Host("stopped", [legacy]), false, null), new Dictionary<string, ProcessControlJournal> { [legacy.JournalPath] = legacyJournal });
            var legacyView = await View(legacySnapshot);
            check(legacyView.Any(line => line.StartsWith("Rule ", StringComparison.Ordinal) && line.Contains("CPU priority · Left as another program set it.", StringComparison.Ordinal)), "A mixed terminal legacy journal names only the field that was left as set");
        }
        finally { App.Operations.Governor = savedGovernor; App.Live.GameStatusModel = savedGame; App.Live.GovernorStatusModel = savedRestraint; }
    }

    public static async Task RunAsync(Action<bool, string> check)
    {
        var savedGovernor = App.Operations.Governor;
        var savedGame = App.Live.GameStatusModel;
        var savedRestraint = App.Live.GovernorStatusModel;
        var savedProcess = App.Operations.ProcessSnapshot;
        App.Live.GameStatusModel = new GameTuneSessionStatus { Status = "notFound", Restorable = false };
        App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus { Status = "notFound", Restorable = false };
        try
        {
            await States(check);
            await Problems(check);
            await Observe(check);
            await FailedSync(check);
            await TimedOut(check);
#if !OLD_UI
            await RetryButton(check);
            await RuleValues(check);
            await RealSnapshot(check);
            await Scheduled(check);
            await Details(check);
            await LeftAsSetAsync(check);
            Restore(check);
            Probe(check);
#endif
        }
        finally
        {
            App.Operations.Governor = savedGovernor;
            App.Operations.GovernorError = null;
            App.Operations.ProcessSnapshot = savedProcess;
            App.Live.GameStatusModel = savedGame;
            App.Live.GovernorStatusModel = savedRestraint;
        }
    }

    private static async Task States(Action<bool, string> check)
    {
        var chrome = Process(100, Chrome);
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        var other = Rule(OtherRuleId, "Game rule", Game, true);
        var off = Rule(RuleId, "Chrome rule", Chrome, false);
        var exited = new HashSet<string> { ChromeKey };
        var restart = new GovernorTaskState("task", true, true, true);
        var signedIn = new GovernorTaskState("task", true, true, true, 0x00041301, true);

        var running = Host("running", [
            Instance(chrome, "cpuPriority", "active"),
            Instance(chrome, "ioPriority", "active", "denied", "NtSetInformationProcess failed with NTSTATUS 0xC0000022"),
            Instance(chrome, "gpuPriority", "conflict", "keepsChanging", ProcessPolicyHost.KeepsChanging),
            Instance(chrome, "priorityBoost", "conflict", "error", "Fixture policy denied this change"),
        ], [
            new(RuleId, 100, Chrome, "Access is denied. (Win32 5 SetProcessInformation)") { Kind = "denied", Field = "memoryPriority" },
            new(OtherRuleId, 200, null, ProcessPolicyHost.OtherAccount) { Kind = "otherAccount" },
        ]);
        var journals = new Dictionary<string, ProcessControlJournal>(StringComparer.OrdinalIgnoreCase)
        {
            [running.Instances[0].JournalPath] = Journal(chrome, Owner, ("cpuPriority", Value("High"))),
            [running.Instances[1].JournalPath] = Journal(chrome, Owner, ("ioPriority", Value(2))),
        };
        var view = await View(Snapshot(false, [rule, other], new(running, true, null), journals, signedIn, images: new HashSet<string>()));
        Expect(check, view, "Running: headline, detail and buttons",
            "State: running", "Headline: " + SignedIn,
            "Detail: 2 rules are on.", "Buttons: pause=True start=False");
        Expect(check, view, "Per-field mix: the applied field stays visible, only failed fields say unavailable, the stepped-back field says it keeps changing back, a denial is recognised by its recorded kind, not by its wording (an NTSTATUS text without the word denied still says unavailable, and an error text that mentions 'denied' is not treated as a denial)",
            "Rule Chrome rule: Now: chrome.exe (100) · CPU priority High | chrome.exe (100) · I/O priority unavailable · " + Denied
            + " | chrome.exe (100) · GPU priority · This app keeps changing it back, so the Governor stepped back. | chrome.exe (100) · Memory priority unavailable · " + Denied
            + " | chrome.exe (100) · Priority boost stepped back · Fixture policy denied this change");
        Expect(check, view, "Other account: a matching process under another Windows account says so instead of 'not running'",
            "Rule Game rule: Now: game.exe (200) · Running under another Windows account, so this rule doesn't control it.");
        Expect(check, view, "Undo page while running counts apps, not per-field records, and history has one row per app",
            "Undo: Running · 1 app changed · pause it in Games > Processes to put settings back (safe)", "History: chrome · Chrome rule · some settings stepped back");

        view = await View(Snapshot(false, [rule], new(Host("running", []), true, null), task: signedIn, images: new HashSet<string>()));
        Expect(check, view, "Running with no matching process in the process list says the app is not running", "Rule Chrome rule: Now: The app is not running right now.");

        var stale = Host("stopped", [Instance(chrome, "cpuPriority", "active")], [new(RuleId, 100, Chrome, "stale") { Kind = "denied", Field = "ioPriority" }]);
        view = await View(Snapshot(true, [rule], new(Host("stopped", []), false, null)));
        Expect(check, view, "Paused with nothing left applied: paused, settings put back, rule row explains it is paused",
            "State: paused", "Headline: Paused", "Detail: Your rules are saved but not used. The apps got their old settings back. Press Start governor to use your rules again.",
            "Buttons: pause=False start=True", "Rule Chrome rule: Now: Not applied right now because the governor is paused.", "Undo: Paused · settings put back (neutral)");

        view = await View(Snapshot(true, [rule], new(stale, false, null)));
        Expect(check, view, "Paused with an instance still active: no 'Paused' or 'settings put back' claim, Pause is offered again, the row lists the still-applied field and no stale issue",
            "State: pausing", "Headline: Pausing", "Detail: 1 app still has rule settings that were not put back. Press Pause governor to put them back.",
            "Buttons: pause=True start=True", "Rule Chrome rule: Now: Not applied right now because the governor is paused. | chrome.exe (100) · CPU priority still set by this rule",
            "Undo: Pausing · 1 app still has rule settings · open Games > Processes (medium)");
        view = await View(Snapshot(true, [rule], new(stale, true, null)));
        Expect(check, view, "Paused while the worker is still stopping says it is putting settings back", "Headline: Pausing", "Detail: Putting the old settings back for 1 app.");
        view = await View(Snapshot(true, [rule], new(stale, false, null), exited: exited));
        Expect(check, view, "Paused with an active record whose process exited counts as settings put back",
            "State: paused", "Headline: Paused", "Rule Chrome rule: Now: Not applied right now because the governor is paused.", "Undo: Paused · settings put back (neutral)");

        view = await View(Snapshot(true, [rule], new(null, null, "'n' is an invalid start of a value.")));
        Expect(check, view, "Paused with an unreadable governor state never claims the settings were put back",
            "State: notResponding", "Headline: Not responding",
            "Detail: Paused, but the app couldn't read the governor's state, so it can't confirm the old settings were put back: 'n' is an invalid start of a value.",
            "Undo: Not responding · open Games > Processes (medium)");
        var hungPause = Host("running", [Instance(chrome, "cpuPriority", "active")]);
        view = await View(Snapshot(true, [rule], new(hungPause, true, "The worker heartbeat is stale; it may be busy or unresponsive.")));
        Expect(check, view, "Paused with a hung worker shows not responding instead of pausing forever",
            "State: notResponding", "Headline: Not responding",
            "Detail: Paused, but the governor is not answering, so the old settings may not be back yet. Press Pause governor to stop it and put them back.", "Buttons: pause=True start=True");

        var starting = Host("stopped", [Instance(chrome, "cpuPriority", "applying")]);
        var unapplied = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { starting.Instances[0].JournalPath };
        view = await View(Snapshot(true, [rule], new(starting, false, null), unapplied: unapplied));
        Expect(check, view, "An applying record with no journal is not counted as a saved setting",
            "State: paused", "Headline: Paused", "Rule Chrome rule: Now: Not applied right now because the governor is paused.", "Undo: Paused · settings put back (neutral)");
        view = await View(Snapshot(false, [rule], new(Host("running", starting.Instances.ToArray()), true, null), task: signedIn, unapplied: unapplied));
        Expect(check, view, "A running governor shows an applying record with no journal as starting, not as changed",
            "Rule Chrome rule: Now: chrome.exe (100) · CPU priority starting", "Undo: Running · 0 apps changed · pause it in Games > Processes to put settings back (safe)");

        view = await View(Snapshot(false, [rule], new(stale, false, "The previous worker has exited."), task: restart));
        Expect(check, view, "Stopped with an enabled one-minute task: promises a restart within a minute, rule row says it is stopped",
            "State: stopped", "Headline: Stopped", "Detail: " + Restarts, "Buttons: pause=True start=True",
            "Rule Chrome rule: Now: Not applied right now because the governor is stopped. | chrome.exe (100) · CPU priority still set by this rule",
            "Undo: Stopped · 1 app still has saved settings · starts again by itself within a minute (medium)");
        foreach (var (task, label, detail) in new[] { ((GovernorTaskState?)null, "an unreadable", Unknown), (new GovernorTaskState("task", false, false, false), "no", Stays),
                     (new GovernorTaskState("task", true, false, true), "a disabled", Stays), (new GovernorTaskState("task", true, true, false), "a non-repeating", Stays) })
        {
            view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: task));
            Expect(check, view, "Stopped with " + label + " task never promises a restart within a minute" + (task is null ? " and does not claim it never restarts" : ""),
                "State: stopped", "Headline: Stopped", "Detail: " + detail, "Rule Chrome rule: Now: Not applied right now because the governor is stopped.",
                "Undo: Stopped · open Games > Processes to start it (medium)");
        }
        view = await View(Snapshot(false, [rule], new(Host("stopped", [], errors: ["Saved rules could not be read: fixture"]), false, null), task: restart));
        Expect(check, view, "Stopped detail keeps the last worker error", "Detail: Saved rules could not be read: fixture " + Restarts);

        view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: new GovernorTaskState("task", true, true, true, 1)));
        Expect(check, view, "Stopped with a one-minute task whose last start failed says so instead of promising a restart",
            "State: stopped", "Headline: Stopped",
            "Detail: The governor stopped and its last automatic start failed (error 0x00000001), so it may not start again by itself. Press Start governor to start it.",
            "Undo: Stopped · open Games > Processes to start it (medium)");
        view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: new GovernorTaskState("task", true, true, true, 0x41303)));
        Expect(check, view, "Stopped with a one-minute task that has not run yet still promises the restart", "Detail: " + Restarts);
        foreach (var (code, label) in new[] { (unchecked((int)0x800710E0), "had a launch ignored while it was running"), (unchecked((int)0x00041301), "was running"),
                     (unchecked((int)0x8004131F), "had a launch ignored because it was already running"), (0x00041300, "was ready"), (0x00041306, "was ended by the user"), (0x00041325, "was queued"), (0x00041308, "was set to start on an event") })
        {
            view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: new GovernorTaskState("task", true, true, true, code)));
            Expect(check, view, "Stopped with a one-minute task whose last run " + label + " still promises the restart", "Detail: " + Restarts);
        }
        view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: new GovernorTaskState("task", true, true, true, unchecked((int)0x80070002))));
        Expect(check, view, "Stopped with a one-minute task whose host file was not found says the last start failed",
            "Detail: The governor stopped and its last automatic start failed (error 0x80070002), so it may not start again by itself. Press Start governor to start it.");
        foreach (var (label, codes) in new[]
                 {
                     ("an account problem", new uint[] { 0x8004130F, 0x80041310, 0x80041311, 0x80041312, 0x80041314 }),
                     ("the Task Scheduler service not running or not available", new uint[] { 0x8004130C, 0x80041315, 0x80041322, 0x80041323 }),
                     ("a task Task Scheduler cannot start or read", new uint[] { 0x80041309, 0x8004130A, 0x8004130D, 0x8004130E, 0x80041313, 0x80041316, 0x80041317, 0x80041318, 0x80041319, 0x8004131A, 0x8004131D, 0x80041321, 0x80041326, 0x80041327, 0x80041328, 0x80041329, 0x80041330 }),
                     ("the user not signed in or the trigger past its end", new uint[] { 0x8004131E, 0x80041320 }),
                     ("the .NET host not finding its runtime or files", new uint[] { 0x80008080, 0x80008083, 0x80008096 }),
                     ("the launcher or the command interpreter not starting the program", new uint[] { 87, 9009, 9059 }),
                     ("a crash or a forced end", new uint[] { 0xC0000005, 0xC000013A, 0xC0000142 }),
                     ("a Windows file or folder error", new uint[] { 0x80070005, 0x80070002, 0x8007010B }),
                 })
        {
            var wrong = new List<string>();
            foreach (var code in codes)
            {
                view = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: new GovernorTaskState("task", true, true, true, unchecked((int)code))));
                if (!view.Contains("Detail: The governor stopped and its last automatic start failed (error 0x" + code.ToString("X8") + "), so it may not start again by itself. Press Start governor to start it.")) wrong.Add("0x" + code.ToString("X8"));
            }
            check(wrong.Count == 0, "Stopped with a one-minute task whose last start returned " + label + " says the last start failed" + (wrong.Count == 0 ? "" : " | did not say the last start failed for " + string.Join(", ", wrong)));
        }

        var failing = "A governor check failed and will be retried in 4 s: The process cannot access the file because it is being used by another process.";
        view = await View(Snapshot(false, [rule], new(Host("running", [], errors: [failing]), true, null)));
        Expect(check, view, "A running governor whose checks keep failing says so instead of only counting rules", "State: running", "Detail: 1 rule is on. " + failing);
        view = await View(Snapshot(false, [], new(Host("stopped", []), false, null), unreadableRules: ["The saved rule broken.json could not be read: The JSON is incomplete."]));
        Expect(check, view, "With only a damaged rule file the governor is not called off and the file is named",
            "State: notResponding", "Detail: The saved rule broken.json could not be read: The JSON is incomplete.");
        var damagedRule = "The saved rule broken.json could not be read: The JSON is incomplete.";
        view = await View(Snapshot(false, [rule], new(Host("running", [], errors: [damagedRule]), true, null), unreadableRules: [damagedRule]));
        Expect(check, view, "The error the worker records for a damaged rule file is shown once, followed by the fact that the rule is not enforced",
            "State: running", "Detail: 1 rule is on. " + damagedRule + " Those rules are not enforced.");
        view = await View(Snapshot(false, [rule], new(Host("running", [], errors: [damagedRule, failing]), true, null), unreadableRules: [damagedRule]));
        Expect(check, view, "A damaged rule file and a failing check are both shown",
            "State: running", "Detail: 1 rule is on. " + failing + " " + damagedRule + " Those rules are not enforced.");
        view = await View(Snapshot(false, [rule], new(Host("running", []), true, null), unreadableRules: [damagedRule]));
        Expect(check, view, "A running governor with one unreadable rule file keeps running and names the file",
            "State: running", "Detail: 1 rule is on. The saved rule broken.json could not be read: The JSON is incomplete. Those rules are not enforced.");

        var hung = Host("running", [Instance(chrome, "cpuPriority", "active"), Instance(chrome, "ioPriority", "active")]);
        view = await View(Snapshot(false, [rule], new(hung, true, "The worker heartbeat is stale; it may be busy or unresponsive."), journals, restart));
        Expect(check, view, "Not responding: a stale heartbeat says not answering, the row shows no stale observed values, the Undo page counts apps",
            "State: notResponding", "Headline: Not responding", "Detail: The governor is not answering. Press Start governor to restart it.", "Buttons: pause=True start=True",
            "Rule Chrome rule: Now: Not checked right now because the governor needs attention. | chrome.exe (100) · CPU priority still set by this rule | chrome.exe (100) · I/O priority still set by this rule",
            "Undo: Not responding · 1 app with saved settings · open Games > Processes (medium)");
        view = await View(Snapshot(false, [rule], new(hung, null, "Access is denied."), journals, restart));
        Expect(check, view, "Not responding: an unverifiable worker never claims it stopped or restarts by itself",
            "State: notResponding", "Detail: The governor's status could not be read: Access is denied. Press Start governor to restart it.");

        var failed = Host("stopped", [Instance(chrome, "cpuPriority", "conflict", "denied", "Access is denied.")]);
        view = await View(Snapshot(false, [off], new(failed, false, null), exited: exited));
        Expect(check, view, "Off rule with a failed restore whose process exited no longer reports saved settings",
            "State: off", "Detail: ", "Rule Chrome rule: Now: Off", "Undo: Off · no rules are on (neutral)");
        view = await View(Snapshot(false, [off], new(failed, true, null)));
        Expect(check, view, "Off rule with a failed restore on a running process says which setting could not be put back, and history says 'could not be put back'",
            "State: off", "Detail: 1 app still has a setting the app could not put back.",
            "Rule Chrome rule: Now: Off | chrome.exe (100) · CPU priority could not be put back · " + Denied, "Undo: Off · 1 app still has saved settings (medium)",
            "History: chrome · Chrome rule · a setting could not be put back");
        view = await View(Snapshot(false, [off], new(null, null, "This operation belongs to another PC or Windows user.")));
        Expect(check, view, "No rules on with an unreadable governor state stays off but does not claim every app got its settings back",
            "State: off", "Detail: The app couldn't read the governor's last state, so it can't confirm every app got its old settings back: This operation belongs to another PC or Windows user.",
            "Undo: Off · the governor's last state could not be read (medium)");
    }

    private static async Task Problems(Action<bool, string> check)
    {
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        var legacy = Process(300, Legacy);
        var instance = Instance(legacy, null, "active");
        var journals = new Dictionary<string, ProcessControlJournal>(StringComparer.OrdinalIgnoreCase)
        {
            [instance.JournalPath] = Journal(legacy, Owner, ("cpuPriority", Value("High")), ("ioPriority", Value(2))),
        };
        var view = await View(Snapshot(false, [rule], new(Host("running", [instance], [
            new(RuleId, 300, Legacy, "Access is denied.") { Kind = "denied" },
            new(RuleId, 400, Chrome, "The process could not be opened.") { Kind = "error" },
        ]), true, null), journals));
        Expect(check, view, "Legacy multi-field records show every applied field, and app-level denied or failed checks mark only the fields that are not applied",
            "Rule Chrome rule: Now: legacy.exe (300) · CPU priority High, I/O priority Normal"
            + " | legacy.exe (300) · GPU priority unavailable · " + Denied + " | legacy.exe (300) · Memory priority unavailable · " + Denied
            + " | legacy.exe (300) · Priority boost unavailable · " + Denied
            + " | chrome.exe (400) · CPU priority unavailable · The process could not be opened. | chrome.exe (400) · I/O priority unavailable · The process could not be opened."
            + " | chrome.exe (400) · GPU priority unavailable · The process could not be opened. | chrome.exe (400) · Memory priority unavailable · The process could not be opened."
            + " | chrome.exe (400) · Priority boost unavailable · The process could not be opened.");

        view = await View(Snapshot(false, [], new(Host("stopped", []), false, null), rulesError: "A rule file is damaged."));
        Expect(check, view, "A rules error says the saved rules could not be read", "State: notResponding", "Detail: Your saved rules could not be read: A rule file is damaged.");
        view = await View(Snapshot(false, [rule], new(Host("running", []), true, null), securityProblem: "the folder inherits permissions"));
        Expect(check, view, "An unsecured rules folder says so", "State: notResponding",
            "Detail: The rules folder is not protected: the folder inherits permissions. Press Start governor to repair it.");
        view = await View(Snapshot(false, [rule], new(Host("configurationError", [], errors: ["Saved rules could not be read: fixture"]), true, null)));
        Expect(check, view, "A worker in configurationError explains it keeps checking instead of claiming it is not answering", "State: notResponding",
            "Detail: Saved rules could not be read: fixture. The governor keeps checking and uses your rules again once they can be read.");
    }

    private static async Task FailedSync(Action<bool, string> check)
    {
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        App.Operations.Governor = Snapshot(false, [rule], new(Host("running", []), true, null));
        var panel = new ProcessControlsViewModel();
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        var before = panel.Rules.Single().Rule.Enabled;
        App.Operations.RuleSaved = saved => App.Operations.Governor = Snapshot(false, [saved], new(Host("running", []), true, null));
        App.Operations.PolicyWorkerError = new InvalidOperationException("Task Scheduler is unavailable.");
        try { await panel.ToggleRuleCommand.ExecuteAsync(null); }
        finally { App.Operations.PolicyWorkerError = null; App.Operations.RuleSaved = null; }
        check(before && !panel.Rules.Single().Rule.Enabled && panel.Status == "Couldn't update the rule." && panel.Detail == "Task Scheduler is unavailable.",
            "A rule that was saved before the governor sync failed shows its real state in the rules list" + (panel.Rules.Count == 1 ? " | list says enabled=" + panel.Rules.Single().Rule.Enabled : ""));
    }

    private static async Task TimedOut(Action<bool, string> check)
    {
        var timeout = new TimeoutException(AppLog.TimedOut);
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        var off = Rule(RuleId, "Chrome rule", Chrome, false);
        App.Operations.Governor = Snapshot(false, [rule], new(Host("running", []), true, null));
        var panel = new ProcessControlsViewModel();
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        App.Operations.PolicyWorkerError = timeout;
        try { await panel.PauseGovernorCommand.ExecuteAsync(null); }
        finally { App.Operations.PolicyWorkerError = null; }
        check(!panel.Busy && panel.Status == "The governor needs attention." && panel.Detail == AppLog.TimedOut && panel.CanPauseGovernor,
            "Pause governor that timed out shows the timed-out text, is not busy and can be pressed again");
        await panel.PauseGovernorCommand.ExecuteAsync(null);
        check(!panel.Busy && panel.Status == "Governor paused." && panel.Detail == "", "Pause governor pressed again after a timeout runs and reports its result");

        App.Operations.Governor = Snapshot(true, [rule], new(Host("stopped", []), false, null));
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        App.Operations.PolicyWorkerError = timeout;
        try { await panel.StartGovernorCommand.ExecuteAsync(null); }
        finally { App.Operations.PolicyWorkerError = null; }
        check(!panel.Busy && panel.Status == "The governor needs attention." && panel.Detail == AppLog.TimedOut && panel.CanStartGovernor,
            "Start governor that timed out shows the timed-out text, is not busy and can be pressed again");
        await panel.StartGovernorCommand.ExecuteAsync(null);
        check(!panel.Busy && panel.Status == "Governor started." && panel.Detail == "", "Start governor pressed again after a timeout runs and reports its result");

        App.Operations.Governor = Snapshot(false, [rule], new(Host("running", []), true, null));
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        App.Operations.RuleSaved = saved => App.Operations.Governor = Snapshot(false, [saved], new(Host("running", []), true, null));
        App.Operations.PolicyWorkerError = timeout;
        try { await panel.ToggleRuleCommand.ExecuteAsync(null); }
        finally { App.Operations.PolicyWorkerError = null; App.Operations.RuleSaved = null; }
        check(!panel.Busy && panel.Status == "Couldn't update the rule." && panel.Detail == AppLog.TimedOut && panel.CanManageRule && !panel.Rules.Single().Rule.Enabled,
            "A rule change whose governor sync timed out shows the timed-out text, the saved rule state and keeps the rule buttons enabled");
#if !OLD_UI
        var chrome = Process(100, Chrome);
        var failed = Host("stoppedWithConflicts", [Instance(chrome, "cpuPriority", "conflict", "denied", "Access is denied.")]);
        var (_, retry) = await Show(Snapshot(false, [off], new(failed, false, null)));
        var calls = App.Operations.RetryCalls;
        App.Operations.RetryRestore = () => Task.FromException<PolicyHostState>(timeout);
        await retry.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == calls + 1 && !retry.Busy && retry.Status == "Couldn't put the settings back." && retry.Detail == AppLog.TimedOut && retry.RetryAvailable && retry.CanRetryRestore,
            "Put settings back that timed out shows the timed-out text, is not busy and Put settings back can be pressed again");
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stopped", []), false, null));
            return Task.FromResult(Host("stopped", []));
        };
        await retry.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == calls + 2 && !retry.Busy && retry.Status == "The old settings are back." && !retry.RetryAvailable,
            "Put settings back pressed again after a timeout runs and reports the fresh governor state");
#endif
    }

    private static async Task Observe(Action<bool, string> check)
    {
        ControlRead Read<T>(T value) => ControlRead.From(value);
        App.Operations.ProcessSnapshot = new(new RunningProcess(123, "1", @"C:\Fixture.exe"), Read(0xfffffffeu),
            [new LogicalCpu(103, 0, 0, 0, 0, 0, 0, false, false, false), new LogicalCpu(104, 0, 1, 1, 0, 0, 0, false, false, false)],
            new Dictionary<string, ControlRead>
            {
                ["cpuPriority"] = Read("Normal"), ["ioPriority"] = Read(2), ["gpuPriority"] = Read(2), ["memoryPriority"] = Read(5),
                ["executionQoS"] = Read(new PowerThrottling(0, 0)), ["priorityBoost"] = Read(true), ["cpuSets"] = Read(Array.Empty<uint>()), ["affinity"] = Read(new AffinityState(0, "0x3")),
            });
        App.Operations.Governor = Snapshot(false, [Rule(RuleId, "Chrome rule", Chrome, true)], new(Host("running", []), true, null));
        var panel = new ProcessControlsViewModel();
        var method = typeof(ProcessControlsViewModel).GetMethod("ReadProcessAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;
        await (Task)method.Invoke(panel, [new CpuProcessChoice(123, "Fixture"), 0])!;
        App.Operations.GovernorError = new IOException("host.json is damaged");
        await panel.ObserveAsync();
        App.Operations.GovernorError = null;
        check(panel.HasProcess && panel.Status == "Controls for Fixture" && panel.GovernorHeadline == "Not responding"
                && panel.GovernorDetail == "The governor's status could not be read: host.json is damaged." && panel.GovernorRules.Count == 0,
            "A governor read failure during polling keeps the selected process and shows the governor as not responding"
            + (panel.HasProcess ? "" : " | got status: " + panel.Status + " | " + panel.Detail));
    }

#if !OLD_UI
    private static async Task RuleValues(Action<bool, string> check)
    {
        ControlRead Read<T>(T value) => ControlRead.From(value);
        var controls = new Dictionary<string, ControlRead>
        {
            ["cpuPriority"] = Read("Normal"), ["ioPriority"] = Read(2), ["gpuPriority"] = Read(2), ["memoryPriority"] = Read(5),
            ["executionQoS"] = Read(new PowerThrottling(0, 0)), ["priorityBoost"] = Read(true), ["cpuSets"] = Read(Array.Empty<uint>()), ["affinity"] = Read(new AffinityState(0, "0x3")),
        };
        var identity = new RunningProcess(123, "1", @"C:\Fixture.exe");
        App.Operations.ProcessSnapshot = new(identity, Read(0xfffffffeu), [new LogicalCpu(103, 0, 0, 0, 0, 0, 0, false, false, false)], controls);
        App.Operations.Governor = Snapshot(false, [], new(Host("stopped", []), false, null));
        App.Operations.Review = desired => new(new() { SchemaVersion = 1, OperationId = "op", Owner = Owner, Identity = identity, Original = desired.Keys.ToDictionary(name => name, name => controls[name]), Desired = desired, TopologyHash = "topology" }, "preview.json", "hash", "journal.json");
        try
        {
            var panel = new ProcessControlsViewModel();
            await panel.RefreshRulesCommand.ExecuteAsync(null);
            panel.SelectedProcess = new CpuProcessChoice(123, "Fixture");
            await (Task)typeof(ProcessControlsViewModel).GetField("_readTask", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(panel)!;
            panel.RuleName = "Fixture rule";
            async Task<bool> Reviewed(string name, JsonElement value)
            {
                foreach (var row in panel.Controls) row.Selected = row.Options[0];
                var target = panel.Controls.Single(row => row.Name == name);
                target.Selected = target.Options.Single(option => option.Value?.GetRawText() == value.GetRawText());
                await panel.PreviewCommand.ExecuteAsync(null);
                return panel.HasReview;
            }
            check(await Reviewed("cpuPriority", Value("Realtime")) && panel.CanApply && !panel.CanSaveRule && panel.HasRuleBlocker && panel.RuleBlocker.Contains("Realtime CPU priority", StringComparison.Ordinal),
                "A reviewed Realtime CPU priority can still be applied once but cannot be saved as a rule, and the panel says why" + " | " + panel.RuleBlocker);
            check(await Reviewed("gpuPriority", Value(5)) && panel.CanApply && !panel.CanSaveRule && panel.RuleBlocker.Contains("Realtime GPU priority", StringComparison.Ordinal),
                "A reviewed Realtime GPU priority can still be applied once but cannot be saved as a rule, and the panel says why" + " | " + panel.RuleBlocker);
            check(await Reviewed("cpuPriority", Value("High")) && panel.CanApply && panel.CanSaveRule && !panel.HasRuleBlocker,
                "A reviewed High CPU priority can be saved as a rule" + " | " + panel.RuleBlocker);
            check(await Reviewed("gpuPriority", Value(4)) && panel.CanSaveRule && panel.RuleBlocker.Length == 0,
                "A reviewed High GPU priority can be saved as a rule" + " | " + panel.RuleBlocker);
            var unsavable = panel.Controls.SelectMany(row => row.Options.Where(option => option.Value is { } value && ProcessPolicyStore.UnsavableReason(row.Name, value) is not null).Select(option => row.Name + "=" + option.Value!.Value.GetRawText())).OrderBy(text => text, StringComparer.Ordinal).ToArray();
            check(unsavable.SequenceEqual(["cpuPriority=\"Realtime\"", "gpuPriority=5"]),
                "The only values the panel offers that a saved rule refuses are Realtime CPU and GPU priority, and both are blocked from saving" + " | " + string.Join(", ", unsavable));
        }
        finally { App.Operations.Review = null; }
    }

    private static async Task RetryButton(Action<bool, string> check)
    {
        var baseline = App.Operations.RetryCalls;
        var chrome = Process(100, Chrome);
        var off = Rule(RuleId, "Chrome rule", Chrome, false);
        var failed = Host("stoppedWithConflicts", [Instance(chrome, "cpuPriority", "conflict", "denied", "Access is denied.")]);
        var (view, panel) = await Show(Snapshot(false, [off], new(failed, false, null)));
        Expect(check, view, "Off with a failed restore and no worker running offers Put settings back",
            "Detail: 1 app still has a setting the app could not put back." + Retry, "Undo: Off · 1 app still has saved settings · put them back in Games > Processes (medium)");
        check(panel.RetryAvailable && panel.CanRetryRestore, "The Put settings back button is shown and enabled");
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stopped", []), false, null));
            return Task.FromResult(Host("stopped", []));
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == baseline + 1 && !panel.RetryAvailable && panel.Status == "The old settings are back." && panel.GovernorDetail == "",
            "Put settings back runs one restore pass and reports the result from fresh governor state");

        App.Operations.Governor = Snapshot(true, [Rule(RuleId, "Chrome rule", Chrome, true)], new(failed, false, null));
        App.Operations.RetryRestore = () => Task.FromResult(failed);
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == baseline + 2 && panel.RetryAvailable && panel.Status == "Some settings still could not be put back."
                && panel.GovernorDetail == "Your rules are saved but not used. Some apps kept a setting the governor could not put back." + Retry + " Press Start governor to use your rules again.",
            "Paused with a failed restore offers Put settings back and says when it still fails");

        (view, panel) = await Show(Snapshot(false, [off], new(Host("running", failed.Instances.ToArray()), true, null)));
        check(!panel.RetryAvailable && !panel.GovernorDetail.Contains("Put settings back", StringComparison.Ordinal),
            "No Put settings back button while the worker is running and still retrying by itself");

        (view, panel) = await Show(Snapshot(false, [off], new(failed, false, null)));
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(null, null, "host.json is damaged"));
            return Task.FromResult(failed);
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(panel.Status == "Couldn't confirm the old settings are back.",
            "Put settings back never says the old settings are back when the state read afterwards fails" + (panel.Status.Length == 0 ? "" : " | got: " + panel.Status));

        (view, panel) = await Show(Snapshot(false, [off], new(failed, false, null)));
        var left = Instance(chrome, "cpuPriority", "restored", "leftAsSet", ProcessControlEngine.LeftAsSet);
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stopped", [left]), false, null));
            return Task.FromResult(Host("stopped", [left]));
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(!panel.RetryAvailable && panel.Status == "Some settings were left as another program set them." && panel.Detail.Contains("that program's value was kept", StringComparison.Ordinal),
            "Put settings back does not claim the old settings are back when another program's value was kept" + " | got: " + panel.Status);

        var earlier = Instance(chrome, "cpuPriority", "restored", "leftAsSet", ProcessControlEngine.LeftAsSet, "older");
        (view, panel) = await Show(Snapshot(false, [off], new(Host("stoppedWithConflicts", [failed.Instances.Single(), earlier]), false, null)));
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stopped", [Instance(chrome, "cpuPriority", "restored"), earlier]), false, null));
            return Task.FromResult(Host("stopped", []));
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(!panel.RetryAvailable && panel.Status == "The old settings are back.",
            "An older left-as-set record for the same app and setting does not change a fully successful Put settings back" + " | got: " + panel.Status);

        var cpuHeld = Instance(chrome, "cpuPriority", "conflict", "denied", "Access is denied.");
        var ioHeld = Instance(chrome, "ioPriority", "conflict", "denied", "Access is denied.");
        var cpuLeft = Instance(chrome, "cpuPriority", "restored", "leftAsSet", ProcessControlEngine.LeftAsSet);
        (view, panel) = await Show(Snapshot(false, [off], new(Host("stoppedWithConflicts", [cpuHeld, ioHeld]), false, null)));
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stoppedWithConflicts", [cpuLeft, ioHeld]), false, null));
            return Task.FromResult(Host("stoppedWithConflicts", [cpuLeft, ioHeld]));
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(panel.RetryAvailable && panel.Status == "Some settings still could not be put back." && panel.Detail == "Where another program changed a setting afterwards, that program's value was kept.",
            "Put settings back says a setting was left as another program set it even while another setting is still held" + " | got: " + panel.Status + " " + panel.Detail);

        (view, panel) = await Show(Snapshot(false, [off], new(Host("stopped", [Instance(chrome, "cpuPriority", "active")]), false, null)));
        Expect(check, view, "Off after an interrupted removal with a setting still changed tells you to press Put settings back",
            "Detail: 1 app still has rule settings that were not put back." + Retry);
        check(panel.RetryAvailable && panel.CanRetryRestore, "Off after an interrupted removal with a setting still changed offers Put settings back");
    }

    private static string Under(string root, params string[] names) => root + string.Concat(names.Select(name => Path.DirectorySeparatorChar + name));

    private static string Launch(string install, params string[] parts)
        => "--headless \"" + Under(System32, "cmd.exe") + "\" /d /e:on /v:off /c set \"SystemRoot=" + Path.GetDirectoryName(System32) + "\"&call \"" + Under(install, "backend", "scripts", "Start-RooIndustriesHelper.cmd") + "\" \" ?" + string.Join("?", parts) + "\"";

    private static string TaskXml(string command, string arguments, string workingDirectory, string user = Sid, string runLevel = "HighestAvailable", string? limit = "PT0S", string? instances = "IgnoreNew", string extraAction = "")
        => "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>Roo Industries process rules | " + Sid + " | " + Data + "</Description></RegistrationInfo>"
            + "<Triggers><TimeTrigger><StartBoundary>2026-10-01T11:00:00</StartBoundary><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><Enabled>true</Enabled></TimeTrigger></Triggers>"
            + "<Principals><Principal id=\"Author\"><UserId>" + user + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>" + runLevel + "</RunLevel></Principal></Principals>"
            + "<Settings>" + (instances is null ? "" : "<MultipleInstancesPolicy>" + instances + "</MultipleInstancesPolicy>") + (limit is null ? "" : "<ExecutionTimeLimit>" + limit + "</ExecutionTimeLimit>") + "</Settings>"
            + "<Actions Context=\"Author\"><Exec><Command>" + command + "</Command><Arguments>" + System.Security.SecurityElement.Escape(arguments) + "</Arguments><WorkingDirectory>" + workingDirectory + "</WorkingDirectory></Exec>" + extraAction + "</Actions></Task>";

    public static async Task Scheduled(Action<bool, string> check)
    {
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        var now = new DateTime(2026, 10, 1, 12, 0, 0, DateTimeKind.Local);
        var expected = new GovernorTaskExpectation(Sid, System32, Install, Data);
        var host = Under(Install, "backend", "bin", "optimizer");
        var hostExe = Under(host, "Optimizer.Host.exe");
        var hostDll = Under(host, "Optimizer.Host.dll");
        var request = Under(Data, "worker-request.json");
        var conhost = Under(System32, "conhost.exe");
        var dotnet = Under(OperatingSystem.IsWindows() ? @"C:\Users\Fixture\.dotnet" : "/fixture/.dotnet", "dotnet.exe");
        var bundled = TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host);
        var development = TaskXml(conhost, Launch(Install, dotnet, hostDll, "policy-run", request), host);
        var neutral = new[] { "State: stopped", "Headline: Stopped", "Detail: " + Unknown, "Undo: Stopped · open Games > Processes to start it (medium)" };
        var promise = new[] { "State: stopped", "Headline: Stopped", "Detail: " + Restarts, "Undo: Stopped · starts again by itself within a minute (medium)" };

        async Task<string[]> Seen(string xml, int result = 0x00041303, bool enabled = true, GovernorTaskExpectation? want = null)
            => await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: GovernorProbe.State(new GovernorTaskFacts("task", xml, enabled, result), want ?? expected, now)));

        Expect(check, await Seen(bundled), "A task with the action, principal and settings that registration builds for this install (bundled host) still promises the restart", promise);
        Expect(check, await Seen(development), "A task registered for a development host (dotnet.exe, this install's host dll) still promises the restart", promise);
        Expect(check, await Seen(TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, instances: null)), "A task without a multiple-instances element has the schema default IgnoreNew and still promises the restart", promise);
        Expect(check, await Seen(bundled, want: new GovernorTaskExpectation(Sid.ToLowerInvariant(), System32.ToUpperInvariant(), Install.ToUpperInvariant(), Data.ToUpperInvariant())),
            "Paths and the owner id are compared without regard to letter case", promise);

        var notepad = Under(System32, "notepad.exe");
        foreach (var (xml, label) in new[]
                 {
                     (TaskXml(Under(System32, "conhost.exe"), "--headless \"" + hostExe + "\" policy-run \"" + request + "\"", host), "the action is the previous direct conhost launch"),
                     (TaskXml(notepad, "", host), "the action is a plain other program"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request).Replace("/d /e:on /v:off /c set \"SystemRoot=" + Path.GetDirectoryName(System32) + "\"&call ", "/d /v:off /c call "), host), "the old clean launcher cannot repair the native environment"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request).Replace("/e:on ", ""), host), "the shell extensions override is missing"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request).Replace("SystemRoot=" + Path.GetDirectoryName(System32), "SystemRoot=" + OtherInstall), host), "the native Windows root is wrong"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request).Replace("&call ", "&echo injected&call "), host), "another native command was added"),
                     (TaskXml(notepad, Launch(Install, hostExe, "policy-run", request), host), "the program is not conhost.exe"),
                     (TaskXml(conhost, Launch(OtherInstall, Under(OtherInstall, "backend", "bin", "optimizer", "Optimizer.Host.exe"), "policy-run", request), host), "the launcher and host belong to another install"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", Under(OtherData, "worker-request.json")), host), "the request file belongs to another rules folder"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-status", request), host), "the command is not policy-run"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), Under(Install, "backend")), "the working directory is not the host folder"),
                     (TaskXml(conhost, Launch(Install, notepad, hostDll, "policy-run", request), host), "the development program is not dotnet.exe"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, extraAction: "<Exec><Command>" + notepad + "</Command></Exec>"), "a second action was added"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, runLevel: "LeastPrivilege"), "the task does not run with the highest privileges"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, user: "S-1-5-21-1-2-3-1002"), "the task runs as another user"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, user: "S-1-5-18"), "the task runs as SYSTEM"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, user: ""), "the task has no user"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, limit: "PT72H"), "the task is stopped after 72 hours"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, limit: null), "the task has no time limit setting, so Windows stops it after 72 hours"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, instances: "Parallel"), "the task starts parallel instances"),
                     (TaskXml(conhost, Launch(Install, hostExe, "policy-run", request), host, instances: "StopExisting"), "the task replaces a running instance"),
                 })
            Expect(check, await Seen(xml), "Stopped with a same-name task that repeats every minute but " + label + " never promises a restart and says it can't confirm", neutral);
        Expect(check, await Seen(bundled, want: new GovernorTaskExpectation(Sid, System32, OtherInstall, Data)), "A task for this install is not confirmed when checked against another install", neutral);
        var unknownInstall = await View(Snapshot(false, [rule], new(Host("stopped", []), false, null), task: GovernorProbe.State(new GovernorTaskFacts("task", bundled, true, 0x00041303), null, now)));
        Expect(check, unknownInstall, "A task is not confirmed when the install it should run is unknown", neutral);
        Expect(check, await Seen(TaskXml(notepad, "", host), enabled: false), "A disabled task with another action still says it won't start by itself",
            "State: stopped", "Detail: " + Stays, "Undo: Stopped · open Games > Processes to start it (medium)");

        Expect(check, await Seen(bundled, unchecked((int)0x80041320)), "A task with the right action whose last start failed because the user was not signed in says the last start failed",
            "Detail: The governor stopped and its last automatic start failed (error 0x80041320), so it may not start again by itself. Press Start governor to start it.");
        Expect(check, await Seen(TaskXml(notepad, "", host), unchecked((int)0x80041320)), "A failed last start of a task that does something else says it can't confirm", neutral);

        var silent = await Seen(bundled, 0);
        Expect(check, silent, "Registered, enabled, correct action, last result 0, no worker running and no heartbeat: the status is stopped and neutral, not running and not restarting by itself", neutral);
        check(!silent.Any(line => line.Contains("starts again by itself", StringComparison.Ordinal) || line.Contains("running", StringComparison.OrdinalIgnoreCase)),
            "Last result 0 with no worker never says running or starts again by itself anywhere on the Processes tab or the Undo page");
        foreach (var (code, label) in new[]
                 {
                     (unchecked((int)0x80041324), "the scheduler attempted the task but did not run it"), (unchecked((int)0x8004130B), "the scheduler found no running instance"), (0x00041304, "the scheduler reports no more runs"),
                     (0x00041305, "the scheduler reports the task is not scheduled"), (0x00041307, "the scheduler reports no valid triggers"), (0x0004131B, "only some triggers work"), (0x0004131C, "the batch logon right may be missing"),
                 })
            Expect(check, await Seen(bundled, code), "Stopped with the right task whose last result says " + label + " (0x" + ((uint)code).ToString("X8") + ") never promises a restart and says it can't confirm", neutral);

        string[] Alive(string headline, string note, string risk) => ["State: running", "Headline: " + headline, "Detail: 1 rule is on.", "Buttons: pause=True start=" + (risk == "ok" ? "False" : "True"),
            "Undo: Running · 0 apps changed · pause it in Games > Processes to put settings back" + note + " (" + (risk == "ok" ? "safe" : "medium") + ")"];
        async Task<string[]> Live(GovernorTaskState? task) => await View(Snapshot(false, [rule], new(Host("running", []), true, null), task: task));
        GovernorTaskState? Judged(string xml, int result = 0x00041301, bool enabled = true) => GovernorProbe.State(new GovernorTaskFacts("task", xml, enabled, result), expected, now, true);
        var alive = Alive(SignedIn, "", "ok");
        var noSignIn = Alive(NoSignIn, " · it won't start when you sign in" + RepairNote, "no");
        var unknownSignIn = Alive(UnknownSignIn, " · couldn't confirm it starts when you sign in" + RepairNote, "unknown");
        Expect(check, await Live(Judged(bundled)), "Running with the task this install registers still says it starts when you sign in, and offers no repair", alive);
        Expect(check, await Live(Judged(bundled, 0)), "Running with that task whose last result is 0 (a live worker makes 0 harmless) still says it starts when you sign in", alive);
        Expect(check, await Live(Judged(development)), "Running with the development-host task still says it starts when you sign in", alive);
        Expect(check, await Live(new GovernorTaskState("task", false, false, false, 0x00041303, true)), "Running with the task missing says it won't start when you sign in and offers Start governor to repair it", noSignIn);
        Expect(check, await Live(Judged(bundled, enabled: false)), "Running with the task disabled says it won't start when you sign in and offers Start governor to repair it", noSignIn);
        Expect(check, await Live(new GovernorTaskState("task", true, true, false, 0x00041301, true)), "Running with a task that does not repeat says it won't start when you sign in and offers Start governor to repair it", noSignIn);
        Expect(check, await Live(Judged(TaskXml(notepad, "", host))), "Running with a task that runs something else says it can't confirm the sign-in start and offers Start governor to repair it", unknownSignIn);
        Expect(check, await Live(Judged(TaskXml(conhost, Launch(OtherInstall, Under(OtherInstall, "backend", "bin", "optimizer", "Optimizer.Host.exe"), "policy-run", request), host))), "Running with the task of another install says it can't confirm the sign-in start", unknownSignIn);
        Expect(check, await Live(Judged(bundled, unchecked((int)0x80041320))), "Running with the right task whose last automatic start failed says it can't confirm the sign-in start", unknownSignIn);
        Expect(check, await Live(Judged(bundled, unchecked((int)0x80041324))), "Running with the right task whose last result is 'attempted but not run' says it can't confirm the sign-in start", unknownSignIn);
        Expect(check, await Live(null), "Running with an unreadable task (a Task Scheduler failure) never promises the sign-in start and offers Start governor", unknownSignIn);
        Expect(check, await View(Snapshot(false, [rule], new(Host("running", []), true, null), task: GovernorProbe.State(new GovernorTaskFacts("task", bundled, true, 0x00041301), null, now, true))),
            "Running with the task when the install is unknown never promises the sign-in start", unknownSignIn);
    }

    private static async Task Details(Action<bool, string> check)
    {
        var chrome = Process(100, Chrome);
        var rule = Rule(RuleId, "Chrome rule", Chrome, true);
        var signedIn = new GovernorTaskState("task", true, true, true, 0x00041301, true);
        async Task<string[]> Live(PolicyHostState host, IReadOnlySet<string>? images = null, Dictionary<string, ProcessControlJournal>? journals = null)
            => await View(Snapshot(false, [rule], new(host, true, null), journals, signedIn, images: images));
        var idle = Host("running", []);
        Expect(check, await Live(idle, new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "game.exe" }), "A running rule whose image is missing from the process list says the app is not running", "Rule Chrome rule: Now: The app is not running right now.");
        Expect(check, await Live(idle, new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Chrome.EXE" }), "A running rule whose app is in the process list but has no record says it was not applied, not that the app is not running",
            "Rule Chrome rule: Now: The app is running, but this rule hasn't been applied to it.");
        Expect(check, await Live(idle), "A running rule with no process list never claims the app is not running", "Rule Chrome rule: Now: Can't tell whether the app is running right now.");
        Expect(check, await Live(Host("running", [Instance(chrome, "cpuPriority", "active")])), "An active record whose journal could not be read says it can't confirm, not that it is starting",
            "Rule Chrome rule: Now: chrome.exe (100) · CPU priority couldn't be confirmed");
        var other = Instance(chrome, "cpuPriority", "active");
        Expect(check, await Live(Host("running", [other]), journals: new(StringComparer.OrdinalIgnoreCase) { [other.JournalPath] = Journal(chrome, Owner, ("ioPriority", Value(2))) }),
            "An active record whose journal does not list its field says it can't confirm, not that it is starting", "Rule Chrome rule: Now: chrome.exe (100) · CPU priority couldn't be confirmed");
        Expect(check, await Live(Host("running", [], [new(RuleId, 400, null, "Its program path could not be read, so this rule cannot be applied to it.") { Kind = "unavailable" }])),
            "A path-mode rule whose running app has an unreadable program path shows the reason the host recorded for it",
            "Rule Chrome rule: Now: chrome.exe (400) · unavailable · Its program path could not be read, so this rule cannot be applied to it.");

        GovernorProbe.ForgetTask();
        var reads = 0;
        var first = new GovernorTaskState("a", true, true, true, 0x00041301, true);
        GovernorTaskState? Read() { reads++; return reads == 1 ? first : null; }
        check(GovernorProbe.Cached("k", 1000, Read) == first && reads == 1, "The running task state is read from Task Scheduler on the first poll");
        check(GovernorProbe.Cached("k", 30999, Read) == first && reads == 1, "Polls within 30 seconds reuse the task state and do not read Task Scheduler again");
        check(GovernorProbe.Cached("k", 31000, Read) is null && reads == 2, "A poll 30 seconds later reads Task Scheduler again");
        check(GovernorProbe.Cached("k", 40000, Read) is null && reads == 2, "A failed read is kept for the same 30 seconds instead of hammering Task Scheduler");
        check(GovernorProbe.Cached("other", 40000, Read) is null && reads == 3, "Another rules folder or install never reuses the cached state");
        GovernorProbe.ForgetTask();
        check(GovernorProbe.Cached("other", 40001, Read) is null && reads == 4, "Starting, pausing or removing the governor discards the cached state");
        GovernorProbe.ForgetTask();
        var stale = new GovernorTaskState("stale", false, false, false, 0x00041303, true);
        check(GovernorProbe.Cached("slow", 50000, () => { GovernorProbe.ForgetTask(); return stale; }) == stale && GovernorProbe.Cached("slow", 50001, () => first) == first,
            "A read that was already running when the governor was changed is not kept, so the next poll reads the changed task");
        GovernorProbe.ForgetTask();

        var id = "0123456789abcdef0123456789abcdef";
        string[] Unreadable(params string[] files) => files;
        var damaged = "The saved rule " + id + ".json could not be read: The JSON is incomplete.";
        var broken = "The saved rule broken.json could not be read: The JSON is incomplete.";
        App.Operations.Governor = Snapshot(false, [rule], new(idle, true, null), task: signedIn, unreadableRules: Unreadable(damaged, broken));
        var panel = new ProcessControlsViewModel();
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        check(panel.HasDamagedRules && panel.DamagedRules.Select(item => item.RuleId).SequenceEqual([id]) && panel.SelectedDamagedRule?.RuleId == id && panel.CanRemoveDamagedRule,
            "A damaged rule file named by its rule id is offered for removal, and one whose name is not a rule id is not (rule-delete only accepts rule ids)");
        App.Operations.DeletedRules.Clear();
        App.Operations.PolicyWorkerError = new InvalidOperationException("Task Scheduler is unavailable.");
        try { await panel.RemoveDamagedRuleCommand.ExecuteAsync(null); }
        finally { App.Operations.PolicyWorkerError = null; }
        check(panel.Status == "Couldn't remove the damaged rule." && panel.Detail == "Task Scheduler is unavailable." && panel.HasDamagedRules,
            "When the governor sync fails after the delete, the panel says the damaged rule could not be removed and keeps listing it until the state is read again");
        App.Operations.RuleDeleted = _ => App.Operations.Governor = Snapshot(false, [rule], new(idle, true, null), task: signedIn, unreadableRules: Unreadable(broken));
        try { await panel.RemoveDamagedRuleCommand.ExecuteAsync(null); }
        finally { App.Operations.RuleDeleted = null; }
        check(App.Operations.DeletedRules.Count == 2 && App.Operations.DeletedRules.All(deleted => deleted == id) && !panel.HasDamagedRules && panel.DamagedRules.Count == 0 && !panel.CanRemoveDamagedRule && panel.Status == "Damaged rule removed.",
            "Remove damaged rule deletes exactly that rule id through rule-delete, then the refreshed state no longer lists it");
        App.Operations.DeletedRules.Clear();
    }

    private static void Restore(Action<bool, string> check)
    {
        var build = typeof(RestoreLogsViewModel).GetMethod("BuildRestore", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var history = new RestoreLogsViewModel();
        var chrome = Process(100, Chrome);
        var enabled = Rule(RuleId, "Chrome rule", Chrome, true);
        var disabled = Rule(RuleId, "Chrome rule", Chrome, false);
        var signedIn = new GovernorTaskState("task", true, true, true, 0x00041301, true);
        var states = new (string Name, PolicyHostState? State)[]
        {
            ("no state", null), ("stopped", Host("stopped", [])), ("running", Host("running", [])), ("stopped with an active app", Host("stopped", [Instance(chrome, "cpuPriority", "active")])),
            ("running with a stepped-back app", Host("running", [Instance(chrome, "cpuPriority", "conflict", "error", "x")])), ("configurationError", Host("configurationError", [])),
        };
        var workers = (from state in states from running in new bool?[] { null, false, true } from error in new string?[] { null, "error" } select (state, running, error)).ToArray();
        var problems = new (string Name, string? RulesError, string[]? Unreadable, string? Security)[]
        {
            ("clean", null, null, null), ("rules error", "x", null, null), ("unreadable file", null, ["The saved rule 0123456789abcdef0123456789abcdef.json could not be read: x"], null),
            ("unprotected folder", null, null, "inherits"), ("folder missing", null, null, "missing"),
        };
        var recovery = new bool?[] { null, false, true };
        var sessions = new (string Name, GameSessionEntry[] Games)[]
        {
            ("none", []), ("host unknown", [new("s", new ProtectedSessionStatus(null, null, null))]), ("state unreadable", [new("s", new ProtectedSessionStatus(null, false, null))]),
        };
        var windows = new (string Name, TweakRecovery? Value)[] { ("unreadable", null), ("none", new TweakRecovery(null, null, null)) };
        var failures = new Dictionary<string, string>();
        var count = 0;
        void Verify(string kind, string rule, bool condition, Func<string> input) { if (!condition && failures.TryAdd(rule + " | governor row: " + kind, "")) failures[rule + " | governor row: " + kind] = input(); }

        IEnumerable<(string Name, GovernorSnapshot? Snapshot)> Governors()
        {
            yield return ("unreadable snapshot", null);
            foreach (var paused in new[] { false, true })
            foreach (var rules in new[] { Array.Empty<SavedProcessRule>(), [disabled], [enabled] })
            foreach (var problem in problems)
            foreach (var (state, running, error) in workers)
            foreach (var task in new GovernorTaskState?[] { null, signedIn })
            foreach (var exited in new IReadOnlySet<string>?[] { null, new HashSet<string> { ChromeKey } })
            {
                var journals = state.State?.Instances.ToDictionary(instance => instance.JournalPath, instance => Journal(chrome, Owner, ("cpuPriority", Value("High"))), StringComparer.OrdinalIgnoreCase);
                yield return ("paused=" + paused + " rules=" + rules.Length + (rules.Length > 0 ? "/" + rules[0].Enabled : "") + " " + problem.Name + " worker=" + state.Name + "/" + running + "/" + error + " task=" + (task is null ? "none" : "signed in") + " exited=" + (exited is not null),
                    Snapshot(paused, rules, new(state.State, running, error), journals, task, exited, rulesError: problem.RulesError, securityProblem: problem.Security, unreadableRules: problem.Unreadable));
            }
        }

        foreach (var (governorName, snapshot) in Governors())
        foreach (var (windowName, windowValue) in windows)
        foreach (var (sessionName, games) in sessions)
        foreach (var gameRecovery in recovery)
        foreach (var governorRecovery in recovery)
        {
            count++;
            build.Invoke(history, [gameRecovery, governorRecovery, games, windowValue, snapshot]);
            var headline = history.RestoreHeadline;
            var rows = history.RestoreRows.ToArray();
            var governor = rows.Single(row => row.Label == "Governor").Value;
            var nothing = headline == "No Windows or process settings to restore.";
            var worker = snapshot?.Worker;
            var unreadable = windowValue is null || gameRecovery is null || governorRecovery is null || games.Any(game => game.Worker.State is null || game.Worker.HostRunning is null) || snapshot is null
                || worker!.HostRunning is null || worker.HostRunning == true && worker.Error is not null || snapshot.Summary.RulesError is not null || snapshot.Summary.UnreadableRules is { Length: > 0 }
                || snapshot.Summary.SecurityProblem is not (null or "missing") || governor.StartsWith("Not responding", StringComparison.Ordinal) || governor == "Status unavailable" || governor.Contains("could not be read", StringComparison.Ordinal);
            string Input() => governorName + " | windows " + windowName + " | games " + sessionName + " | game " + gameRecovery + " | governor session " + governorRecovery + " => " + headline + " || " + governor;
            Verify(governor.Split(" · ")[0], "Undo headline says there is nothing to restore while a source is unreadable or the governor is not responding", !(nothing && unreadable), Input);
            Verify(governor.Split(" · ")[0], "Undo page shows a safe status while a source is unreadable or the governor is not responding", history.RestoreState != "safe" || !unreadable, Input);
            Verify(governor.Split(" · ")[0], "Undo headline says there is nothing to restore while the governor row counts apps with settings", !(nothing && governor.Any(letter => letter is >= '1' and <= '9')), Input);
            Verify(governor.Split(" · ")[0], "Governor row says its settings are put back while the worker state is unreadable, not answering, or an app still holds a setting",
                governor != "Paused · settings put back" || snapshot is not null && worker!.HostRunning is not null && !(worker.HostRunning == true && worker.Error is not null)
                    && (worker.State?.Instances.All(instance => instance.Status is not ("active" or "applying" or "conflict") || snapshot.Exited?.Contains(GovernorProbe.Key(instance.Process)) == true) ?? true), Input);
            if (snapshot is not null)
            {
                var state = GovernorDisplay.State(snapshot);
                Verify(governor.Split(" · ")[0], "Processes headline says it starts when you sign in without a confirmed task and a verified running worker", GovernorDisplay.Headline(state, snapshot) != SignedIn || state == "running" && snapshot.ScheduledTask is { Restarts: true } && worker!.HostRunning == true && worker.Error is null, Input);
                Verify(governor.Split(" · ")[0], "Processes detail promises a restart by itself without a stopped worker and a confirmed task", !GovernorDisplay.Detail(state, snapshot).Contains("starts again by itself", StringComparison.Ordinal) || state == "stopped" && snapshot.ScheduledTask is { Restarts: true } && worker!.HostRunning == false, Input);
            }
        }
        check(failures.Count == 0, "Undo and Processes fuzz over " + count + " states of the governor, Windows tweaks, game sessions and session backups never contradict themselves" + string.Concat(failures.Select(item => "\n    " + item.Key + "\n      e.g. " + item.Value)));
    }

    private static async Task RealSnapshot(Action<bool, string> check)
    {
        if (!OperatingSystem.IsWindows()) { Console.WriteLine("SKIP Real governor snapshot checks need Windows"); return; }
        var owner = OperationOwner.Current();
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-governor-snapshot-" + Guid.NewGuid().ToString("N"));
        var store = new ProcessPolicyStore(root);
        using var alive = System.Diagnostics.Process.Start(new ProcessStartInfo("cmd.exe", "/c ping -n 60 127.0.0.1 >nul") { CreateNoWindow = true, UseShellExecute = false })!;
        using var gone = System.Diagnostics.Process.Start(new ProcessStartInfo("cmd.exe", "/c exit 0") { CreateNoWindow = true, UseShellExecute = false })!;
        try
        {
            string Created(System.Diagnostics.Process process) => process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture);
            var running = new RunningProcess(alive.Id, Created(alive), @"C:\Windows\System32\cmd.exe");
            var ended = new RunningProcess(gone.Id, Created(gone), @"C:\Windows\System32\cmd.exe");
            gone.WaitForExit();
            var ruleId = Guid.NewGuid().ToString("N");
            var rule = Rule(ruleId, "Real rule", @"C:\Windows\System32\cmd.exe", true, owner) with { RuleId = ruleId, Revision = Guid.NewGuid().ToString("N") };
            OperationFiles.Write(Path.Combine(store.RulesDirectory, ruleId + ".json"), rule);
            PolicyInstance Real(RunningProcess process, string field, string status) => new()
            {
                RuleId = ruleId, RuleHash = "hash", Process = process, PreviewPath = Path.Combine(root, "operations", process.ProcessId + field, "preview.json"), ReviewHash = "review",
                JournalPath = Path.Combine(root, "operations", process.ProcessId + field, "journal.json"), Status = status, Field = field,
            };
            var active = Real(running, "cpuPriority", "active");
            var applying = Real(running, "ioPriority", "applying");
            var expired = Real(ended, "cpuPriority", "active");
            OperationFiles.Write(active.JournalPath, Journal(running, owner, ("cpuPriority", Value("High"))));
            OperationFiles.Write(store.SettingsPath, new GovernorSettings(1, true));
            OperationFiles.Write(store.StatePath, Host("stopped", [active, applying, expired], owner: owner));

            var snapshot = GovernorProbe.Read(root);
            check(snapshot.Worker.HostRunning == false && snapshot.Rules.Length == 1 && snapshot.Journals.ContainsKey(active.JournalPath)
                    && snapshot.Exited!.SetEquals([GovernorProbe.Key(ended)]) && snapshot.Unapplied!.SetEquals([applying.JournalPath]) && snapshot.ScheduledTask is null,
                "Real snapshot: reads rules, state and journals, marks only the exited process, flags the applying record without a journal, and skips the task while paused");
            var (view, _) = await Show(snapshot);
            Expect(check, view, "Real snapshot paused with one live active setting shows Pausing for exactly 1 app",
                "State: pausing", "Detail: 1 app still has rule settings that were not put back. Press Pause governor to put them back.",
                "Rule Real rule: Now: Not applied right now because the governor is paused. | cmd.exe (" + alive.Id + ") · CPU priority still set by this rule");

            File.WriteAllText(store.StatePath, "{ not json");
            snapshot = GovernorProbe.Read(root);
            (view, _) = await Show(snapshot);
            check(snapshot.Worker.HostRunning is null && snapshot.ScheduledTask is null && view.Contains("State: notResponding")
                    && view.Any(line => line.StartsWith("Detail: Paused, but the app couldn't read the governor's state, so it can't confirm the old settings were put back", StringComparison.Ordinal)),
                "Real snapshot: a damaged host.json while paused never says the settings were put back");
            File.Delete(store.SettingsPath);
            snapshot = GovernorProbe.Read(root);
            check(snapshot.Worker.HostRunning is null && snapshot.ScheduledTask is null, "Real snapshot: the scheduled task is not read when the worker state is unknown");

            OperationFiles.Write(store.StatePath, Host("stopped", [], owner: owner));
            snapshot = GovernorProbe.Read(root);
            (view, _) = await Show(snapshot);
            check(snapshot.Worker.HostRunning == false && snapshot.ScheduledTask is { Registered: false } && snapshot.Summary.Secured == false
                    && view.Any(line => line.StartsWith("Detail: The rules folder is not protected: ", StringComparison.Ordinal)),
                "Real snapshot: a stopped worker reads the task, and an unprotected temporary rules folder is reported as not protected");

            File.WriteAllText(Path.Combine(store.RulesDirectory, Guid.NewGuid().ToString("N") + ".json"), "{ not json");
            snapshot = GovernorProbe.Read(root);
            (view, _) = await Show(snapshot);
            check(snapshot.Summary.RulesError is null && snapshot.Summary.UnreadableRules is { Length: 1 } && snapshot.Summary.UnreadableRules[0].Contains(" could not be read: ", StringComparison.Ordinal)
                    && snapshot.Rules.Length == 1 && view.Contains("State: notResponding"),
                "Real snapshot: a damaged rule file is named as unreadable while the readable rule is still listed, and the unprotected folder still needs attention");
        }
        finally
        {
            try { if (!alive.HasExited) alive.Kill(entireProcessTree: true); } catch (Exception) { }
            Directory.Delete(root, true);
        }
    }

    private static void Probe(Action<bool, string> check)
    {
        string Xml(string triggers) => "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>Roo Industries process rules | S-1 | C:\\R</Description></RegistrationInfo><Triggers>" + triggers + "</Triggers></Task>";
        var now = new DateTime(2026, 10, 1, 12, 0, 0, DateTimeKind.Local);
        const string logon = "<LogonTrigger><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><Enabled>true</Enabled></LogonTrigger>";
        string Time(string inner, string start = "2026-10-01T11:00:00") => "<TimeTrigger><StartBoundary>" + start + "</StartBoundary>" + inner + "</TimeTrigger>";
        const string repeat = "<Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>";
        check(GovernorProbe.Description(Xml("")) == @"Roo Industries process rules | S-1 | C:\R", "Task XML: the registration description is read for ownership matching");
        check(GovernorProbe.RepeatsEveryMinute(Xml(logon + Time(repeat + "<Enabled>true</Enabled>")), now), "Task XML: an enabled, started, endless one-minute time trigger counts as a restart");
        check(GovernorProbe.RepeatsEveryMinute(Xml(Time(repeat, "2026-10-01T18:00:00Z")), new DateTime(2026, 10, 2, 0, 0, 0, DateTimeKind.Local)), "Task XML: a UTC start boundary in the past counts");
        foreach (var (xml, label) in new[]
                 {
                     (Xml(logon), "only the logon trigger repeats"),
                     (Xml(Time(repeat + "<Enabled>false</Enabled>")), "the time trigger is disabled"),
                     (Xml(Time("<Repetition><Interval>PT5M</Interval></Repetition>")), "the repeat is five minutes"),
                     (Xml(Time("<Repetition><Interval>PT1M</Interval><Duration>PT1H</Duration></Repetition>")), "the repeat stops after an hour"),
                     (Xml(Time(repeat, "2026-10-01T13:00:00")), "the trigger starts later"),
                     (Xml(Time(repeat + "<EndBoundary>2026-10-01T11:30:00</EndBoundary>")), "the trigger expired"),
                     (Xml(Time("")), "the time trigger has no repeat"),
                     ("not xml", "the XML is unreadable"),
                 })
            check(!GovernorProbe.RepeatsEveryMinute(xml, now), "Task XML: no restart claim when " + label);
        check(GovernorProbe.Suffix("S-1-5-21-1-2-3-1001", OperatingSystem.IsWindows() ? @"C:\Users\Fixture\AppData\Local\RooIndustriesOptimizationSuite\process-rules" : "/fixture/process-rules")
                == (OperatingSystem.IsWindows() ? "0FE4642A9C64D10BCAAC" : "75C733714C2EB0BE18B7"),
            "Task name suffix is the first 20 upper-case hex digits of SHA-256(sid|UPPER(policy root))");

        using var self = System.Diagnostics.Process.GetCurrentProcess();
        var created = self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture);
        using var child = System.Diagnostics.Process.Start(new ProcessStartInfo(OperatingSystem.IsWindows() ? "cmd.exe" : "sleep") { Arguments = OperatingSystem.IsWindows() ? "/c ping -n 2 127.0.0.1 >nul" : "1", CreateNoWindow = true, UseShellExecute = false })!;
        var childCreated = child.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture);
        var childId = child.Id;
        child.WaitForExit();
        var exited = GovernorProbe.ExitedKeys([new RunningProcess(self.Id, created, "self"), new RunningProcess(self.Id, "1", "self"), new RunningProcess(childId, childCreated, "child")]);
        check(exited.SetEquals([self.Id + "|1", childId + "|" + childCreated]),
            "Process list check: the running process is live, a reused process id with another start time and an exited process count as exited");
    }
#endif
}
