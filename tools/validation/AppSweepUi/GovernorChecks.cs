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
        GovernorTaskState? task = null, IReadOnlySet<string>? exited = null, IReadOnlySet<string>? unapplied = null, string? rulesError = null, string? securityProblem = null, string[]? unreadableRules = null)
        => new(new PolicySummary(securityProblem is null, securityProblem, paused, rules.Length, rules.Count(rule => rule.Enabled), rulesError, unreadableRules), worker, rules, journals ?? new(), task, exited, unapplied);

    private static async Task<(string[] View, ProcessControlsViewModel Panel)> Show(GovernorSnapshot snapshot)
    {
        App.Operations.Governor = snapshot;
        var panel = new ProcessControlsViewModel();
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        var history = new RestoreLogsViewModel();
        await history.InitializeAsync();
        var undo = history.RestoreRows.Single(row => row.Label == "Roo Industries Governor");
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
#if !OLD_UI
            await RetryButton(check);
            await RealSnapshot(check);
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
        var view = await View(Snapshot(false, [rule, other], new(running, true, null), journals));
        Expect(check, view, "Running: headline, detail and buttons",
            "State: running", "Headline: Roo Industries Governor is running. It keeps your rules active when this app is closed and starts when you sign in.",
            "Detail: 2 rules are on.", "Buttons: pause=True start=False");
        Expect(check, view, "Per-field mix: the applied field stays visible, only failed fields say unavailable, the stepped-back field says it keeps changing back, a denial is recognised by its recorded kind, not by its wording (an NTSTATUS text without the word denied still says unavailable, and an error text that mentions 'denied' is not treated as a denial)",
            "Rule Chrome rule: Now: chrome.exe (100) · CPU priority High | chrome.exe (100) · I/O priority unavailable · " + Denied
            + " | chrome.exe (100) · GPU priority · This app keeps changing it back, so Roo Industries stepped back. | chrome.exe (100) · Memory priority unavailable · " + Denied
            + " | chrome.exe (100) · Priority boost stepped back · Fixture policy denied this change");
        Expect(check, view, "Other account: a matching process under another Windows account says so instead of 'not running'",
            "Rule Game rule: Now: game.exe (200) · Running under another Windows account, so this rule doesn't control it.");
        Expect(check, view, "Undo page while running counts apps, not per-field records, and history has one row per app",
            "Undo: Running · 1 app changed · pause it in Games > Processes to put settings back (safe)", "History: chrome · Chrome rule · some settings stepped back");

        view = await View(Snapshot(false, [rule], new(Host("running", []), true, null)));
        Expect(check, view, "Running with no matching process says the app is not running", "Rule Chrome rule: Now: The app is not running right now.");

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
            "Detail: Paused, but Roo Industries couldn't read the governor's state, so it can't confirm the old settings were put back: 'n' is an invalid start of a value.",
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
        view = await View(Snapshot(false, [rule], new(Host("running", starting.Instances.ToArray()), true, null), unapplied: unapplied));
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

        var failing = "A governor check failed and will be retried in 4 s: The process cannot access the file because it is being used by another process.";
        view = await View(Snapshot(false, [rule], new(Host("running", [], errors: [failing]), true, null)));
        Expect(check, view, "A running governor whose checks keep failing says so instead of only counting rules", "State: running", "Detail: 1 rule is on. " + failing);
        view = await View(Snapshot(false, [rule], new(Host("running", []), true, null), unreadableRules: ["The saved rule broken.json could not be read: The JSON is incomplete."]));
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
            "State: off", "Detail: 1 app still has a setting Roo Industries could not put back.",
            "Rule Chrome rule: Now: Off | chrome.exe (100) · CPU priority could not be put back · " + Denied, "Undo: Off · 1 app still has saved settings (medium)",
            "History: chrome · Chrome rule · a setting could not be put back");
        view = await View(Snapshot(false, [off], new(null, null, "This operation belongs to another PC or Windows user.")));
        Expect(check, view, "No rules on with an unreadable governor state stays off but does not claim every app got its settings back",
            "State: off", "Detail: Roo Industries couldn't read the governor's last state, so it can't confirm every app got its old settings back: This operation belongs to another PC or Windows user.",
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
    private static async Task RetryButton(Action<bool, string> check)
    {
        var chrome = Process(100, Chrome);
        var off = Rule(RuleId, "Chrome rule", Chrome, false);
        var failed = Host("stoppedWithConflicts", [Instance(chrome, "cpuPriority", "conflict", "denied", "Access is denied.")]);
        var (view, panel) = await Show(Snapshot(false, [off], new(failed, false, null)));
        Expect(check, view, "Off with a failed restore and no worker running offers Put settings back",
            "Detail: 1 app still has a setting Roo Industries could not put back." + Retry, "Undo: Off · 1 app still has saved settings · put them back in Games > Processes (medium)");
        check(panel.RetryAvailable && panel.CanRetryRestore, "The Put settings back button is shown and enabled");
        App.Operations.RetryRestore = () =>
        {
            App.Operations.Governor = Snapshot(false, [off], new(Host("stopped", []), false, null));
            return Task.FromResult(Host("stopped", []));
        };
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == 1 && !panel.RetryAvailable && panel.Status == "The old settings are back." && panel.GovernorDetail == "",
            "Put settings back runs one restore pass and reports the result from fresh governor state");

        App.Operations.Governor = Snapshot(true, [Rule(RuleId, "Chrome rule", Chrome, true)], new(failed, false, null));
        App.Operations.RetryRestore = () => Task.FromResult(failed);
        await panel.RefreshRulesCommand.ExecuteAsync(null);
        await panel.RetryRestoreCommand.ExecuteAsync(null);
        check(App.Operations.RetryCalls == 2 && panel.RetryAvailable && panel.Status == "Some settings still could not be put back."
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
                    && view.Any(line => line.StartsWith("Detail: Paused, but Roo Industries couldn't read the governor's state, so it can't confirm the old settings were put back", StringComparison.Ordinal)),
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
            check(snapshot.Summary.RulesError is not null && snapshot.Rules.Length == 0 && view.Contains("State: notResponding"),
                "Real snapshot: a damaged rule file is reported as unreadable saved rules and the governor needs attention");
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
