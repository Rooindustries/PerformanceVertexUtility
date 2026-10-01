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
        public bool HangFeatures { get; set; }
        Task<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>> ITweakStore.ReadControlsAsync(IReadOnlyCollection<ControlAddress> addresses)
        {
            lock (Requested) Requested.AddRange(addresses);
            if (HangFeatures && addresses.Any(address => address.Kind == "windows-features")) return new TaskCompletionSource<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>>().Task;
            return Task.FromResult(((ITweakStore)this).ReadControls(addresses));
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
        check(failures.Count == 0, "Detection bounds and skips (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
