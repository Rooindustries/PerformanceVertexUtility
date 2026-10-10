using System.Diagnostics;
using System.Text.Json;
using RooIndustries.Optimizer;

static class DetectChecks
{
    static readonly ControlAddress Features = new("windows-features", "system", "features");
    static readonly ControlAddress Plain = new("service", "RooIndustriesFixture", "startup");
    static readonly ControlAddress OfficeOnly = new("service", "RooIndustriesOfficeFixture", "startup");

    sealed class HangingFeatureStore(string path) : FileTweakStore(path), ITweakStore
    {
        public List<ControlAddress> Requested { get; } = [];
        public List<ControlAddress> Direct { get; } = [];
        public HashSet<ControlAddress> HangDirect { get; } = [];
        public bool HangFeatures { get; set; }
        public bool HangFast { get; set; }
        public bool FaultFeatures { get; set; }
        Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> Batch(IReadOnlyCollection<ControlAddress> addresses)
        {
            var results = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
            foreach (var address in addresses.Distinct())
            {
                try { results[address] = (ReadControl(address), null); }
                catch (Exception error) { results[address] = (null, error); }
            }
            return results;
        }
        TweakControlRead ITweakStore.ReadControl(ControlAddress address)
        {
            lock (Direct) Direct.Add(address);
            if (HangDirect.Contains(address)) new ManualResetEventSlim().Wait();
            return ReadControl(address);
        }
        Task<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>> ITweakStore.ReadControlsAsync(IReadOnlyCollection<ControlAddress> addresses)
        {
            lock (Requested) Requested.AddRange(addresses);
            var slow = addresses.Any(address => address.Kind == "windows-features");
            if (slow && HangFeatures || !slow && HangFast) return new TaskCompletionSource<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>>().Task;
            if (slow && FaultFeatures) return Task.FromException<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>>(new IOException("Fixture feature batch failed."));
            return Task.FromResult(Batch(addresses));
        }
    }

