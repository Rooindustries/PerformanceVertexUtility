using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class GameSessionPresetChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        var shipped = LaunchPresetCatalog.Read(Path.Combine(fixtures, "launch-presets.json")).Presets;
        var schema = JsonNode.Parse(File.ReadAllText(Path.Combine(fixtures, "roo-industries-backend-contracts.schema.json")))!;
        var allowed = schema["$defs"]!["launchPresetCatalog"]!["properties"]!["presets"]!["items"]!["properties"]!["settings"]!["properties"]!.AsObject();
        var launcher = new RunningProcess(4100, "1", Path.Combine(fixtures, "launcher.exe"));
        LogicalCpu[] topology = [new(0, 0, 0, 0, 0, 0, 0, false, false, false), new(1, 0, 1, 1, 0, 0, 0, false, false, false)];
        ProtectedSessionPreview Plan(Dictionary<string, JsonElement> controls) => new()
        {
            SchemaVersion = 1, OperationId = "presets", Owner = new OperationOwner("PC", "S-1-5-21-0"), Launcher = launcher, LauncherHash = "", GamePath = Path.Combine(fixtures, "game.exe"),
            GameHash = "", GameLength = 1, GameModifiedAtUtc = DateTime.UtcNow, TopologyHash = CpuSelection.Fingerprint(topology), OriginalAffinity = new AffinityState(0, "0x3"), Controls = controls,
            OriginalLaunchSettings = new LaunchPrioritySnapshot { ImageKeyExisted = false, OptionsKeyExisted = false, Values = new() }, LauncherChanges = null, AcceptLauncherScope = true,
        };
        string Written(IEnumerable<KeyValuePair<string, JsonElement>> controls) => string.Join(",", controls.Where(pair => pair.Key != "affinity").OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + "=" + pair.Value.GetRawText()));
        var before = (App.Live.Inventory, App.Operations.ProcessSnapshot, App.Operations.GameSessions, App.Operations.LaunchProfiles, GameSessionViewModel.PresetsPath, AppLog.Observer, App.Operations.GameReview);
        var started = App.Operations.StartedSessions.Count;
        var saved = App.Operations.SavedLaunchProfiles.Count;
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-presets-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        Dictionary<string, JsonElement>? sent = null;
        App.Live.Inventory = new ProcessInventory { Processes = [new ProcessItem { Pid = launcher.ProcessId, Name = "launcher.exe", Category = "backgroundApp" }] };
        App.Operations.ProcessSnapshot = new ProcessControlSnapshot(launcher, ControlRead.From(0u), topology, new Dictionary<string, ControlRead> { ["affinity"] = ControlRead.From(new AffinityState(0, "0x3")) });
        App.Operations.GameReview = controls => { sent = controls; return new GameSessionReview(Plan(controls), @"C:\Fixture\preview.json", "hash", @"C:\Fixture\game-session"); };
        try
        {
            GameSessionViewModel.PresetsPath = Path.Combine(fixtures, "launch-presets.json");
            var model = new GameSessionViewModel();
            await model.InitializeAsync();
            check(model.Presets.Select(preset => preset.Name).SequenceEqual(shipped.Select(preset => preset.Name)) && model.SelectedPreset is null && model.PresetPlaceholder == "Choose a preset",
                "The Games tab offers the shipped launch presets, with none picked on a fresh form");
            check(model.Settings.All(setting => setting.Options.Skip(1).Select(option => option.Value!.Value.GetRawText())
                .SequenceEqual(allowed[setting.Name]!["enum"]!.AsArray().Select(value => value!.ToJsonString()))), "Each session setting offers exactly the values a launch preset may use");
            model.SelectedLauncher = model.Launchers.Single();
            var cores = model.AffinityMask;
            foreach (var preset in model.Presets)
            {
                model.SelectedPreset = preset;
                check(model.Settings.All(setting => preset.Settings.TryGetValue(setting.Name, out var value) ? setting.Selected.Value?.GetRawText() == value.GetRawText() : setting.Selected.Value is null)
                    && model.SelectedPreset == preset && model.PresetHint == preset.Description && model.AffinityMask == cores,
                    "Picking " + preset.Name + " fills in exactly its settings, resets the rest to Keep current, preserves cores and shows its description");
            }
            var picked = model.Presets[0];
            model.SelectedPreset = picked;
            var edited = model.Settings.First(setting => !picked.Settings.ContainsKey(setting.Name));
            edited.Selected = edited.Options[^1];
            check(model.SelectedPreset is null && model.PresetPlaceholder == LaunchPresetCatalog.Custom && model.PresetHint.StartsWith("Your own mix", StringComparison.Ordinal),
                "Changing a setting after picking " + picked.Name + " shows Custom");
            edited.Selected = edited.Options[0];
            check(model.SelectedPreset is null && model.PresetPlaceholder == LaunchPresetCatalog.Custom, "Putting a setting back keeps Custom until a preset is picked again");
            model.GamePath = Path.Combine(fixtures, "game.exe"); model.AcceptLauncherScope = true; model.KeepArmed = true;
            await model.PreviewCommand.ExecuteAsync(null);
            check(model.CanStart && !model.ReviewSummary.Contains("Preset:", StringComparison.Ordinal), "A custom review makes no preset claim even when the values happen to match one");
            model.SelectedPreset = picked;
            check(!model.CanStart && model.ReviewSummary.Length == 0, "Picking a preset after a custom review requires a new review even when its values are identical");
            foreach (var setting in model.Settings)
            {
                model.SelectedPreset = picked;
                await model.PreviewCommand.ExecuteAsync(null);
                setting.Selected = setting.Options.First(option => option != setting.Selected);
                check(!model.CanStart && model.ReviewSummary.Length == 0 && model.SelectedPreset is null,
                    "Editing " + setting.Name + " clears the reviewed plan and shows Custom");
            }
            model.SelectedPreset = picked;
            await model.PreviewCommand.ExecuteAsync(null);
            model.AffinityMask = "0x1";
            check(!model.CanStart && model.ReviewSummary.Length == 0 && model.SelectedPreset is null && model.PresetPlaceholder == LaunchPresetCatalog.Custom,
                "Editing cores after review clears Start and shows Custom");
            model.SelectedPreset = picked;
            check(model.AffinityMask == "0x1", "Repicking a preset preserves the user's core choice");
            var first = model.SelectedLauncher;
            App.Operations.ProcessReads = _ => new ProcessControlSnapshot(launcher, ControlRead.From(0u), topology, new Dictionary<string, ControlRead> { ["affinity"] = ControlRead.From(new AffinityState(0, "0x2")) });
            model.SelectedLauncher = new CpuProcessChoice(4200, "other.exe");
            check(model.SelectedPreset == picked && model.PresetHint == picked.Description && model.AffinityMask == "0x2",
                "Switching launchers after picking " + picked.Name + " loads the new launcher's cores and keeps the preset");
            App.Operations.ProcessReads = null;
            model.SelectedLauncher = first;
            check(model.SelectedPreset == picked && model.AffinityMask == "0x3", "Switching back keeps the preset and reloads the first launcher's cores");
            model.AffinityMask = "0x1";
            model.SelectedPreset = picked;
            await model.PreviewCommand.ExecuteAsync(null);
            var lines = model.ReviewSummary.Split('\n');
            check(model.CanStart && lines[0] == "game.exe via launcher.exe" && lines[1] == "Preset: " + picked.Name && sent is not null && Written(sent) == Written(picked.Controls())
                && sent["affinity"].Deserialize<AffinityState>(OperationFiles.Json) == new AffinityState(0, "0x1"),
                "Review sends exactly " + picked.Name + "'s settings with the chosen cores and the summary names the preset");
            check(App.Operations.StartedSessions.Count == started && App.Operations.SavedLaunchProfiles.Count == saved,
                "Picking and reviewing presets never starts a session or saves a launch profile");
            var reviewed = sent!;
            await model.StartCommand.ExecuteAsync(null);
            check(App.Operations.StartedSessions.LastOrDefault()?.Plan.Controls == reviewed && App.Operations.SavedLaunchProfiles.LastOrDefault()?.Plan.Controls == reviewed,
                "Start and Save for next time use the reviewed plan as it was, so saved launch settings keep the exact values");
            var custom = new Dictionary<string, JsonElement>(reviewed) { ["memoryPriority"] = JsonSerializer.SerializeToElement(4) };
            App.Operations.LaunchProfiles = [new LaunchProfileEntry(@"C:\Fixture\profile-preset", Plan(reviewed)), new LaunchProfileEntry(@"C:\Fixture\profile-custom", Plan(custom))];
            await model.RefreshProfilesAsync();
            check(model.Profiles.Select(row => row.Title).SequenceEqual(["game.exe via launcher.exe · " + picked.Name + " preset", "game.exe via launcher.exe"]),
                "Saved launch settings name the preset their values match, and only that one");
            var state = new ProtectedSessionState
            {
                SchemaVersion = 1, Preview = Plan(reviewed), PreviewPath = "", ReviewHash = "", Host = new RunningProcess(4200, "1", @"C:\Fixture\host.exe"), Status = "active", RegistryStatus = "applied",
                JobStatus = "assigned", DesiredAffinity = new AffinityState(0, "0x1"), LauncherJournal = null, Games = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow,
            };
            App.Operations.GameSessions = [new GameSessionEntry(@"C:\Fixture\game-session", new ProtectedSessionStatus(state, true, null), "profile-preset")];
            var reopened = new GameSessionViewModel();
            await reopened.InitializeAsync();
            check(reopened.SelectedSession is not null && !reopened.CanEdit && reopened.SelectedPreset?.Id == picked.Id && reopened.AffinityMask == "0x1",
                "Reopening a session started from " + picked.Name + " shows the preset after its custom cores finish loading");
            App.Operations.GameSessions = [];
            var manual = new GameSessionViewModel();
            await manual.InitializeAsync();
            var notified = new List<string?>();
            manual.PropertyChanged += (_, args) => notified.Add(args.PropertyName);
            manual.Settings[0].Selected = manual.Settings[0].Options[1];
            check(manual.PresetPlaceholder == LaunchPresetCatalog.Custom && notified.Contains(nameof(manual.PresetPlaceholder)) && notified.Contains(nameof(manual.PresetHint)),
                "Manual settings notify the picker to show Custom even when no preset was selected");
            manual.Settings[0].Selected = manual.Settings[0].Options[0];
            manual.SelectedLauncher = manual.Launchers.Single();
            manual.AffinityMask = "0x1";
            check(manual.PresetPlaceholder == LaunchPresetCatalog.Custom, "Custom cores show Custom even when every priority is Keep current");
            GameSessionViewModel.PresetsPath = Path.Combine(fixtures, "missing-launch-presets.json");
            App.Operations.GameSessions = [];
            var missing = new GameSessionViewModel();
            var logged = new List<string>();
            AppLog.Observer = (source, detail) => logged.Add(source + ": " + detail);
            await missing.InitializeAsync();
            check(missing.Presets.Length == 0 && missing.PresetHint.StartsWith("Launch presets couldn't be loaded: ", StringComparison.Ordinal) && missing.Settings.All(setting => setting.Options.Length > 1)
                && logged.Contains("games: " + missing.PresetHint), "A missing preset list says so, is logged, and the settings stay usable");
            var catalog = Path.Combine(root, "launch-presets.json");
            File.Copy(Path.Combine(fixtures, "launch-presets.json"), catalog);
            GameSessionViewModel.PresetsPath = catalog;
            var retry = new GameSessionViewModel();
            await retry.InitializeAsync();
            retry.SelectedPreset = retry.Presets[0];
            File.WriteAllText(catalog, "{broken");
            await retry.InitializeAsync();
            check(retry.Presets.Length == 0 && retry.SelectedPreset is null && retry.PresetHint.StartsWith("Launch presets couldn't be loaded: ", StringComparison.Ordinal),
                "A bad catalog after a good load removes stale preset choices and says what failed");
            File.Copy(Path.Combine(fixtures, "launch-presets.json"), catalog, true);
            await retry.InitializeAsync();
            check(retry.Presets.Length == shipped.Length && !retry.PresetHint.StartsWith("Launch presets couldn't", StringComparison.Ordinal),
                "Restoring the catalog lets the Games tab load presets again");
        }
        finally
        {
            (App.Live.Inventory, App.Operations.ProcessSnapshot, App.Operations.GameSessions, App.Operations.LaunchProfiles, GameSessionViewModel.PresetsPath, AppLog.Observer, App.Operations.GameReview) = before;
            App.Operations.StartedSessions.RemoveRange(started, App.Operations.StartedSessions.Count - started);
            App.Operations.SavedLaunchProfiles.RemoveRange(saved, App.Operations.SavedLaunchProfiles.Count - saved);
            App.Operations.ProcessReads = null;
            Directory.Delete(root, true);
        }
    }
}
