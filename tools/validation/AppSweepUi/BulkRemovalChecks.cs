using System.Text.Json;
using System.Text.RegularExpressions;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class BulkRemovalChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        App.Live.InstalledApps = new InstalledAppInventory
        {
            Apps = [new() { AppId = "registry:editor", DisplayName = "Roo Industries Fixture Editor", SourceType = "registry" }, new() { AppId = "registry:player", DisplayName = "Roo Industries Fixture Player", SourceType = "registry" }],
            Complete = true,
        };
        App.Live.LastError = null;
        BulkRemovalJournal Journal(string status, params (string AppId, string State, bool Absent)[] entries) => new()
        {
            Status = status,
            Plan = new() { QueueId = "queue-" + status, Entries = entries.Select(entry => new BulkRemovalEntry { EntryId = entry.AppId, AppId = entry.AppId, DisplayName = entry.AppId == "registry:editor" ? "Roo Industries Fixture Editor" : "Roo Industries Fixture Player" }).ToList() },
            Entries = entries.Select(entry => new BulkRemovalEntryState { AppId = entry.AppId, State = entry.State, RegistrationAbsent = entry.Absent }).ToList(),
        };
        BulkRemovalSession Session(BulkRemovalJournal journal) => new(new(journal.Plan, "preview.json", "hash", journal.Status + "-journal.json"), journal);
        async Task<BulkRemovalViewModel> Start()
        {
            var model = new BulkRemovalViewModel();
            await model.InitializeAsync();
            return model;
        }
        var failed = Journal("needs-reconciliation", ("registry:editor", "needs-reconciliation", false), ("registry:player", "pending", false));
        App.Operations.LastRemoval = Session(failed); App.Operations.RemovalHistory = [(failed.Status + "-journal.json", failed)];
        App.Operations.ReconcileRemoval = _ => Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = failed.Status, Data = failed });
        var model = await Start();
        check(!model.CanSelect && model.CanReconcile && model.CanStartOver && model.Status == "Removal needs checking.", "A failed removal list reloaded at startup offers Start over next to Check again");
        await model.ReconcileCommand.ExecuteAsync(null);
        check(!model.CanSelect && model.CanStartOver, "When Check again cannot resolve a failed removal, Start over still gives a way out");
        model = await Start();
        check(model.CanStartOver && App.Operations.Dismissed.Count == 0, "Reopening the app never clears a failed list without the user choosing Start over");

        App.Operations.DismissRemoval = _ => throw new InvalidOperationException("This removal is still running. Let it finish, then start over.");
        await model.StartOverCommand.ExecuteAsync(null);
        check(!model.CanSelect && model.CanStartOver && model.ReviewRows.Count == 2 && model.Status == "Couldn't clear this list yet." && model.Detail == "An uninstaller may still be running, or Windows needs a restart. Let it finish or restart, then try again.",
            "A list that is genuinely still running stays in place and says what to do without the backend error");

        var release = new TaskCompletionSource<OptimizerResult<BulkRemovalJournal>>();
        App.Operations.DismissRemoval = _ => release.Task;
        var pending = model.StartOverCommand.ExecuteAsync(null);
        check(model.Busy && !model.CanStartOver && !model.CanSelect, "Start over cannot be pressed again while it is working");
        await model.StartOverCommand.ExecuteAsync(null);
        check(App.Operations.Dismissed.Count == 2, "A second press during Start over sends nothing");
        App.Operations.LastRemoval = null;
        release.SetResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = failed });
        await pending;
        check(model.CanSelect && !model.CanStartOver && !model.CanReconcile && model.ReviewRows.Count == 0 && model.Apps.Count == 2 && model.ApplyLabel == "Remove selected apps" && model.Status == "Pick the apps to remove.",
            "Start over unlocks the app list, clears the failed list and shows every installed app again");
        model.SetSelection([model.Apps[0]]);
        check(model.CanPreview && model.SelectionSummary == "1 selected", "After starting over, the failed app can be picked again to retry");
        model = await Start();
        check(model.CanSelect && !model.CanStartOver && model.ReviewRows.Count == 0, "A cleared list does not come back after reopening the app");

        var partial = Journal("needs-reconciliation", ("registry:editor", "removed", true), ("registry:player", "needs-reconciliation", false));
        App.Operations.LastRemoval = Session(partial); App.Operations.RemovalHistory = [(partial.Status + "-journal.json", partial)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = partial }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.HasRemovedApps && model.RemovedApps.Single().Id == "registry:editor", "Starting over a partly finished list keeps the finished app ready for leftover review");
        check(!model.Detail.Contains("can't tell", StringComparison.Ordinal), "Starting over a list with no interrupted launch shows no launch warning");

        var interrupted = Journal("running", ("registry:editor", "dispatching", false), ("registry:player", "pending", false));
        App.Operations.LastRemoval = Session(interrupted); App.Operations.RemovalHistory = [(interrupted.Status + "-journal.json", interrupted)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = interrupted }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.Detail.Contains("can't tell whether it ran", StringComparison.Ordinal), "Starting over a list interrupted while a remover was starting warns that the launch could not be verified");

        var rechecked = Journal("needs-reconciliation", ("registry:editor", "needs-reconciliation", false), ("registry:player", "pending", false));
        rechecked.Entries[0].LaunchUnconfirmed = true;
        App.Operations.LastRemoval = Session(rechecked); App.Operations.RemovalHistory = [(rechecked.Status + "-journal.json", rechecked)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = rechecked }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.Detail.Contains("can't tell whether it ran", StringComparison.Ordinal), "The unconfirmed-launch warning survives Check again before Start over");

        foreach (var status in new[] { "running", "canceled", "ready", "reboot-required" })
        {
            App.Operations.LastRemoval = Session(Journal(status, ("registry:editor", status == "running" ? "running" : "pending", false)));
            model = await Start();
            check(!model.CanSelect && model.CanStartOver, "A saved " + status + " list offers Start over and lets the backend decide whether it is safe");
        }
        App.Operations.LastRemoval = Session(Journal("cleanup-review-required", ("registry:editor", "removed", true)));
        model = await Start();
        check(model.CanSelect && !model.CanStartOver, "A finished list keeps the app list usable without an extra Start over step");
        App.Operations.LastRemoval = null; App.Operations.RemovalHistory = [];
        await PlainWordsAsync(check);
        App.Operations.LastRemoval = null; App.Operations.RemovalHistory = [];
    }

    static readonly string[] Raw =
    [
        "registryKey", "registryValue", "Registry32", "Registry64", "scheduledTask", "already-absent", "needs-reconciliation", "needsReconciliation", "installer-busy",
        "failed-before-start", "reboot-required", "restart-initiated", "dispatching", "subtree", "package-family", "selected product", "Excluded ", "Ownership could not",
        "registration", "route", "manifest", "rollback", "runner", "engine", "executor", "gate", "remover", "this path", "S-1-5-", "S-1-12-", "Exception", ".ps1",
        "Unexpected ", "Controlled ", "RegOpenKeyEx", "Access is denied", "I reviewed", "I accept", "I understand", "apply",
    ];

    public static string? Jargon(string? text) => text is null ? null : Raw.FirstOrDefault(token => text.Contains(token, StringComparison.OrdinalIgnoreCase));

    static string? Shown(BulkRemovalViewModel model)
    {
        IEnumerable<(string Name, string? Text)> shown = typeof(BulkRemovalViewModel).GetProperties().Where(property => property.PropertyType == typeof(string) && property.Name != nameof(BulkRemovalViewModel.SearchText))
            .Select(property => (property.Name, property.GetValue(model) as string));
        shown = shown.Concat(model.ReviewRows.SelectMany(row => new (string, string?)[] { ("row state", row.State), ("row name", row.Entry.ReviewLabel) }))
            .Concat(model.Leftovers.Select(item => ("leftover", (string?)item.Evidence)))
            .Concat(model.Apps.Select(app => ("app", (string?)app.SelectionLabel)));
        return shown.Where(item => Jargon(item.Text) is not null).Select(item => item.Name + " shows '" + Jargon(item.Text) + "': " + item.Text).FirstOrDefault();
    }

    static async Task PlainWordsAsync(Action<bool, string> check)
    {
        var logged = new List<string>();
        var observer = AppLog.Observer;
        var reconcile = App.Operations.ReconcileRemoval;
        AppLog.Observer = (_, detail) => { if (detail is not null) lock (logged) logged.Add(detail); };
        try
        {
            const string raw = "Exception calling \"Start\" with \"0\" argument(s): Access is denied at C:\\Fixture\\uninstall.exe";
            var states = new[] { "pending", "dispatching", "running", "removed", "already-absent", "reboot-required", "restart-initiated", "needs-reconciliation", "installer-busy", "canceled", "failed-before-start", "failed" };
            var journal = new BulkRemovalJournal
            {
                Status = "needs-reconciliation",
                Plan = new() { QueueId = "queue-words", Entries = states.Select((state, index) => new BulkRemovalEntry { EntryId = state, AppId = "registry:" + state, DisplayName = "Roo Industries Fixture " + (index + 1) }).ToList() },
                Entries = states.Select(state => new BulkRemovalEntryState { AppId = "registry:" + state, State = state, Error = state == "failed" ? raw : null }).ToList(),
            };
            App.Operations.LastRemoval = new(new(journal.Plan, "preview.json", "hash", "words-journal.json"), journal);
            App.Operations.RemovalHistory = [];
            var model = new BulkRemovalViewModel();
            await model.InitializeAsync();
            check(model.ReviewRows.Count == states.Length && Shown(model) is null
                && model.ReviewRows.Single(row => row.Entry.AppId == "registry:failed").State == "Couldn't remove it. Try again, or uninstall it from Windows Settings."
                && logged.Any(line => line.Contains(raw, StringComparison.Ordinal)),
                "Every removal row reads as plain words, and an uninstaller's raw error goes to the app log instead of the row: " + (Shown(model) ?? string.Join(" | ", model.ReviewRows.Select(row => row.State))));

            App.Operations.ReconcileRemoval = _ => throw new InvalidOperationException(raw);
            await model.ReconcileCommand.ExecuteAsync(null);
            check(model.Status == "Couldn't check the list." && model.Detail == "Press Check again in a moment." && Shown(model) is null,
                "A failed Check again says what to do instead of showing the backend error: " + model.Status + " / " + model.Detail);

            var removed = new RemovedAppChoice("registry:editor", "Roo Industries Fixture Editor", "words-journal.json");
            var doubtful = new LeftoverChoice(new LeftoverCandidate
            {
                ItemId = "doubtful", Kind = "registryKey", Target = @"CurrentUser\Software\Roo Industries Fixture", Exists = true,
                Registry = new RegistryAddress("CurrentUser", "Registry32", @"Software\Roo Industries Fixture", "key", null),
                Evidence = ["Published installation location", "Exact package-family data directory", "Directory name matches the selected product", "Key name matches the selected product; review its subtree ownership",
                    "Value references the selected installation path", "Ownership could not be checked for installed app: Roo Industries Fixture Player", @"Excluded path: C:\Windows", "A reason the app has no words for yet"],
                SharedOwners = ["Windows"], Protected = true, UserData = false, OwnershipComplete = false, Error = "RegOpenKeyEx failed with registry status 5: Access is denied.",
            }, removed);
            check(Jargon(doubtful.Evidence) is null && !doubtful.Evidence.Contains("no words", StringComparison.Ordinal) && doubtful.Evidence.Contains("Registry key", StringComparison.Ordinal) && !doubtful.CanSelect,
                "A leftover says what it is and why it matches in plain words: " + doubtful.Evidence);

            App.Operations.LastRemoval = null;
            model = new BulkRemovalViewModel();
            await model.InitializeAsync();
            model.SetSelection([model.Apps[0]]);
            await model.PreviewCommand.ExecuteAsync(null);
            check(model.Status == "Couldn't get the removal ready." && model.Detail == "Press Preview removal to try again." && logged.Any(line => line.Contains("Unexpected removal preview call.", StringComparison.Ordinal)),
                "A removal preview that fails says what to do and keeps the reason in the app log: " + model.Status + " / " + model.Detail);

            model.RemovedApps.Add(removed);
            model.SelectedRemovedApp = removed;
            await model.ScanFilesCommand.ExecuteAsync(null);
            check(model.FileStatus == "Couldn't finish looking for leftovers." && model.FileSummary == "Press Find leftovers to try again." && logged.Any(line => line.Contains("Unexpected leftover scan.", StringComparison.Ordinal)),
                "A leftover scan that fails says what to do and keeps the reason in the app log: " + model.FileStatus + " / " + model.FileSummary);

            model.Leftovers.Add(new LeftoverChoice(new LeftoverCandidate
            {
                ItemId = "key", Kind = "registryKey", Target = @"CurrentUser\Software\Roo Industries Fixture", Exists = true,
                Registry = new RegistryAddress("CurrentUser", "Registry64", @"Software\Roo Industries Fixture", "key", null),
                Evidence = ["Key name matches the selected product; review its subtree ownership"], SharedOwners = [], Protected = false, UserData = false,
            }, removed) { Selected = true });
            check(model.HasSelectedKeys && model.CanPreviewFiles, "A picked registry key can be previewed without an extra acceptance box");
            await model.PreviewFilesCommand.ExecuteAsync(null);
            check(model.FileStatus == "Couldn't get the cleanup ready." && Shown(model) is null && logged.Any(line => line.Contains("Unexpected cleanup preview.", StringComparison.Ordinal)),
                "A cleanup preview that fails says what to do and keeps the reason in the app log: " + model.FileStatus + " / " + model.FileSummary);
            model.FileReviewReady = true;
            check(model.CanApplyFiles && typeof(BulkRemovalViewModel).GetProperties().All(property => property.Name is not ("FilesReviewed" or "AcceptKeyRecreation")),
                "A previewed leftover cleanup, which is backed up and can be restored, deletes without an extra review box");

            var repo = new DirectoryInfo(AppContext.BaseDirectory);
            while (!File.Exists(Path.Combine(repo.FullName, "AGENTS.md"))) repo = repo.Parent ?? throw new DirectoryNotFoundException("Repository root not found from " + AppContext.BaseDirectory);
            var views = Path.Combine(repo.FullName, "docs", "internal", "frontend", "RooIndustries.OptimizationSuite.App", "Views");
            var panel = File.ReadAllText(Path.Combine(views, "BulkRemovalPanel.xaml"));
            var panelCode = File.ReadAllText(Path.Combine(views, "BulkRemovalPanel.xaml.cs"));
            var page = File.ReadAllText(Path.Combine(views, "UninstallCleanupPage.xaml"));
            static int Count(string text, string token) => text.Split(token).Length - 1;
            check(Count(panelCode, "new ContentDialog") == 1 && panelCode.Contains("Removing apps can't be undone.", StringComparison.Ordinal) && !panelCode.Contains("Start over?", StringComparison.Ordinal)
                && panel.Contains("Command=\"{x:Bind ViewModel.StartOverCommand}\"", StringComparison.Ordinal),
                "Only app removal, which can't be undone, asks before it runs; Start over changes nothing on the PC and runs straight away");
            check(!panel.Contains("RemovedFilesApproval", StringComparison.Ordinal) && !panel.Contains("RegistryRecreationReview", StringComparison.Ordinal)
                && Count(page, "<CheckBox") == 1 && page.Contains("ViewModel.RemovalApproved", StringComparison.Ordinal)
                && Regex.IsMatch(panel, "AutomationId=\"RegistryRestoreNote\"") && panel.Contains("audit settings and last-changed time aren't saved", StringComparison.Ordinal)
                && panel.Contains("comes back as a normal key", StringComparison.Ordinal),
                "Leftover deletion has no review boxes but still says what Restore can't bring back for registry keys, and the Leftover cleanup tab asks once before it runs an uninstaller");
            var labels = Regex.Matches(panel + page, "(?:Text|Content|Header|PlaceholderText|AutomationProperties\\.Name)=\"([^\"{][^\"]*)\"").Select(match => match.Groups[1].Value).ToArray();
            var jargon = labels.FirstOrDefault(label => Jargon(label) is not null);
            check(labels.Length > 40 && jargon is null, "Remove apps labels use plain words: " + (jargon ?? labels.Length + " labels"));

            var other = JsonDocument.Parse("{\"kind\":\"appx\",\"scope\":\"registered-user\",\"userSid\":\"S-1-5-21-1000-2000-3000-1001\"}").RootElement;
            var storeApp = new InstalledApp { AppId = "appx:fixture", DisplayName = "Roo Industries Fixture Store App", SourceType = "appx", SourceIdentity = other };
            var storeEntry = new BulkRemovalEntry { AppId = "appx:fixture", DisplayName = "Roo Industries Fixture Store App", Identity = other };
            check(Jargon(storeApp.SelectionLabel) is null && storeApp.SelectionLabel.EndsWith("account", StringComparison.Ordinal)
                && Jargon(storeEntry.ReviewLabel) is null && storeEntry.ReviewLabel.EndsWith("account", StringComparison.Ordinal),
                "Another Windows account's Store app names the account instead of its security ID: " + storeApp.SelectionLabel + " / " + storeEntry.ReviewLabel);
        }
        finally { AppLog.Observer = observer; App.Operations.ReconcileRemoval = reconcile; }
    }
}
