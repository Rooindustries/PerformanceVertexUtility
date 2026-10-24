using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

static class RevisitChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        var failures = new List<string>();
        var only = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_SCENARIO");
        async Task Scenario(string name, Func<Task<bool>> body)
        {
            if (!string.IsNullOrEmpty(only) && !name.Contains(only, StringComparison.OrdinalIgnoreCase)) return;
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
        static IEnumerable<string[]> Merges(string[] first, string[] second)
        {
            if (first.Length == 0) { yield return second; yield break; }
            if (second.Length == 0) { yield return first; yield break; }
            foreach (var rest in Merges(first[1..], second)) yield return [first[0], .. rest];
            foreach (var rest in Merges(first, second[1..])) yield return [second[0], .. rest];
        }
        static async Task Until(Func<bool> condition) { for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(20); }
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
            App.Data.NvidiaProfiles = new NvidiaProfileCatalog { Entries = [new() { ProfileId = "framesync", Name = "Frame sync" }] };
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

        async Task<bool> GraphicsDrivers(DriverHardwareSummary? hardware, Func<DriversProfilesViewModel, bool> shows, bool unreadableProfiles = false)
        {
            var (savedHardware, savedProfiles) = (App.Live.DriverHardware, App.Data.NvidiaProfiles);
            try
            {
                App.Live.LastError = null; App.Live.OperationError = null; App.Live.DriverHardware = hardware;
                if (unreadableProfiles) App.Data.NvidiaProfiles = null!;
                var drivers = new DriversProfilesViewModel();
                await drivers.InitializeAsync();
                return shows(drivers);
            }
            finally { (App.Live.DriverHardware, App.Data.NvidiaProfiles) = (savedHardware, savedProfiles); }
        }
        static string Released(int year, int month, int day) => new DateTime(year, month, day).ToString("d MMM yyyy", System.Globalization.CultureInfo.CurrentCulture);

        await Scenario("Graphics drivers shows the NVIDIA driver number gamers know and leaves out placeholder and Windows names", () => GraphicsDrivers(new DriverHardwareSummary
        {
            Machine = new() { Manufacturer = "To Be Filled By O.E.M.", Model = "To Be Filled By O.E.M.", OsCaption = "Microsoft Windows 11 Pro" },
            Cpu = new() { Name = "AMD Ryzen(TM) 9 9950X3D 16-Core Processor", Cores = 16, LogicalProcessors = 32 },
            Gpus = [new() { Name = "NVIDIA GeForce RTX 5090", Vendor = "NVIDIA", DriverVersion = "32.0.15.6094", DriverDate = "2024-09-12" }],
            NetworkAdapters = [new() { Name = "Intel(R) Wi-Fi 6E AX211 160MHz", Protected = true, Reason = "Network adapters and VPN interfaces require manual review by default" }],
        }, drivers => drivers.IsReady && drivers.MachineModel == "Custom-built PC" && drivers.MachineOsCaption == "Windows 11 Pro"
            && drivers.CpuName == "AMD Ryzen 9 9950X3D 16-Core Processor" && drivers.CpuCoreSummary == "16 cores, 32 threads"
            && drivers.PrimaryGpuDriverSummary == "Driver 560.94 · " + Released(2024, 9, 12)
            && drivers.DriverDownloadHint == "Open Tools and pick NVIDIA App & Driver."
            && drivers.NetworkAdapters.Single().Name == "Intel Wi-Fi 6E AX211 160MHz"));

        await Scenario("Graphics drivers picks the AMD card over onboard Intel graphics, keeps its driver number, drops an unreadable date and a placeholder model, and points to AMD's installer", () => GraphicsDrivers(new DriverHardwareSummary
        {
            Machine = new() { Manufacturer = "ASUS", Model = "System Product Name", OsCaption = "Microsoft Windows 10 Home" },
            Cpu = new() { Name = "Intel(R) Core(TM) i7-14700K", Cores = 20, LogicalProcessors = 28 },
            Gpus = [new() { Name = "Intel(R) UHD Graphics 770", Vendor = "Intel Corporation", DriverVersion = "31.0.101.5186", DriverDate = "2024-01-10" },
                    new() { Name = "AMD Radeon RX 9070 XT", Vendor = "Advanced Micro Devices, Inc.", DriverVersion = "32.0.21013.1000", DriverDate = "20250312000000.000000-000" }],
        }, drivers => drivers.IsReady && drivers.MachineModel == "ASUS" && drivers.MachineOsCaption == "Windows 10 Home"
            && drivers.PrimaryGpuName == "AMD Radeon RX 9070 XT"
            && drivers.PrimaryGpuDriverSummary == "Driver 32.0.21013.1000"
            && drivers.DriverDownloadHint == "Open Tools and pick AMD Software: Adrenalin Edition."));

        await Scenario("Graphics drivers says what to do when the hardware read comes back empty", () => GraphicsDrivers(null,
            drivers => !drivers.IsReady && drivers.ErrorMessage == DriversProfilesViewModel.ReadFailed));

        await Scenario("Graphics drivers shows a plain sentence, not the raw error, when reading the page fails", () => GraphicsDrivers(new DriverHardwareSummary
        {
            Machine = new() { Manufacturer = "Fixture", Model = "PC", OsCaption = "Windows" },
            Gpus = [new() { Name = "NVIDIA Fixture GPU", DriverVersion = "1.0", DriverDate = "2026-01-01" }],
        }, drivers => !drivers.IsReady && drivers.ErrorMessage == DriversProfilesViewModel.ReadFailed, unreadableProfiles: true));

        await Scenario("The Graphics drivers page shows no internal tags or confirmation boxes and offers Retry when the read fails", () =>
        {
            var folder = new DirectoryInfo(AppContext.BaseDirectory);
            const string relative = "docs/internal/frontend/RooIndustries.OptimizationSuite.App/Views/DriversProfilesPage.xaml";
            while (folder is not null && !File.Exists(Path.Combine(folder.FullName, relative))) folder = folder.Parent;
            if (folder is null) return Task.FromResult(false);
            var page = File.ReadAllText(Path.Combine(folder.FullName, relative));
            var hidden = page.IndexOf("<Expander x:Name=\"NvidiaProfilesSection\" x:Load=\"False\"", StringComparison.Ordinal);
            var shown = hidden < 0 ? page : page[..hidden] + page[page.IndexOf("</Expander>", hidden, StringComparison.Ordinal)..];
            string[] internals = ["Text=\"Manual\"", "Drivers &amp; GPU", "No driver recommendations", "Close and reopen", "{x:Bind Protected", "{x:Bind Reason"];
            return Task.FromResult(hidden > 0 && !internals.Any(text => page.Contains(text, StringComparison.Ordinal))
                && !shown.Contains("<CheckBox", StringComparison.Ordinal) && !shown.Contains("<ContentDialog", StringComparison.Ordinal)
                && shown.Contains("Command=\"{x:Bind ViewModel.RetryCommand}\"", StringComparison.Ordinal));
        });

        await Scenario("After the page's own removal ran, clearing the picked app lists only the apps that are left", async () =>
        {
            App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
            App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            cleanup.SelectedApp = cleanup.Apps.Single(app => app.AppId == "registry:Editor");
            cleanup.RemovalPathReviewed = true; cleanup.LeftoverScanCompleted = true; cleanup.CleanupPlanReady = true;
            cleanup.RemoverPathApproved = true; cleanup.CleanupListApproved = true;
            cleanup.FinalCheckPassed = true; cleanup.RealCleanupApproved = true;
            App.Live.CleanupApply = (id, _, _, _) =>
            {
                using (DataGeneration.BeginChange()) { App.Live.InstalledApps = Apps("Player"); }
                return Task.FromResult<string?>(JsonSerializer.Serialize(new { actionId = "apps.invokeUninstallCleanupApplyPackage", appId = id, dryRun = false, status = "partial", executionMode = "real", summary = new { deletedCount = 1 } }));
            };
            await cleanup.ApplyCleanupCommand.ExecuteAsync(null);
            var quiet = cleanup.StaleNotice.Length == 0 && cleanup.Apps.Count == 2;
            cleanup.SelectedApp = null;
            await Until(() => cleanup.Apps.Count == 1);
            return quiet && cleanup.Apps.Count == 1 && cleanup.Apps[0].AppId == "registry:Player" && cleanup.IsReady && cleanup.StaleNotice.Length == 0;
        });

        await Scenario("A removal that changed nothing leaves the list alone when the picked app is cleared", async () =>
        {
            App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
            App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            cleanup.SelectedApp = cleanup.Apps.First();
            var reads = 0;
            App.Live.BeforeInstalledApps = () => { reads++; return Task.CompletedTask; };
            cleanup.ScanBusy = true;
            cleanup.ScanBusy = false;
            cleanup.SelectedApp = null;
            await Task.Delay(100);
            App.Live.BeforeInstalledApps = null;
            return reads == 0 && cleanup.Apps.Count == 2;
        });

        await Scenario("A page load that overlaps the page's own change shows the list from after the change in every order of the six steps", async () =>
        {
            var wrong = new List<string>();
            foreach (var order in Merges(["trigger", "read", "end"], ["ownStart", "change", "ownEnd"]))
            {
                App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
                App.Live.InstalledApps = Apps("Editor", "Player");
                var cleanup = new UninstallCleanupViewModel();
                await cleanup.InitializeAsync();
                var beforeRead = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var readDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var afterRead = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                Task? load = null;
                foreach (var step in order)
                {
                    switch (step)
                    {
                        case "trigger":
                            App.Live.BeforeInstalledApps = () => { App.Live.BeforeInstalledApps = null; return beforeRead.Task; };
                            App.Live.AfterInstalledApps = () => { App.Live.AfterInstalledApps = null; readDone.TrySetResult(); return afterRead.Task; };
                            load = cleanup.InitializeAsync();
                            break;
                        case "read":
                            beforeRead.SetResult();
                            await Task.WhenAny(readDone.Task, Task.Delay(2000));
                            break;
                        case "end":
                            afterRead.SetResult();
                            await load!;
                            break;
                        case "ownStart": cleanup.ScanBusy = true; break;
                        case "change": using (DataGeneration.BeginChange()) { App.Live.InstalledApps = Apps("Editor"); } break;
                        case "ownEnd": cleanup.ScanBusy = false; break;
                    }
                }
                for (var i = 0; i < 25 && !(cleanup.IsReady && cleanup.Apps.Count == 1); i++) { await cleanup.RevalidateAsync(); await Task.Delay(20); }
                if (!(cleanup.IsReady && cleanup.Apps.Count == 1 && cleanup.StaleNotice.Length == 0)) wrong.Add(string.Join(">", order) + " shows " + cleanup.Apps.Count + (cleanup.IsReady ? "" : " (not ready)") + " stale='" + cleanup.StaleNotice + "' outOfDate='" + cleanup.OutOfDateNotice + "' error='" + cleanup.ErrorMessage + "' changing=" + DataGeneration.Changing);
            }
            if (wrong.Count > 0) Console.WriteLine("  old list kept after: " + string.Join(" | ", wrong));
            return wrong.Count == 0;
        });

        await Scenario("A load that read before the page's own change and finishes after it is read again", async () =>
        {
            App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
            App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            var readDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            App.Live.AfterInstalledApps = () => { App.Live.AfterInstalledApps = null; readDone.TrySetResult(); return finish.Task; };
            var load = cleanup.InitializeAsync();
            await readDone.Task;
            cleanup.ScanBusy = true;
            using (DataGeneration.BeginChange()) { App.Live.InstalledApps = Apps("Editor"); }
            cleanup.ScanBusy = false;
            finish.SetResult();
            await load;
            await Until(() => cleanup.Apps.Count == 1);
            return cleanup.Apps.Count == 1 && cleanup.IsReady && cleanup.StaleNotice.Length == 0;
        });

        await Scenario("A background reload that fails keeps the shown page and its numbers", async () =>
        {
            App.Live.LastError = null;
            App.Live.Classification = Background(2);
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            App.Live.Classification = null; App.Live.LastError = "Controlled background failure";
            using (DataGeneration.BeginChange()) { }
            await startup.RevalidateAsync();
            App.Live.LastError = null;
            return startup.IsReady && startup.ErrorMessage is null && startup.BackgroundCount == 2;
        });

        await Scenario("A background reload that fails says the page may be out of date and logs the reason", async () =>
        {
            App.Live.LastError = null;
            App.Live.Classification = Background(2);
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            var logged = new List<string>();
            AppLog.Observer = (source, detail) => logged.Add(source + ": " + detail);
            try
            {
                App.Live.Classification = null; App.Live.LastError = "Controlled background failure";
                using (DataGeneration.BeginChange()) { }
                await startup.RevalidateAsync();
            }
            finally { AppLog.Observer = null; App.Live.LastError = null; }
            return startup.OutOfDateNotice.Length > 0 && startup.IsReady && logged.Any(line => line.StartsWith("StartupServicesViewModel", StringComparison.Ordinal) && line.Contains("Controlled background failure", StringComparison.Ordinal));
        });

        await Scenario("Refresh from the out-of-date notice reads again and clears the notice", async () =>
        {
            App.Live.LastError = null;
            App.Live.Classification = Background(2);
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            App.Live.Classification = null; App.Live.LastError = "Controlled background failure";
            using (DataGeneration.BeginChange()) { }
            await startup.RevalidateAsync();
            var flagged = startup.OutOfDateNotice.Length > 0;
            App.Live.Classification = Background(5); App.Live.LastError = null;
            await startup.RetryCommand.ExecuteAsync(null);
            return flagged && startup.OutOfDateNotice.Length == 0 && startup.IsReady && startup.BackgroundCount == 5;
        });

        await Scenario("A background reload that succeeds after a failed one clears the out-of-date notice", async () =>
        {
            App.Live.LastError = null;
            App.Live.Classification = Background(2);
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            App.Live.Classification = null; App.Live.LastError = "Controlled background failure";
            using (DataGeneration.BeginChange()) { }
            await startup.RevalidateAsync();
            App.Live.Classification = Background(4); App.Live.LastError = null;
            using (DataGeneration.BeginChange()) { }
            await startup.RevalidateAsync();
            return startup.OutOfDateNotice.Length == 0 && startup.IsReady && startup.BackgroundCount == 4;
        });

        await Scenario("A first read and an explicit reload that fail still show the error, not the old page", async () =>
        {
            App.Live.LastError = "Controlled first failure"; App.Live.Classification = null;
            var startup = new StartupServicesViewModel();
            await startup.InitializeAsync();
            var first = !startup.IsReady && startup.ErrorMessage == "Controlled first failure" && startup.OutOfDateNotice.Length == 0;
            App.Live.LastError = null; App.Live.Classification = Background(2);
            await startup.ReloadAsync();
            App.Live.Classification = null; App.Live.LastError = "Controlled reload failure";
            await startup.ReloadAsync();
            App.Live.LastError = null;
            return first && !startup.IsReady && startup.ErrorMessage == "Controlled reload failure" && startup.OutOfDateNotice.Length == 0;
        });

        await Scenario("A background reload where Remove apps reports no apps keeps the list on screen", async () =>
        {
            App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
            App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            App.Live.InstalledApps = null;
            using (DataGeneration.BeginChange()) { }
            await cleanup.RevalidateAsync();
            var kept = cleanup.IsReady && cleanup.ErrorMessage is null && cleanup.Apps.Count == 2 && cleanup.OutOfDateNotice.Length > 0;
            App.Live.InstalledApps = Apps("Editor");
            await cleanup.RetryCommand.ExecuteAsync(null);
            return kept && cleanup.IsReady && cleanup.Apps.Count == 1 && cleanup.OutOfDateNotice.Length == 0;
        });

        await Scenario("The page's own change does not mark a page that failed to refresh as current", async () =>
        {
            App.Live.LastError = null; App.Live.BeforeInstalledApps = null; App.Live.AfterInstalledApps = null;
            App.Live.InstalledApps = Apps("Editor", "Player");
            var cleanup = new UninstallCleanupViewModel();
            await cleanup.InitializeAsync();
            App.Live.InstalledApps = null;
            using (DataGeneration.BeginChange()) { }
            await cleanup.RevalidateAsync();
            var flagged = cleanup.OutOfDateNotice.Length > 0 && cleanup.Apps.Count == 2;
            App.Live.InstalledApps = Apps("Editor");
            cleanup.ScanBusy = true;
            using (DataGeneration.BeginChange()) { }
            cleanup.ScanBusy = false;
            await Until(() => cleanup.Apps.Count == 1);
            return flagged && cleanup.Apps.Count == 1 && cleanup.OutOfDateNotice.Length == 0 && cleanup.IsReady;
        });

        await Scenario("A process list refresh that fails reports the failure so the page is not marked seen", async () =>
        {
            App.Live.LastError = "Controlled process list failure"; App.Live.Inventory = null;
            var process = new ProcessControlsViewModel();
            var failed = await process.TryRefreshAsync();
            var failureShown = process.Status == "Couldn't refresh applications.";
            App.Live.LastError = null;
            App.Live.Inventory = new ProcessInventory { Processes = [new ProcessItem { Pid = 4242, Name = "fixture-process", Category = "backgroundApp" }] };
            var worked = await process.TryRefreshAsync();
            return !failed && failureShown && worked && process.Processes.Count == 1;
        });

        check(failures.Count == 0, "Revisit freshness checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