    public static void Run(string root, Action<bool, string> check)
    {
        var failures = new List<string>();
        void Scenario(string name, Func<bool> body)
        {
            bool passed;
            try { passed = body(); }
            catch (Exception error) { passed = false; name += " (" + error.GetType().Name + ": " + error.Message + ")"; }
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        TweakDefinition Setting(string id, ControlAddress address, object value, bool patch, string[]? requirements = null) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(address, ControlValues.From(value), patch)])], [new("Roo Industries", "fixture", "detection timing")], requirements);
        var catalog = new TweakCatalog(1, "detect-timing", [
            Setting("feature", Features, new Dictionary<string, string> { ["HypervisorPlatform"] = "Enabled" }, true),
            Setting("plain", Plain, "Disabled", false),
            Setting("office-only", OfficeOnly, "Disabled", false, ["office"]),
        ], []);
        HangingFeatureStore Store(string name)
        {
            var path = Path.Combine(root, name + ".json"); FileTweakStore.Create(path);
            var fixture = OperationFiles.Read<TweakFixture>(path);
            fixture.Controls.Add(Features.Key, new(Features, Features.Key, "features", ControlValues.From(new Dictionary<string, string> { ["HypervisorPlatform"] = "Disabled" }), Parents: new() { ["HypervisorPlatform"] = [] }));
            fixture.Controls.Add(Plain.Key, new(Plain, Plain.Key, "fixture", ControlValues.From("Manual")));
            fixture.Controls.Add(OfficeOnly.Key, new(OfficeOnly, OfficeOnly.Key, "fixture", ControlValues.From("Manual")));
            OperationFiles.Write(path, fixture);
            return new(path);
        }

        Scenario("Settings whose requirements fail do not read their Windows controls", () =>
        {
            var store = Store("requirements");
            var detected = new TweakEngine(catalog, store).Detect();
            var office = detected.Settings.Single(setting => setting.Id == "office-only");
            return !store.Requested.Contains(OfficeOnly) && store.Requested.Contains(Plain) && office.Error is not null && !office.Supported;
        });

        Scenario("A Windows features read that never answers is bounded; feature rows say they could not be checked and every other row keeps its state", () =>
        {
            var normal = new TweakEngine(catalog, Store("features-normal")).Detect();
            var store = Store("features-hang"); store.HangFeatures = true;
            var partials = 0;
            var watch = Stopwatch.StartNew();
            var detect = Task.Run(() => new TweakEngine(catalog, store) { FeatureTimeout = TimeSpan.FromSeconds(2) }.Detect(_ => partials++));
            if (!detect.Wait(TimeSpan.FromSeconds(30))) { Console.WriteLine("Detection did not finish within 30 seconds."); return false; }
            var hung = detect.Result;
            var feature = hung.Settings.Single(setting => setting.Id == "feature");
            var others = hung.Settings.Where(setting => setting.Id != "feature").Select(setting => JsonSerializer.Serialize(setting, OperationFiles.Json));
            var expected = normal.Settings.Where(setting => setting.Id != "feature").Select(setting => JsonSerializer.Serialize(setting, OperationFiles.Json));
            Console.WriteLine("Hung feature read finished after " + watch.ElapsedMilliseconds + " ms: " + feature.Error);
            return watch.Elapsed < TimeSpan.FromSeconds(10) && partials == 1 && feature.Error == TweakEngine.FeaturesTimedOut && !feature.Supported && others.SequenceEqual(expected);
        });
        Scenario("Windows features get 60 seconds to answer by default", () => new TweakEngine(catalog, Store("features-default")).FeatureTimeout == TimeSpan.FromSeconds(60));
        Scenario("An available-only preset refuses to plan when Windows features did not answer instead of silently skipping them", () =>
        {
            var store = Store("features-preset"); store.HangFeatures = true;
            var presetCatalog = catalog with { Presets = [new("both", "Both", [new("feature", "set"), new("plain", "set")], AvailableOnly: true)] };
            var engine = new TweakEngine(presetCatalog, store) { FeatureTimeout = TimeSpan.FromSeconds(1) };
            var plan = Task.Run(() => { try { engine.PreviewPreset("preset-profile", "both"); return null; } catch (TimeoutException error) { return error.Message; } });
            return plan.Wait(TimeSpan.FromSeconds(30)) && plan.Result == TweakEngine.FeaturesTimedOut;
        });
        Scenario("A status whose feature rows timed out counts as transient and a normal status does not", () =>
        {
            var normal = new TweakEngine(catalog, Store("transient-normal")).Detect();
            var store = Store("transient-hang"); store.HangFeatures = true;
            var detect = Task.Run(() => new TweakEngine(catalog, store) { FeatureTimeout = TimeSpan.FromSeconds(1) }.Detect());
            return detect.Wait(TimeSpan.FromSeconds(30)) && TweakEngine.HasTransientErrors(detect.Result) && !TweakEngine.HasTransientErrors(normal);
        });
        Scenario("A status whose service rows are still transitioning counts as transient", () =>
        {
            var normal = new TweakEngine(catalog, Store("transitioning")).Detect();
            var transitioning = normal with { Settings = normal.Settings.Select(setting => setting with { Error = "The service is transitioning. Try again after it settles: Fixture" }).ToArray() };
            return TweakEngine.HasTransientErrors(transitioning) && !TweakEngine.HasTransientErrors(normal);
        });
        TweakEngine Engine(TweakCatalog source, ITweakStore store, double? readSeconds = null, double? featureSeconds = null)
        {
            var engine = featureSeconds is { } feature ? new TweakEngine(source, store) { FeatureTimeout = TimeSpan.FromSeconds(feature) } : new TweakEngine(source, store);
            if (readSeconds is { } read) typeof(TweakEngine).GetProperty("ReadTimeout")?.SetValue(engine, TimeSpan.FromSeconds(read));
            return engine;
        }
        static string Row(TweakInspection inspection, string id) => JsonSerializer.Serialize(inspection.Settings.Single(setting => setting.Id == id), OperationFiles.Json);
        (string Path, string Hash) Review(TweakEngine engine, string profile, params TweakSelection[] choices)
        {
            var plan = engine.Preview(profile, choices); var path = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(path, plan);
            return (path, OperationFiles.HashFile(path));
        }
        bool Finished<T>(Func<T> body, int seconds, out T? result, out Exception? failure)
        {
            var task = Task.Run(body);
            result = default; failure = null;
            try { if (!task.Wait(TimeSpan.FromSeconds(seconds))) return false; result = task.Result; }
            catch (AggregateException error) { failure = error.InnerException; }
            return true;
        }

        Scenario("Reads get 60 seconds to answer by default", () => typeof(TweakEngine).GetProperty("ReadTimeout")?.GetValue(new TweakEngine(catalog, Store("reads-default"))) is TimeSpan limit && limit == TimeSpan.FromSeconds(60));
        Scenario("The timed-out message does not blame Windows features when another kind of read was slow", () => !TweakEngine.FeaturesTimedOut.Contains("features", StringComparison.OrdinalIgnoreCase) && TweakEngine.FeaturesTimedOut.Contains("60 seconds", StringComparison.Ordinal));
        Scenario("A fast Windows read that never answers is bounded; its rows say they could not be checked and the other rows keep their state", () =>
        {
            var normal = new TweakEngine(catalog, Store("fast-normal")).Detect();
            var store = Store("fast-hang"); store.HangFast = true;
            var watch = Stopwatch.StartNew();
            if (!Finished(() => Engine(catalog, store, readSeconds: 2).Detect(), 15, out var hung, out var failure)) { Console.WriteLine("Detection did not finish within 15 seconds."); return false; }
            Console.WriteLine("Hung fast read finished after " + watch.ElapsedMilliseconds + " ms: " + hung?.Settings.Single(setting => setting.Id == "plain").Error);
            return failure is null && hung!.Settings.Single(setting => setting.Id == "plain") is { Supported: false, Error: var error } && error == TweakEngine.FeaturesTimedOut
                && Row(hung, "feature") == Row(normal, "feature") && Row(hung, "office-only") == Row(normal, "office-only") && TweakEngine.HasTransientErrors(hung);
        });
        Scenario("A feature batch that faults reports its error on the feature row and never falls back to a direct unbounded read", () =>
        {
            var normal = new TweakEngine(catalog, Store("fault-normal")).Detect();
            var store = Store("fault-feature"); store.FaultFeatures = true; store.HangDirect.Add(Features);
            if (!Finished(() => Engine(catalog, store, readSeconds: 2, featureSeconds: 2).Detect(), 15, out var faulted, out var failure)) { Console.WriteLine("Detection did not finish within 15 seconds."); return false; }
            var feature = faulted?.Settings.Single(setting => setting.Id == "feature");
            Console.WriteLine("Faulted feature batch: " + feature?.Error);
            return failure is null && feature is { Supported: false, Error: not null } && feature.Error.Contains("Fixture feature batch failed.", StringComparison.Ordinal)
                && !store.Direct.Contains(Features) && Row(faulted!, "plain") == Row(normal, "plain");
        });
        Scenario("A review whose control read never answers stops with the timed-out error instead of hanging", () =>
        {
            var store = Store("review-hang"); store.HangDirect.Add(Plain);
            var engine = Engine(catalog, store, readSeconds: 2);
            if (!Finished(() => engine.Preview("review", [new("plain", "set")]), 15, out _, out var failure)) { Console.WriteLine("Review did not finish within 15 seconds."); return false; }
            return failure is TimeoutException && failure.Message == TweakEngine.FeaturesTimedOut;
        });
        Scenario("An undo review whose held service never answers refuses and keeps the profile instead of releasing ownership", () =>
        {
            var store = Store("undo-hang");
            var engine = Engine(catalog, store, readSeconds: 2);
            var applied = Review(engine, "undo", new TweakSelection("plain", "set"));
            engine.Apply(applied.Path, applied.Hash);
            if (store.ReadState()!.Profiles.Length != 1) return false;
            store.HangDirect.Add(Plain);
            if (!Finished(() => engine.Preview("undo", []), 15, out _, out var failure)) { Console.WriteLine("Undo review did not finish within 15 seconds."); return false; }
            store.HangDirect.Clear();
            var held = store.ReadState()!;
            return failure is TimeoutException && held.Profiles.Length == 1 && held.Controls!.Length == 1;
        });
        Scenario("An apply whose control read never answers stops with the timed-out error and writes nothing", () =>
        {
            var store = Store("apply-hang");
            var engine = Engine(catalog, store, readSeconds: 2);
            var review = Review(engine, "apply", new TweakSelection("plain", "set"));
            var before = OperationFiles.HashFile(Path.Combine(root, "apply-hang.json"));
            store.HangDirect.Add(Plain);
            if (!Finished(() => engine.Apply(review.Path, review.Hash), 15, out _, out var failure)) { Console.WriteLine("Apply did not finish within 15 seconds."); return false; }
            return failure is TimeoutException && OperationFiles.HashFile(Path.Combine(root, "apply-hang.json")) == before;
        });
        Scenario("An available-only preset refuses when the fast rows did not answer instead of skipping them", () =>
        {
            var store = Store("preset-fast-hang"); store.HangFast = true;
            var presetCatalog = catalog with { Presets = [new("both", "Both", [new("feature", "set"), new("plain", "set")], AvailableOnly: true)] };
            var engine = Engine(presetCatalog, store, readSeconds: 2);
            if (!Finished(() => engine.PreviewPreset("preset-fast", "both"), 30, out _, out var failure)) { Console.WriteLine("Preset review did not finish within 30 seconds."); return false; }
            return failure is TimeoutException && failure.Message == TweakEngine.FeaturesTimedOut;
        });
        check(failures.Count == 0, "Detection bounds and skips (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
