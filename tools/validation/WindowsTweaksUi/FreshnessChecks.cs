using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class FreshnessChecks
{
    public static async Task Run(string root, Action<bool, string> check)
    {
        var failures = new List<string>();
        var only = Environment.GetEnvironmentVariable("ROO_SCENARIO");
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
        static async Task Until(Func<bool> condition) { for (var i = 0; i < 500 && !condition(); i++) await Task.Delay(20); }
        async Task<(Fixture Fixture, WindowsTweaksViewModel Model)> Load(string name)
        {
            var fixture = new Fixture(Path.Combine(root, name)) { Missing = false };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            return (fixture, model);
        }
        static async Task ChangeElsewhere(Fixture fixture, string option)
        {
            using (DataGeneration.BeginChange())
            {
                var plan = fixture.Engine.Preview("elsewhere-" + option, [new("setting", option)]);
                var file = Path.Combine(Path.GetTempPath(), "roo-elsewhere-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
                try { fixture.Engine.Apply(file, OperationFiles.HashFile(file)); } finally { File.Delete(file); }
            }
            await Task.Yield();
        }

        await Scenario("A visible Windows tweaks page with no picks shows a change made elsewhere without navigating", async () =>
        {
            var (fixture, model) = await Load("visible-no-picks");
            var before = model.Rows[0].Current;
            await ChangeElsewhere(fixture, "on");
            await model.RevalidateAsync();
            return before != "On" && model.Rows[0].Current == "On" && !model.Busy;
        });
        await Scenario("A visible Windows tweaks page with picks keeps them and says settings changed elsewhere", async () =>
        {
            var (fixture, model) = await Load("visible-picks");
            model.Rows[0].ToggleOn = true; var picked = model.Rows[0].Selected.Id;
            await ChangeElsewhere(fixture, "off");
            await model.RevalidateAsync();
            return picked.Length > 0 && model.Rows[0].Selected.Id == picked && model.StaleNotice.Length > 0;
        });
        await Scenario("Returning to Windows tweaks after a change elsewhere keeps picks and shows the notice", async () =>
        {
            var (fixture, model) = await Load("revisit-picks");
            model.Rows[0].ToggleOn = true; var picked = model.Rows[0].Selected.Id; var reads = fixture.StatusReads;
            await ChangeElsewhere(fixture, "off");
            await model.ShowAsync();
            return picked.Length > 0 && model.Rows[0].Selected.Id == picked && fixture.StatusReads == reads && model.StaleNotice.Length > 0;
        });
        await Scenario("Refresh after the notice reads current values and clears the notice", async () =>
        {
            var (fixture, model) = await Load("notice-refresh");
            model.Rows[0].ToggleOn = true;
            await ChangeElsewhere(fixture, "on");
            await model.RevalidateAsync();
            var noticed = model.StaleNotice.Length > 0;
            await model.RefreshCommand.ExecuteAsync(null);
            return noticed && model.StaleNotice.Length == 0 && model.Rows[0].Current == "On";
        });
        await Scenario("A load whose read straddles a change elsewhere is read again before it is shown as complete", async () =>
        {
            var (fixture, model) = await Load("straddle");
            var reads = fixture.StatusReads;
            var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            fixture.AfterStatus = () => { fixture.AfterStatus = null; return hold.Task; };
            var load = model.RefreshCommand.ExecuteAsync(null);
            await Until(() => fixture.StatusReads != reads);
            await ChangeElsewhere(fixture, "on");
            hold.SetResult();
            await load;
            await Until(() => !model.Busy);
            return fixture.StatusReads == reads + 2 && model.Rows[0].Current == "On" && !model.Busy;
        });
        await Scenario("Reviewing file ownership does not hide a change made elsewhere before it", async () =>
        {
            var (fixture, model) = await Load("ownership");
            fixture.AllowOwnership = true;
            await ChangeElsewhere(fixture, "on");
            await model.ReviewOwnershipAsync(@"C:\fixture-ownership.txt");
            model.ClearSelectionCommand.Execute(null);
            var reads = fixture.StatusReads;
            await model.ShowAsync();
            return fixture.StatusReads == reads + 1 && model.Rows[0].Current == "On";
        });
        await Scenario("A straddled load is read again even when saved choices are still waiting to apply", async () =>
        {
            var fixture = new Fixture(Path.Combine(root, "straddle-saved")) { Missing = false };
            fixture.Choices.Save(fixture.Catalog, "my-settings", [new("setting", "on")], null);
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            var reads = fixture.StatusReads;
            var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            fixture.AfterStatus = () => { fixture.AfterStatus = null; return hold.Task; };
            var load = model.RefreshCommand.ExecuteAsync(null);
            await Until(() => fixture.StatusReads != reads);
            await ChangeElsewhere(fixture, "off");
            hold.SetResult();
            await load;
            await Until(() => !model.Busy);
            return fixture.StatusReads == reads + 2 && model.Rows[0].Current == "Off" && model.StaleNotice.Length == 0;
        });
        await Scenario("A review of a profile renamed after loading still sends the choices the user can see", async () =>
        {
            var first = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "First");
            var second = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Second");
            var third = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Third");
            TweakDefinition Setting(string id, RegistryAddress address) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")]);
            var fixture = new Fixture(Path.Combine(root, "renamed-review"), new TweakCatalog(1, "three", [Setting("first", first), Setting("second", second), Setting("third", third)], [])) { Missing = false };
            fixture.Choices.Save(fixture.Catalog, "my-settings", [new("first", "on"), new("second", "on")], null);
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            var row = model.Rows.Single(item => item.Id == "third");
            row.Selected = row.Choices.Single(choice => choice.Id == "on");
            model.ProfileId = "gaming";
            using (DataGeneration.BeginChange()) { }
            await model.RevalidateAsync();
            await model.ReviewCommand.ExecuteAsync(null);
            var sent = fixture.LastPreviewSelections ?? [];
            return model.StaleNotice.Length > 0 && sent.Any(choice => choice.SettingId == "first") && sent.Any(choice => choice.SettingId == "second") && sent.Any(choice => choice.SettingId == "third");
        });
        await Scenario("Reviewing file ownership with no change elsewhere neither reloads nor says settings changed", async () =>
        {
            var (fixture, model) = await Load("ownership-alone");
            fixture.AllowOwnership = true;
            await model.ReviewOwnershipAsync(@"C:\fixture-ownership.txt");
            model.ClearSelectionCommand.Execute(null);
            var reads = fixture.StatusReads;
            await model.ShowAsync();
            return fixture.StatusReads == reads && model.StaleNotice.Length == 0;
        });
        await Scenario("Clearing picks after the changed-elsewhere notice reads the current values", async () =>
        {
            var (fixture, model) = await Load("clear-after-notice");
            model.Rows[0].ToggleOn = true;
            await ChangeElsewhere(fixture, "on");
            await model.RevalidateAsync();
            var noticed = model.StaleNotice.Length > 0; var reads = fixture.StatusReads;
            model.ClearSelectionCommand.Execute(null);
            await Until(() => !model.Busy && fixture.StatusReads != reads);
            return noticed && fixture.StatusReads == reads + 1 && model.StaleNotice.Length == 0 && model.Rows[0].Current == "On";
        });
        await Scenario("A review started after a change elsewhere keeps only the profile choices that still exist", async () =>
        {
            var first = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "First");
            var second = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Second");
            TweakDefinition Setting(string id, RegistryAddress address) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")]);
            var fixture = new Fixture(Path.Combine(root, "stale-review"), new TweakCatalog(1, "two", [Setting("first", first), Setting("second", second)], [])) { Missing = false };
            void Apply(TweakSelection[] choices)
            {
                using (DataGeneration.BeginChange())
                {
                    var plan = fixture.Engine.Preview("my-settings", choices);
                    var file = Path.Combine(Path.GetTempPath(), "roo-stale-review-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
                    try { fixture.Engine.Apply(file, OperationFiles.HashFile(file)); } finally { File.Delete(file); }
                }
            }
            Apply([new("first", "on"), new("second", "on")]);
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            var row = model.Rows.Single(item => item.Id == "first");
            row.Selected = row.Choices.Single(choice => choice.Id == "off");
            Apply([new("first", "on")]);
            await model.RevalidateAsync();
            await model.ReviewCommand.ExecuteAsync(null);
            var sent = fixture.LastPreviewSelections ?? [];
            return model.StaleNotice.Length > 0 && sent.Any(choice => choice.SettingId == "first") && sent.All(choice => choice.SettingId != "second");
        });
        await Scenario("Simple mode keeps an advanced row with a pending choice visible", async () =>
        {
            var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Advanced");
            var advanced = new TweakDefinition("advanced", "advanced", "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, true);
            var fixture = new Fixture(Path.Combine(root, "simple-pending"), new TweakCatalog(1, "advanced", [advanced], [])) { Missing = false };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false; var hidden = model.Rows.Count == 0;
            model.ShowAdvanced = true; var shown = model.Rows.Count == 1;
            model.Rows[0].Selected = model.Rows[0].Choices.Single(choice => choice.Id == "off");
            model.ShowAdvanced = false;
            return hidden && shown && model.Rows.Count == 1 && model.Rows[0].HasPendingChange;
        });
        await Scenario("A shared read that is in flight across a change is not reused for later callers", async () =>
        {
            var reads = new SharedReads(); var calls = 0;
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Task<string> Read() { var number = Interlocked.Increment(ref calls); return Task.Run(async () => { started.TrySetResult(); await release.Task; return "read-" + number; }); }
            var first = reads.GetAsync("straddle", TimeSpan.FromMinutes(1), Read);
            await started.Task;
            using (DataGeneration.BeginChange()) { }
            release.SetResult();
            var firstValue = await first;
            var second = await reads.GetAsync("straddle", TimeSpan.FromMinutes(1), Read);
            return firstValue == "read-1" && second == "read-2" && calls == 2;
        });
        await Scenario("A completed shared read from before a change is not reused after it", async () =>
        {
            var reads = new SharedReads(); var calls = 0;
            Task<string> Read() => Task.FromResult("read-" + Interlocked.Increment(ref calls));
            var before = await reads.GetAsync("completed", TimeSpan.FromMinutes(1), Read);
            var again = await reads.GetAsync("completed", TimeSpan.FromMinutes(1), Read);
            using (DataGeneration.BeginChange()) { }
            var after = await reads.GetAsync("completed", TimeSpan.FromMinutes(1), Read);
            return before == "read-1" && again == "read-1" && after == "read-2";
        });
        await Scenario("A read started within the settle window after a change is not reused, and later reads are cached again", async () =>
        {
            var reads = new SharedReads(); var calls = 0;
            Task<string> Read() => Task.FromResult("read-" + Interlocked.Increment(ref calls));
            using (DataGeneration.BeginChange()) { }
            var settle = TimeSpan.FromMilliseconds(400);
            var first = (await reads.ReadAsync("settle", TimeSpan.FromMinutes(1), Read, settle: settle)).Value;
            var second = (await reads.ReadAsync("settle", TimeSpan.FromMinutes(1), Read, settle: settle)).Value;
            await Task.Delay(500);
            var third = (await reads.ReadAsync("settle", TimeSpan.FromMinutes(1), Read, settle: settle)).Value;
            var fourth = (await reads.ReadAsync("settle", TimeSpan.FromMinutes(1), Read, settle: settle)).Value;
            return first == "read-1" && second == "read-2" && third == "read-3" && fourth == "read-3";
        });
        await Scenario("The result of a restore is not replaced when the page revalidates after its own change", async () =>
        {
            var fixture = new Fixture(Path.Combine(root, "restore-result")) { Missing = false };
            var plan = fixture.Engine.Preview("my-settings", [new("setting", "off")]);
            var file = Path.Combine(Path.GetTempPath(), "roo-restore-result-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
            try { fixture.Engine.Apply(file, OperationFiles.HashFile(file)); } finally { File.Delete(file); }
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            Action settled = () => _ = model.RevalidateAsync();
            DataGeneration.Settled += settled;
            try
            {
                fixture.AfterStatus = () => Task.Delay(150);
                await model.ReviewRestoreCommand.ExecuteAsync(null);
                model.Approved = true;
                await model.ApplyCommand.ExecuteAsync(null);
                await Until(() => !model.Busy);
                await Task.Delay(400);
                return fixture.Applies == 1 && model.Status == "Windows settings saved" && model.StaleNotice.Length == 0 && !model.Busy;
            }
            finally { DataGeneration.Settled -= settled; fixture.AfterStatus = null; }
        });
        await Scenario("A foreign change that settles while the page is busy with a review is noticed when the review ends", async () =>
        {
            var (fixture, model) = await Load("busy-review");
            Action settled = () => _ = model.RevalidateAsync();
            DataGeneration.Settled += settled;
            try
            {
                model.Rows[0].ToggleOn = true;
                fixture.BeforePreview = () => { fixture.BeforePreview = null; AsForeign(() => { using (DataGeneration.BeginChange()) { } }); return Task.CompletedTask; };
                await model.ReviewCommand.ExecuteAsync(null);
                await Until(() => model.StaleNotice.Length > 0);
                return model.StaleNotice.Length > 0 && !model.Busy;
            }
            finally { DataGeneration.Settled -= settled; }
        });
        await Scenario("Clearing the selection and picking one setting sends only that pick after a change elsewhere", async () =>
        {
            var first = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "First");
            var second = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Second");
            var third = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Third");
            TweakDefinition Setting(string id, RegistryAddress address) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")]);
            var fixture = new Fixture(Path.Combine(root, "clear-then-pick"), new TweakCatalog(1, "three", [Setting("first", first), Setting("second", second), Setting("third", third)], [])) { Missing = false };
            fixture.Choices.Save(fixture.Catalog, "my-settings", [new("first", "on"), new("second", "on")], null);
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ClearSelectionCommand.Execute(null);
            var row = model.Rows.Single(item => item.Id == "third");
            row.Selected = row.Choices.Single(choice => choice.Id == "on");
            using (DataGeneration.BeginChange()) { }
            await model.RevalidateAsync();
            await model.ReviewCommand.ExecuteAsync(null);
            var sent = fixture.LastPreviewSelections ?? [];
            return sent.Length == 1 && sent[0].SettingId == "third";
        });
        await Scenario("Picking a preset that sets a hidden advanced row keeps that row visible in simple mode", async () =>
        {
            var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "AdvancedPreset");
            var advanced = new TweakDefinition("advanced", "advanced", "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, true);
            var fixture = new Fixture(Path.Combine(root, "preset-advanced"), new TweakCatalog(1, "advanced", [advanced], [new("advanced-preset", "Advanced preset", [new("advanced", "off")])])) { Missing = false };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var hidden = model.Rows.Count == 0;
            model.SelectedPreset = model.Presets.Single();
            return hidden && model.Rows.Count == 1 && model.Rows[0].HasPendingChange;
        });
        await Scenario("An operation of the page's own is accepted without a reload, and a foreign change during it is not swallowed", async () =>
        {
            var (fixture, model) = await Load("own-operation");
            var reads = fixture.StatusReads;
            await model.OwnAsync(async () => { using (DataGeneration.BeginChange()) { } await Task.Yield(); });
            await model.ShowAsync();
            var accepted = fixture.StatusReads == reads && model.StaleNotice.Length == 0;
            await model.OwnAsync(async () =>
            {
                using (DataGeneration.BeginChange()) { }
                AsForeign(() => { using (DataGeneration.BeginChange()) { } });
                await Task.Yield();
            });
            await model.ShowAsync();
            return accepted && fixture.StatusReads == reads + 1;
        });
        await Scenario("A generation observed while a change is running is never current after the change ends", async () =>
        {
            var change = DataGeneration.BeginChange();
            var during = DataGeneration.Current;
            var snapshotDuring = DataGeneration.Snapshot();
            change.Dispose();
            await Task.Yield();
            return !DataGeneration.IsCurrent(during) && snapshotDuring == -1 && DataGeneration.IsCurrent(DataGeneration.Snapshot());
        });
        await Scenario("Rows whose Windows feature read timed out say they could not be checked while the other rows stay usable", async () =>
        {
            var first = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "First");
            var second = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Second");
            TweakDefinition Setting(string id, RegistryAddress address) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")]);
            var fixture = new Fixture(Path.Combine(root, "feature-timeout"), new TweakCatalog(1, "two", [Setting("first", first), Setting("second", second)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(setting => setting.Id == "first" ? setting with { Error = TweakEngine.FeaturesTimedOut, Supported = false } : setting).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            var timedOut = model.Rows.Single(row => row.Id == "first"); var other = model.Rows.Single(row => row.Id == "second");
            other.Selected = other.Choices.Single(choice => choice.Id == "off");
            return timedOut.Current == "Couldn't check" && !timedOut.Available && other.Current != "Couldn't check" && other.Available && model.CanReview && !model.Busy;
        });
        check(failures.Count == 0, "Windows tweaks freshness checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
