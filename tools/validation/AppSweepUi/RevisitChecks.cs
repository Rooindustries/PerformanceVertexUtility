using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

static class RevisitChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        var failures = new List<string>();
        async Task Scenario(string name, Func<Task<bool>> body)
        {
            bool passed;
            try { passed = await body(); }
            catch (Exception error) { passed = false; name += " (" + error.GetType().Name + ": " + error.Message + ")"; }
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        static void AsForeign(Action action)
        {
            var thread = new Thread(() => action());
            using (ExecutionContext.SuppressFlow()) thread.Start();
            thread.Join();
        }
        static ProcessClassification Background(int count) => new()
        {
            Processes = Enumerable.Range(1, count).Select(index => new ProcessItem { Pid = 100 + index, Name = "fixture-background-" + index, Category = "backgroundApp", WorkingSetBytes = 1024 * index }).ToList(),
        };

        await Scenario("A visible page loaded before a change shows the new data when the change finishes", async () =>
        {
            App.Live.LastError = null;
            App.Live.Classification = Background(2);
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            var before = startup.BackgroundCount;
            App.Live.Classification = Background(5);
            using (DataGeneration.BeginChange()) { }
            await startup.RevalidateAsync();
            return before == 2 && startup.BackgroundCount == 5 && startup.IsReady;
        });

        await Scenario("Revisiting Remove apps while a removal is running keeps the page content and the selected app", async () =>
        {
            App.Live.LastError = null;
            App.Live.InstalledApps = new InstalledAppInventory
            {
                Apps = [new() { AppId = "registry:editor", DisplayName = "Roo Industries Fixture Editor", SourceType = "registry" }, new() { AppId = "registry:player", DisplayName = "Roo Industries Fixture Player", SourceType = "registry" }],
                Complete = true,
            };
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            var selected = cleanup.Apps.First();
            cleanup.SelectedApp = selected;
            var hidden = false;
            cleanup.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(cleanup.IsReady) && !cleanup.IsReady) hidden = true; };
            using (DataGeneration.BeginChange())
            {
                await cleanup.InitializeAsync();
            }
            await cleanup.RevalidateAsync();
            return !hidden && ReferenceEquals(cleanup.SelectedApp, selected) && cleanup.IsReady;
        });

        await Scenario("A revisit keeps the result of the last NVIDIA action instead of resetting it", async () =>
        {
            App.Live.LastError = null; App.Live.OperationError = null;
            App.Live.DriverHardware = new DriverHardwareSummary
            {
                Machine = new() { Manufacturer = "Fixture", Model = "PC", OsCaption = "Windows" },
                Gpus = [new() { Name = "NVIDIA Fixture GPU", DriverVersion = "1.0", DriverDate = "2026-01-01" }],
            };
            App.Data.NvidiaProfiles = new NvidiaProfileCatalog { Entries = [new() { ProfileId = "base-profile", Name = "Frame sync" }] };
            var drivers = new DriversProfilesViewModel();
            await drivers.InitializeAsync();
            App.Live.NvidiaProbeText = "{}";
            await drivers.CheckNvidiaToolCommand.ExecuteAsync(null);
            var after = drivers.NvidiaActionTitle;
            await drivers.InitializeAsync();
            return after == "Tool check finished" && drivers.NvidiaActionTitle == "Tool check finished";
        });

        static InstalledAppInventory Apps(params string[] names) => new() { Apps = names.Select(name => new InstalledApp { AppId = "registry:" + name, DisplayName = "Roo Industries Fixture " + name, SourceType = "registry" }).ToList(), Complete = true };

        await Scenario("Picking an app while a refresh after a change is running keeps the page stale and says so", async () =>
        {
            App.Live.LastError = null; App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            using (DataGeneration.BeginChange()) { }
            App.Live.InstalledApps = Apps("Editor");
            var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            App.Live.BeforeInstalledApps = () => { App.Live.BeforeInstalledApps = null; return hold.Task; };
            var revisit = cleanup.RevalidateAsync();
            cleanup.SelectedApp = cleanup.Apps.First();
            hold.SetResult(); await revisit;
            return cleanup.StaleNotice.Length > 0 && cleanup.Apps.Count == 2;
        });

        await Scenario("Clearing the picked app after the notice loads the current list and clears the notice", async () =>
        {
            App.Live.LastError = null; App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            cleanup.SelectedApp = cleanup.Apps.First();
            using (DataGeneration.BeginChange()) { }
            App.Live.InstalledApps = Apps("Editor");
            await cleanup.RevalidateAsync();
            var noticed = cleanup.StaleNotice.Length > 0;
            cleanup.SelectedApp = null;
            for (var i = 0; i < 50 && cleanup.Apps.Count != 1; i++) await Task.Delay(20);
            return noticed && cleanup.Apps.Count == 1 && cleanup.StaleNotice.Length == 0;
        });

        await Scenario("A change made by the page's own cleanup step does not show the changed-elsewhere notice", async () =>
        {
            App.Live.LastError = null; App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            cleanup.SelectedApp = cleanup.Apps.First();
            cleanup.ScanBusy = true;
            using (DataGeneration.BeginChange()) { }
            await cleanup.RevalidateAsync();
            cleanup.ScanBusy = false;
            await cleanup.RevalidateAsync();
            return cleanup.StaleNotice.Length == 0;
        });

        await Scenario("A change by someone else during the page's own cleanup step still shows the changed-elsewhere notice", async () =>
        {
            App.Live.LastError = null; App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            cleanup.SelectedApp = cleanup.Apps.First();
            cleanup.ScanBusy = true;
            using (DataGeneration.BeginChange()) { }
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            cleanup.ScanBusy = false;
            await cleanup.RevalidateAsync();
            return cleanup.StaleNotice.Length > 0;
        });

        await Scenario("Returning to a page after a change hides the old list until the current one is read", async () =>
        {
            App.Live.LastError = null; App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            using (DataGeneration.BeginChange()) { }
            App.Live.InstalledApps = Apps("Editor");
            var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            App.Live.BeforeInstalledApps = () => { App.Live.BeforeInstalledApps = null; return hold.Task; };
            var revisit = cleanup.InitializeAsync();
            var hidden = cleanup.IsLoading && !cleanup.IsReady;
            hold.SetResult(); await revisit;
            return hidden && cleanup.IsReady && cleanup.Apps.Count == 1;
        });

        await Scenario("A change elsewhere after an NVIDIA action lets the next load show the current state again", async () =>
        {
            App.Live.LastError = null; App.Live.OperationError = null;
            var drivers = new DriversProfilesViewModel();
            await drivers.InitializeAsync();
            App.Live.NvidiaProbeText = "{}";
            await drivers.CheckNvidiaToolCommand.ExecuteAsync(null);
            var after = drivers.NvidiaActionTitle;
            using (DataGeneration.BeginChange()) { }
            await drivers.InitializeAsync();
            return after == "Tool check finished" && drivers.NvidiaActionTitle.EndsWith("is ready to review", StringComparison.Ordinal);
        });

        check(failures.Count == 0, "Revisit freshness checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
