using System.Text.Json;
using System.Text.RegularExpressions;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class UndoChangesChecks
{
    private static readonly string[] Jargon =
    [
        "restorable", "Reversible", "restraint", "Restrained", "Status unavailable", "Backed up", "session backup", "recovery state", "needs recovery", "Interrupted change",
        "verification", "readback", "requested controls", "Partially applied", "Recovery required", "needs attention", "value changes", "selected settings", "No active profile",
        "Review profile", "saved profiles", "Saved settings", "stepped back", "kept by the governor", "could not", "process settings", "file-permissions-", "restore-point-",
        "AboveNormal", "BelowNormal", "RealTime", "restartRequired", "notFound", "leftAsSet", "steppedBack", "notPutBack", "awaiting-restart", "0x", "\u2014", "  ",
    ];
    private static readonly string[] UndoColumn = ["Undo in Games", "Undo in Processes", "Undo in Windows tweaks", "Done", "Nothing to undo"];
    private static readonly string Folder = OperatingSystem.IsWindows() ? @"C:\Fixture\" : "/fixture/";

    public static async Task RunAsync(Action<bool, string> check)
    {
        var savedGame = App.Live.GameStatusModel;
        var savedRestraint = App.Live.GovernorStatusModel;
        var savedGovernor = App.Operations.Governor;
        var savedSessions = App.Operations.GameSessions;
        var savedWindows = App.Operations.WindowsRecovery;
        try
        {
            await BusyPcAsync(check);
            await HeadlinesAsync(check);
            Page(check);
        }
        finally
        {
            App.Live.GameStatusModel = savedGame;
            App.Live.GovernorStatusModel = savedRestraint;
            App.Operations.Governor = savedGovernor;
            App.Operations.GameSessions = savedSessions;
            App.Operations.WindowsRecovery = savedWindows;
        }
    }

    private static async Task BusyPcAsync(Action<bool, string> check)
    {
        var tuned = new SessionChangedItem { ProcessId = 10, ProcessName = "cs2", OriginalPriorityClass = "Normal", AppliedPriorityClass = "AboveNormal", RestoredPriorityClass = "Normal" };
        var idle = new SessionChangedItem { ProcessId = 11, ProcessName = "discord", OriginalPriorityClass = "BelowNormal", AppliedPriorityClass = "Idle" };
        App.Live.GameStatusModel = new GameTuneSessionStatus { DryRun = false, Status = "active", Restorable = true, ChangedItems = [tuned, idle], RestoredItems = [tuned] };
        App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus
        {
            DryRun = false, Status = "active", Restorable = true,
            ActiveRestraints = [new ActiveRestraint { ProcessId = 12, ProcessName = "steamwebhelper", RuleId = "fixture" }, new ActiveRestraint { ProcessId = 13, ProcessName = "onedrive", RuleId = "fixture" }],
        };
        var chrome = GovernorChecks.Process(100, Folder + "chrome.exe");
        var obs = GovernorChecks.Process(101, Folder + "obs64.exe");
        var rule = GovernorChecks.Rule("11111111111111111111111111111111", "Chrome rule", Folder + "chrome.exe", true);
        App.Operations.Governor = GovernorChecks.Snapshot(false, [rule],
            new(GovernorChecks.Host("running", [GovernorChecks.Instance(chrome, "cpuPriority", "active"), GovernorChecks.Instance(obs, "cpuPriority", "restored", "leftAsSet")]), true, null),
            new() { [GovernorChecks.Instance(chrome, "cpuPriority", "active").JournalPath] = GovernorChecks.Journal(chrome, GovernorChecks.Owner, ("cpuPriority", JsonSerializer.SerializeToElement("High", OperationFiles.Json))) },
            new GovernorTaskState("task", true, true, true, 0x00041301, true));
        App.Operations.GameSessions =
        [
            Session("on", "active", "applied", "applied", "applied", true),
            Session("done", "stopped", "restored", "cleared", "restored", false),
            Session("relaunch", "stopped", "restored", "cleared", "restartRequired", false, journal: false),
            Session("stuck", "recoveryRequired", "applied", "applied", "applied", false),
            Session("unknown", "active", "applied", "applied", "applied", null),
        ];
        var file = new ControlAddress("file-ownership", "selected:" + Folder + "game.cfg", "owner");
        App.Operations.WindowsRecovery = new TweakRecovery(new TweakState
        {
            SchemaVersion = 1, Context = FakeOptimizerService.WindowsContext, Revision = "fixture-revision", Held = [], CreatedKeys = [], Notices = [],
            Profiles =
            [
                Profile("my-settings", 2),
                Profile("file-permissions-0123456789abcdef", 1) with { Controls = [new ControlClaim("file-owner", "take", Read(file), JsonSerializer.SerializeToElement("admins"))] },
                Profile("restore-point-0123456789abcdef", 1),
            ],
            History =
            [
                History("a", "old-tweaks", 4, null),
                History("b", "my-settings", 3, null),
                History("c", "file-permissions-0123456789abcdef", 0, Read(file)),
                History("d", "restore-point-0123456789abcdef", 1, null),
            ],
        }, null, null);

        var page = new RestoreLogsViewModel();
        await page.InitializeAsync();
        var rows = page.RestoreRows.ToDictionary(row => row.Label, row => row.Value);
        check(page.RestoreHeadline == "You've got changes you can undo. Each row tells you where.", "Undo changes headline says there are changes to undo and that each row says where");
        check(rows["Game priority"] == "Can undo · press Restore in Games > Background apps" && rows["Background limits"] == "Can undo · press Restore in Games > Background apps",
            "Game priority and Background limits rows name the Restore button and the Games tab that undoes them");
        check(rows["Governor"] == "Running · 1 app changed · press Pause governor in Games > Processes to undo · " + ProcessControlEngine.LeftAsSet,
            "The Governor row names the Pause governor button that undoes it");
        check(rows["Windows tweaks"] == "3 profiles to undo" && rows["my-settings"] == "2 settings · undo them in Windows tweaks"
                && rows["File ownership: game.cfg"] == "1 setting · undo it in Windows tweaks" && rows["Restore point limit"] == "1 setting · undo it in Windows tweaks",
            "Windows tweak profiles show the name the user typed, the file whose ownership changed, or the restore point limit, never an internal profile id");
        var sessions = page.RestoreRows.TakeLast(5).Select(row => row.Value).ToArray();
        check(sessions.SequenceEqual(new[]
            {
                "On · press Stop and restore in Games to undo", "Settings put back", "Settings put back · restart the game to clear its launch priorities",
                "Didn't finish putting settings back · press Recover settings in Games", "Couldn't check this session · open Games",
            }), "Each game session row says whether its settings are back and which Games button undoes it\n    got: " + string.Join(" | ", sessions));

        var history = page.HistoryRows.Select(row => (row.Action, row.Target, row.Change, row.RestoreText)).ToArray();
        string Show((string Action, string Target, string Change, string RestoreText) row) => row.Action + " | " + row.Target + " | " + row.Change + " | " + row.RestoreText;
        check(history.All(row => UndoColumn.Contains(row.RestoreText)), "Every history row's Undo column says where to undo it, that it's done, or that there's nothing to undo\n    got: " + string.Join("\n      ", history.Select(Show)));
        check(history.Contains(("Governor", "OBS Studio", ProcessControlEngine.LeftAsSet, "Nothing to undo")) && history.Contains(("Governor", "Google Chrome", "Chrome rule · on for this app", "Undo in Processes")),
            "Governor history names the app and its rule and points to Processes for undo\n    got: " + string.Join("\n      ", history.Select(Show)));
        check(history.Where(row => row.Action == "Game priority").Select(row => (row.Change, row.RestoreText)).SequenceEqual(new[]
            {
                ("CPU priority Normal → Above normal", "Undo in Games"), ("CPU priority Below normal → Idle", "Undo in Games"), ("CPU priority back to Normal", "Done"),
            }), "Game priority history says CPU priority in words and which row is the undo\n    got: " + string.Join("\n      ", history.Select(Show)));
        check(history.Contains(("Background limits", "2 background apps", "Lower priority while your game runs", "Undo in Games")), "Background limits history says how many background apps it lowered and where to undo it");
        check(history.Where(row => row.Action == "Windows tweaks").Select(row => (row.Target, row.Change, row.RestoreText)).SequenceEqual(new[]
            {
                ("Windows", "Restore point limit · 1 change", "Undo in Windows tweaks"), ("Windows", "File ownership: game.cfg · 1 change", "Undo in Windows tweaks"),
                ("Windows", "my-settings · 3 changes", "Undo in Windows tweaks"), ("Windows", "old-tweaks · 4 changes", "Nothing to undo"),
            }), "Windows tweaks history names each profile in words, counts its changes and says whether it can still be undone\n    got: " + string.Join("\n      ", history.Select(Show)));

        var shown = new[] { page.RestoreHeadline }.Concat(page.RestoreRows.SelectMany(row => new[] { row.Label, row.Value }))
            .Concat(page.HistoryRows.SelectMany(row => new[] { row.Time, row.Action, row.Target, row.Change, row.RestoreText })).ToArray();
        Clean(check, shown, "Undo changes rows on a PC with every kind of change");
    }

    private static async Task HeadlinesAsync(Action<bool, string> check)
    {
        App.Live.GameStatusModel = new GameTuneSessionStatus { Status = "notFound", Restorable = false };
        App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus { Status = "notFound", Restorable = false };
        App.Operations.Governor = GovernorChecks.Snapshot(false, [], new(GovernorChecks.Host("stopped", []), false, null));
        App.Operations.GameSessions = [];
        var shown = new List<string>();
        async Task<RestoreLogsViewModel> Read(TweakRecovery? windows)
        {
            App.Operations.WindowsRecovery = windows;
            var page = new RestoreLogsViewModel();
            await page.InitializeAsync();
            shown.Add(page.RestoreHeadline);
            shown.AddRange(page.RestoreRows.SelectMany(row => new[] { row.Label, row.Value }));
            shown.AddRange(page.HistoryRows.SelectMany(row => new[] { row.Time, row.Action, row.Target, row.Change, row.RestoreText }));
            return page;
        }
        string Windows(RestoreLogsViewModel page) => page.RestoreRows.Single(row => row.Label == "Windows tweaks").Value;

        var page = await Read(new TweakRecovery(null, null, null));
        check(page.RestoreHeadline == "Nothing to undo." && page.RestoreRows.All(row => row.Value is "Nothing to undo" or "No rules") && !page.HasHistory,
            "A PC with nothing changed says Nothing to undo on every row");
        page = await Read(null);
        check(page.RestoreHeadline == "Couldn't check everything. Open this page again to retry." && Windows(page) == "Couldn't check",
            "An unreadable Windows tweaks state says it couldn't check and how to retry");
        var plan = Plan("op-1", "my-settings");
        page = await Read(new TweakRecovery(null, new ControlJournal(plan, "review", 1), "hash"));
        check(page.RestoreHeadline == "A Windows change didn't finish. Press Review recovery in Windows tweaks." && Windows(page) == "A change didn't finish · press Review recovery in Windows tweaks",
            "A Windows change cut off part way names the Review recovery button in Windows tweaks");
        var state = new TweakState
        {
            SchemaVersion = 1, Context = FakeOptimizerService.WindowsContext, Revision = "fixture-revision", Held = [], CreatedKeys = [], Notices = [], Profiles = [Profile("my-settings", 1)],
            History = [History("op-1", "my-settings", 1, null)],
        };
        page = await Read(new TweakRecovery(state, new ControlJournal(plan, "review", 1, "awaiting-restart"), "hash"));
        check(page.RestoreHeadline == "Restart your PC to finish a Windows feature change." && Windows(page) == "Restart your PC to finish",
            "A Windows feature change waiting for a restart says to restart the PC");
        Clean(check, shown.ToArray(), "Undo changes headlines and rows for nothing changed, unreadable, cut off and restart states");
    }

    private static void Page(Action<bool, string> check)
    {
        var views = Views();
        if (views is null) { check(false, "Undo changes page source is next to the checks"); return; }
        var xaml = File.ReadAllText(Path.Combine(views, "RestoreLogsPage.xaml"));
        var code = File.ReadAllText(Path.Combine(views, "RestoreLogsPage.xaml.cs"));
        check(!Regex.IsMatch(xaml + code, @"ContentDialog|CheckBox|MessageBox|Are you sure|I understand", RegexOptions.IgnoreCase),
            "Undo changes has no are-you-sure checkbox or dialog: its buttons only open the page that undoes a change");
        var texts = Regex.Matches(xaml, @"\b(?:Text|Content|Header|PlaceholderText|ToolTipService\.ToolTip)=""([^""{][^""]*)""").Select(match => match.Groups[1].Value).ToArray();
        check(new[] { "Undo changes", "Checking what you can undo", "What you can undo", "Open Games", "Open Windows tweaks", "Open BIOS backups", "Changed by", "Undo" }.All(texts.Contains),
            "Undo changes page labels use plain words\n    got: " + string.Join(" | ", texts));
        Clean(check, texts, "Undo changes page labels");
    }

    private static void Clean(Action<bool, string> check, string[] shown, string where)
    {
        var hits = shown.SelectMany(text => Jargon.Where(word => text.Contains(word, StringComparison.Ordinal)).Select(word => "'" + word + "' in: " + text)).Distinct().ToArray();
        check(hits.Length == 0, where + " show no internal ids, enum names, hex or developer wording" + string.Concat(hits.Select(hit => "\n    " + hit)));
    }

    private static string? Views()
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            var views = Path.Combine(folder.FullName, "docs", "internal", "frontend", "RooIndustries.OptimizationSuite.App", "Views");
            if (File.Exists(Path.Combine(views, "RestoreLogsPage.xaml"))) return views;
        }
        return null;
    }

    private static GameSessionEntry Session(string name, string status, string registry, string job, string field, bool? hostRunning, bool journal = true)
    {
        var game = new RunningProcess(200, "133000000000000200", Folder + name + ".exe");
        return new(Folder + name, new ProtectedSessionStatus(new ProtectedSessionState
        {
            SchemaVersion = 1, PreviewPath = Folder + name + "-preview.json", ReviewHash = "review", Host = new RunningProcess(4242, "133000000000004242", Folder + "Optimizer.Host.exe"),
            Status = status, RegistryStatus = registry, JobStatus = job,
            Preview = new ProtectedSessionPreview
            {
                SchemaVersion = 1, OperationId = name, Owner = GovernorChecks.Owner, Launcher = game, LauncherHash = "", GamePath = game.ExecutablePath, GameHash = "", GameLength = 0,
                GameModifiedAtUtc = DateTime.UtcNow, TopologyHash = "", OriginalAffinity = new AffinityState(0, "0xF"), Controls = new() { ["gpuPriority"] = JsonSerializer.SerializeToElement(3) },
                OriginalLaunchSettings = new LaunchPrioritySnapshot { ImageKeyExisted = false, OptionsKeyExisted = false, Values = new() }, LauncherChanges = null, AcceptLauncherScope = true,
            },
            DesiredAffinity = new AffinityState(0, "0xF"), LauncherJournal = null, Errors = [], UpdatedAtUtc = DateTime.UtcNow,
            Games = [new ProtectedGameState { Identity = game, Fields = [new ProtectedFieldState { Name = "gpuPriority", Route = "native", Status = field, JournalPath = journal ? Folder + name + "-journal.json" : null }] }],
        }, hostRunning, null));
    }

    private static TweakControlRead Read(ControlAddress address) => new(address, "identity", "binding", JsonSerializer.SerializeToElement("user"));

    private static TweakProfile Profile(string id, int selections)
        => new(id, "catalog", Enumerable.Range(0, selections).Select(index => new TweakSelection("setting-" + index, "option")).ToArray(), []);

    private static TweakHistory History(string operation, string profile, int changes, TweakControlRead? control)
        => new(operation, "review", profile, DateTime.UtcNow, Enumerable.Range(0, changes).Select(_ => new TweakMutation(null!, null)).ToArray(),
            control is null ? null : [new ControlMutation(control, JsonSerializer.SerializeToElement("admins"))]);

    private static TweakPlan Plan(string operation, string profile) => new()
    {
        SchemaVersion = 1, OperationId = operation, CreatedAtUtc = DateTime.UtcNow, Context = FakeOptimizerService.WindowsContext, CatalogHash = "catalog", BeforeRevision = null, AfterRevision = "after",
        ProfileId = profile, Selections = [], Expected = [], Changes = [], Profiles = [], Held = [],
    };
}
