using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.OptimizationSuite.Views;
using RooIndustries.Optimizer;

static class FreshnessChecks
{
    public static async Task Run(string root, Action<bool, string> check)
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
                var file = Path.Combine(Path.GetTempPath(), "roo-industries-elsewhere-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
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
                    var file = Path.Combine(Path.GetTempPath(), "roo-industries-stale-review-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
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
            var file = Path.Combine(Path.GetTempPath(), "roo-industries-restore-result-" + Guid.NewGuid().ToString("N") + ".json"); OperationFiles.Write(file, plan);
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
        await Scenario("A refresh that straddled a change elsewhere leaves the page changed and catches up when it ends", async () =>
        {
            var queued = new List<Func<Task>>();
            var watch = new ChangeWatch(work => { queued.Add(work); return true; }, _ => Task.CompletedTask);
            watch.MarkSeen();
            var hold = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var refresh = watch.RefreshAsync(() => hold.Task);
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            hold.SetResult(true);
            await refresh;
            return watch.Changed && queued.Count == 1;
        });
        await Scenario("A refresh that fails after a change leaves the page changed and does not queue another catch-up", async () =>
        {
            var queued = new List<Func<Task>>();
            var watch = new ChangeWatch(work => { queued.Add(work); return true; }, _ => Task.CompletedTask);
            watch.MarkSeen();
            var hold = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var refresh = watch.RefreshAsync(() => hold.Task);
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            hold.SetResult(false);
            await refresh;
            return watch.Changed && queued.Count == 0;
        });
        await Scenario("A refresh that throws does not mark the page seen", async () =>
        {
            var watch = new ChangeWatch(_ => true, _ => Task.CompletedTask);
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            watch.MarkSeen();
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            try { await watch.RefreshAsync(() => Task.FromException<bool>(new IOException("Controlled refresh failure"))); } catch (IOException) { }
            return watch.Changed;
        });
        await Scenario("A refresh with no change meanwhile marks the page seen and queues nothing", async () =>
        {
            var queued = new List<Func<Task>>();
            var watch = new ChangeWatch(work => { queued.Add(work); return true; }, _ => Task.CompletedTask);
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            await watch.RefreshAsync(() => Task.FromResult(true));
            return !watch.Changed && queued.Count == 0;
        });
        await Scenario("No refresh entry point of a page watch treats a call that returned as a success", () =>
        {
            var overloads = typeof(ChangeWatch).GetMethods().Where(method => method.Name == "RefreshAsync").ToArray();
            return Task.FromResult(overloads.Length == 1 && overloads[0].GetParameters().Single().ParameterType == typeof(Func<Task<bool>>));
        });
        await Scenario("A page watch is not marked changed again after its own operation, and a foreign change during it is not swallowed", () =>
        {
            var watch = new ChangeWatch(_ => true, _ => Task.CompletedTask);
            watch.MarkSeen();
            watch.OperationStarted();
            using (DataGeneration.BeginChange()) { }
            watch.OperationEnded();
            var accepted = !watch.Changed;
            watch.OperationStarted();
            using (DataGeneration.BeginChange()) { }
            AsForeign(() => { using (DataGeneration.BeginChange()) { } });
            watch.OperationEnded();
            return Task.FromResult(accepted && watch.Changed);
        });
        await Scenario("A page watch settles on the current data after every order of a refresh and a change", async () =>
        {
            var wrong = new List<string>();
            var cases = new (string Name, string[] Refresh, string[] Change, bool Wrap, bool Foreign)[]
            {
                ("own operation", ["refreshStart", "refreshEnd"], ["ownStart", "change", "ownEnd"], false, false),
                ("foreign change", ["refreshStart", "refreshEnd"], ["change"], false, true),
                ("foreign change during a busy refresh", ["refreshStart", "refreshEnd"], ["change"], true, true),
            };
            foreach (var (name, refreshSteps, changeSteps, wrap, foreign) in cases)
            foreach (var order in Merges(refreshSteps, changeSteps))
            {
                var queued = new Queue<Func<Task>>();
                var busy = 0;
                ChangeWatch? self = null;
                var watch = new ChangeWatch(work => { queued.Enqueue(work); return true; }, async revisit =>
                {
                    if ((!revisit && !self!.Changed) || busy > 0) return;
                    await self!.RefreshAsync(() => Task.FromResult(true));
                });
                self = watch;
                watch.Start();
                try
                {
                    watch.MarkSeen();
                    var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    Task? refresh = null;
                    foreach (var step in order)
                    {
                        switch (step)
                        {
                            case "refreshStart":
                                busy++;
                                refresh = watch.RefreshAsync(async () =>
                                {
                                    if (wrap) watch.OperationStarted();
                                    try { return await gate.Task; }
                                    finally { if (wrap) watch.OperationEnded(); }
                                });
                                break;
                            case "refreshEnd": gate.SetResult(true); await refresh!; busy--; break;
                            case "ownStart": busy++; watch.OperationStarted(); break;
                            case "change":
                                if (foreign) AsForeign(() => { using (DataGeneration.BeginChange()) { } });
                                else using (DataGeneration.BeginChange()) { }
                                break;
                            case "ownEnd": busy--; watch.OperationEnded(); break;
                        }
                        for (var i = 0; i < 10 && queued.Count > 0; i++) await queued.Dequeue()();
                    }
                    if (watch.Changed) wrong.Add(name + ": " + string.Join(">", order));
                }
                finally { watch.Stop(); }
            }
            if (wrong.Count > 0) Console.WriteLine("  still changed after: " + string.Join(" | ", wrong));
            return wrong.Count == 0;
        });
        await Scenario("Simple mode keeps a setting whose Windows feature read timed out with Couldn't check and a retry, and hides one this PC does not support", async () =>
        {
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id, bool advanced) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, advanced);
            var fixture = new Fixture(Path.Combine(root, "simple-timeout"), new TweakCatalog(1, "four", [Setting("timedout", false), Setting("fine", false), Setting("unsupported", false), Setting("slowadvanced", true)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                "timedout" or "slowadvanced" => status with { Error = TweakEngine.FeaturesTimedOut, Supported = false },
                "unsupported" => status with { Error = "No choice applies to this Windows version, edition or installed product.", Supported = false },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var listed = model.Rows.Select(row => row.Id).Order().ToArray();
            var timedOut = model.Rows.SingleOrDefault(row => row.Id == "timedout");
            var visible = listed.SequenceEqual(["fine", "timedout"]);
            var says = timedOut is not null && timedOut.SimpleState == "Couldn't check" && timedOut.CanRetry && !model.Rows.Single(row => row.Id == "fine").CanRetry;
            model.ShowAdvanced = true;
            var advancedShows = model.Rows.Count == 4 && model.Rows.Single(row => row.Id == "timedout").Current == "Couldn't check";
            model.ShowAdvanced = false;
            var reads = fixture.StatusReads; fixture.TransformStatus = null;
            timedOut = model.Rows.SingleOrDefault(row => row.Id == "timedout");
            timedOut?.RetryCommand.Execute(null);
            await Until(() => fixture.StatusReads != reads && !model.Busy);
            var after = model.Rows.SingleOrDefault(row => row.Id == "timedout");
            var passed = visible && says && advancedShows && fixture.StatusReads == reads + 1 && after is { CanRetry: false } && after.SimpleState != "Couldn't check";
            if (!passed) Console.WriteLine("  simple mode lists [" + string.Join(", ", listed) + "], says=" + says + ", advanced shows all=" + advancedShows + ", retry re-read=" + (fixture.StatusReads == reads + 1) + ", settled after retry=" + (after is { CanRetry: false }));
            return passed;
        });
        await Scenario("Simple mode keeps a setting whose read failed for any reason other than absence with Couldn't check and a retry, and hides every kind of absence", async () =>
        {
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            var fixture = new Fixture(Path.Combine(root, "simple-other"), new TweakCatalog(1, "six", [Setting("exited"), Setting("denied"), Setting("fine"), Setting("service"), Setting("task"), Setting("office")], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                "exited" => status with { Error = "The Windows control helper exited 1: fixture", Supported = false },
                "denied" => status with { Error = "Access to the fixture control is denied.", Supported = false },
                "service" => status with { Error = "OpenService(Fixture) failed (Win32 1060).", Supported = false },
                "task" => status with { Error = "The task is missing (0x80070002).", Supported = false },
                "office" => status with { Error = "A supported Microsoft Office installation could not be identified.", Supported = false },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var listed = model.Rows.Select(row => row.Id).Order().ToArray();
            var retries = model.Rows.Where(row => row.CanRetry).Select(row => row.Id).Order().ToArray();
            var passed = listed.SequenceEqual(["denied", "exited", "fine"]) && retries.SequenceEqual(["denied", "exited"]) && model.Rows.Where(row => row.CanRetry).All(row => row.SimpleState == "Couldn't check");
            if (!passed) Console.WriteLine("  simple mode lists [" + string.Join(", ", listed) + "], retry on [" + string.Join(", ", retries) + "]");
            return passed;
        });
        await Scenario("A network setting the adapter lacks is hidden in simple mode and explained in full mode, while a failed adapter read keeps Couldn't check and a retry", async () =>
        {
            const string lacking = "windows.bcd77ad54a7accc0", failing = "windows.7f3f80851197aecc";
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id) => new(id, id, "Network", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            var fixture = new Fixture(Path.Combine(root, "network-adapter"), new TweakCatalog(1, "adapter", [Setting(lacking), Setting(failing)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                lacking => status with { Error = "No devices expose RSC on the Ethernet 3 adapter.", Supported = false },
                failing => status with { Error = "LSO configuration is unavailable for Ethernet 3", Supported = false },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var simple = model.Rows.Select(row => row.Id).ToArray();
            model.ShowAdvanced = true;
            var absent = model.Rows.SingleOrDefault(row => row.Id == lacking);
            var failed = model.Rows.SingleOrDefault(row => row.Id == failing);
            var passed = simple.SequenceEqual([failing])
                && absent is { IsNetwork: true, CanRetry: false, UnavailableHere: true } && absent.Detail == "The current adapter does not expose this option. You can save a choice for a compatible adapter."
                && failed is { IsNetwork: true, CanRetry: true, Current: "Couldn't check" } && failed.Detail == "Windows could not read this preference. Refresh to try again.";
            if (!passed) Console.WriteLine("  simple mode lists [" + string.Join(", ", simple) + "], lacking " + (absent is null ? "missing" : absent.CanRetry + "/" + absent.UnavailableHere + "/" + absent.Detail) + ", failing " + (failed is null ? "missing" : failed.CanRetry + "/" + failed.Current + "/" + failed.Detail));
            return passed;
        });
        await Scenario("A mitigation row whose fields Windows leaves at its default says Windows default instead of Custom value", async () =>
        {
            const string dep = "windows.05719d3bbe469a81", cfg = "windows.6eec44b714e4d017", overridden = "windows.ff7c1955e9c48cfa", reserved = "windows.eebc9f3fde48834c";
            var policy = new ControlAddress("mitigations", "system", "policy");
            TweakDefinition Mitigation(string id, string field, string value) => new(id, id, "Security", "Fixture", 10240, 26200, ["*"], "none",
                [new("set", "Set", [], Controls: [new(policy, ControlValues.From(new Dictionary<string, object> { [field] = value, [field.Split('.')[0] + ".Override" + field.Split('.')[0]] = false }), true)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            Dictionary<string, object?> Raw(object? options) => new() { ["MitigationOptions"] = options, ["MitigationAuditOptions"] = null, ["EAFModules"] = null };
            var current = new TweakControlRead(policy, "mitigations:system", "fixture-policy", ControlValues.From(new Dictionary<string, object> { [MitigationControl.SnapshotField] = Raw(null), ["Dep.Enable"] = "NOTSET", ["Dep.OverrideDep"] = false, ["Cfg.Enable"] = "ON", ["Cfg.OverrideCfg"] = false }), "System mitigations");
            var forced = current with { Value = ControlValues.From(new Dictionary<string, object> { [MitigationControl.SnapshotField] = Raw(null), ["Sehop.Enable"] = "NOTSET", ["Sehop.OverrideSehop"] = true }) };
            var configured = current with { Value = ControlValues.From(new Dictionary<string, object> { [MitigationControl.SnapshotField] = Raw(new { name = "MitigationOptions", type = 3, bytes = "AAAAAAAAAAAAAAAAAAAAMA==" }), ["Aslr.BottomUp"] = "NOTSET", ["Aslr.OverrideBottomUp"] = false }) };
            var fixture = new Fixture(Path.Combine(root, "mitigation-default"), new TweakCatalog(1, "mitigations", [Mitigation(dep, "Dep.Enable", "ON"), Mitigation(cfg, "Cfg.Enable", "OFF"), Mitigation(overridden, "Sehop.Enable", "ON"), Mitigation(reserved, "Aslr.BottomUp", "ON")], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status with { Supported = true, Error = null, ConfiguredChoices = [], AvailableChoices = ["set"], Controls = [status.Id == overridden ? forced : status.Id == reserved ? configured : current] }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = true;
            var values = model.Rows.ToDictionary(row => row.Id, row => row.Current);
            var passed = values.GetValueOrDefault(dep) == "Windows default" && values.GetValueOrDefault(cfg) == "Custom value" && values.GetValueOrDefault(overridden) == "Custom value" && values.GetValueOrDefault(reserved) == "Custom value";
            if (!passed) Console.WriteLine("  current values: " + string.Join(", ", values.Select(item => item.Key + "=" + item.Value)));
            return passed;
        });
        await Scenario("A service row whose state isn't one of its choices shows that state instead of Custom value", async () =>
        {
            const string startup = "windows.3f496f83e2c4f002", running = "windows.63bc2ce4fde98aee", matched = "windows.78f9bc6062713ff5";
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id) => new(id, id, "Services", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            TweakControlRead Service(string name, string property, object value) => new(new ControlAddress("service", name, property), "service:" + name + ":" + property, "fixture-service", ControlValues.From(value), name + ": " + property);
            var fixture = new Fixture(Path.Combine(root, "service-state"), new TweakCatalog(1, "service-state", [Setting(startup), Setting(running), Setting(matched)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                startup => status with { ConfiguredChoices = [], Controls = [Service("MapsBroker", "startup", 4)] },
                running => status with { ConfiguredChoices = [], Controls = [Service("BTAGService", "running", true)] },
                matched => status with { ConfiguredChoices = ["off"], Controls = [Service("PcaSvc", "startup", 3)] },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = true;
            var current = model.Rows.ToDictionary(row => row.Id, row => row.Current);
            var passed = current.GetValueOrDefault(startup) == "Disabled" && current.GetValueOrDefault(running) == "Running" && current.GetValueOrDefault(matched) == "Off";
            if (!passed) Console.WriteLine("  current values: " + string.Join(", ", current.Select(item => item.Key + "=" + item.Value)));
            return passed;
        });
        await Scenario("A file setting Windows hard-links or doesn't ship is unavailable here without a retry, while another failed file read keeps Couldn't check", async () =>
        {
            const string linked = "windows.c104f89ba4e1b71b", missing = "windows.05ad0f0f96ac0c21", failing = "windows.3c9ad96209a9da2f";
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id) => new(id, id, "Privacy", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            var fixture = new Fixture(Path.Combine(root, "hard-linked-file"), new TweakCatalog(1, "linked", [Setting(linked), Setting(missing), Setting(failing)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                linked => status with { Error = "Hard-linked file permissions require a separate review.", Supported = false },
                missing => status with { Error = "aitagent.exe is not installed on this PC.", Supported = false },
                failing => status with { Error = "Access is denied.", Supported = false },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var simple = model.Rows.Select(row => row.Id).ToArray();
            model.ShowAdvanced = true;
            var shared = model.Rows.SingleOrDefault(row => row.Id == linked);
            var absent = model.Rows.SingleOrDefault(row => row.Id == missing);
            var failed = model.Rows.SingleOrDefault(row => row.Id == failing);
            var passed = simple.SequenceEqual([failing])
                && shared is { CanRetry: false, UnavailableHere: true } && shared.Detail == "Windows links this file to other copies, so its permissions can't be changed safely here."
                && absent is { CanRetry: false, UnavailableHere: true } && absent.Detail == "aitagent.exe is not installed on this PC."
                && failed is { CanRetry: true, Current: "Couldn't check" };
            if (!passed) Console.WriteLine("  simple mode lists [" + string.Join(", ", simple) + "], linked " + (shared is null ? "missing" : shared.CanRetry + "/" + shared.UnavailableHere + "/" + shared.Detail) + ", not installed " + (absent is null ? "missing" : absent.CanRetry + "/" + absent.UnavailableHere) + ", failing " + (failed is null ? "missing" : failed.CanRetry + "/" + failed.Current));
            return passed;
        });
        await Scenario("A service Windows never lets administrators change is unavailable here without a retry, while a service that is still starting keeps Couldn't check", async () =>
        {
            const string locked = "windows.b356c3123766a188", settling = "windows.4e3841a2d61ce3f9";
            const string refusal = "Windows doesn't let administrators change the startup of this service: printworkflowusersvc";
            RegistryAddress Address(string name) => new("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", name);
            TweakDefinition Setting(string id) => new(id, id, "Services", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(Address(id), 1)]), new("off", "Off", [new(Address(id), 0)])], [new("Fixture", "fixture", "isolated UI validation")], null, false);
            var fixture = new Fixture(Path.Combine(root, "protected-service"), new TweakCatalog(1, "services", [Setting(locked), Setting(settling)], [])) { Missing = false };
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Select(status => status.Id switch
            {
                locked => status with { Error = refusal, Supported = false },
                settling => status with { Error = "The service is transitioning. Try again after it settles: PrintWorkflowUserSvc", Supported = false },
                _ => status,
            }).ToArray() };
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.ShowAsync();
            model.ShowAdvanced = false;
            var simple = model.Rows.Select(row => row.Id).ToArray();
            model.ShowAdvanced = true;
            var refused = model.Rows.SingleOrDefault(row => row.Id == locked);
            var waiting = model.Rows.SingleOrDefault(row => row.Id == settling);
            var passed = simple.SequenceEqual([settling])
                && refused is { CanRetry: false, UnavailableHere: true } && refused.Detail == refusal
                && waiting is { CanRetry: true, Current: "Couldn't check" };
            if (!passed) Console.WriteLine("  simple mode lists [" + string.Join(", ", simple) + "], protected " + (refused is null ? "missing" : refused.CanRetry + "/" + refused.UnavailableHere + "/" + refused.Detail) + ", settling " + (waiting is null ? "missing" : waiting.CanRetry + "/" + waiting.Current));
            return passed;
        });
        check(failures.Count == 0, "Windows tweaks freshness checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
