using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class GameSessionPresetChecks
{
    const string SavedLine = "Saved for next time: these turn back on whenever launcher.exe opens while this app is open. After a restart, open the app once and they're back. Turn them off under Saved launch settings.";
    const string NoCore = "Pick at least one core.";

    public static async Task RunAsync(Action<bool, string> check)
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        var shipped = LaunchPresetCatalog.Read(Path.Combine(fixtures, "launch-presets.json")).Presets;
        var schema = JsonNode.Parse(File.ReadAllText(Path.Combine(fixtures, "roo-industries-backend-contracts.schema.json")))!;
        var allowed = schema["$defs"]!["launchPresetCatalog"]!["properties"]!["presets"]!["items"]!["properties"]!["settings"]!["properties"]!.AsObject();
        var launcher = new RunningProcess(4100, "1", Path.Combine(fixtures, "launcher.exe"));
        LogicalCpu[] topology = [.. Enumerable.Range(0, 12).Select(index => new LogicalCpu((uint)index, 0, (byte)index, (byte)(index / 2), 0, 0, (byte)(index < 8 ? 1 : 0), false, index == 10, false))];
        const string launcherCores = "0x7FF";
        var usable = string.Join(",", Enumerable.Range(1, 10));
        ProtectedSessionPreview Plan(Dictionary<string, JsonElement> controls) => new()
        {
            SchemaVersion = 1, OperationId = "presets", Owner = new OperationOwner("PC", "S-1-5-21-0"), Launcher = launcher, LauncherHash = "", GamePath = Path.Combine(fixtures, "game.exe"),
            GameHash = "", GameLength = 1, GameModifiedAtUtc = DateTime.UtcNow, TopologyHash = CpuSelection.Fingerprint(topology), OriginalAffinity = new AffinityState(0, launcherCores), Controls = controls,
            OriginalLaunchSettings = new LaunchPrioritySnapshot { ImageKeyExisted = false, OptionsKeyExisted = false, Values = new() }, LauncherChanges = null, AcceptLauncherScope = true,
        };
        ProcessControlSnapshot Snapshot(string cores) => new(launcher, ControlRead.From(0u), topology, new Dictionary<string, ControlRead> { ["affinity"] = ControlRead.From(new AffinityState(0, cores)) });
        string Written(IEnumerable<KeyValuePair<string, JsonElement>> controls) => string.Join(",", controls.Where(pair => pair.Key != "affinity").OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + "=" + pair.Value.GetRawText()));
        string Boxes(GameSessionViewModel model, Func<GameCoreBox, bool> which) => string.Join(",", model.Cores.Where(which).Select(box => box.Label["Core ".Length..]));
        string Ticked(GameSessionViewModel model) => Boxes(model, box => box.IsChecked);
        GameCoreBox Core(GameSessionViewModel model, int number) => model.Cores.Single(box => box.Label == "Core " + number);
        void Pick(GameSessionViewModel model, params int[] numbers)
        {
            foreach (var box in model.Cores) box.IsChecked = false;
            foreach (var number in numbers) Core(model, number).IsChecked = true;
        }
        string[] Lines(GameSessionViewModel model) => model.ReviewSummary.Split('\n');
        GameSessionSetting Setting(GameSessionViewModel model, string name) => model.Settings.Single(setting => setting.Name == name);
        ControlOption Option(GameSessionSetting setting, string label) => setting.Options.Single(option => option.Label == label);
        JsonElement Json<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
        var before = (App.Live.Inventory, App.Operations.ProcessSnapshot, App.Operations.GameSessions, App.Operations.LaunchProfiles, GameSessionViewModel.PresetsPath, AppLog.Observer, App.Operations.GameReview, App.Operations.GameSwitch);
        var started = App.Operations.StartedSessions.Count;
        var saved = App.Operations.SavedLaunchProfiles.Count;
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-presets-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        Dictionary<string, JsonElement>? sent = null;
        App.Live.Inventory = new ProcessInventory { Processes = [new ProcessItem { Pid = launcher.ProcessId, Name = "launcher.exe", Category = "backgroundApp" }] };
        App.Operations.ProcessSnapshot = Snapshot(launcherCores);
        App.Operations.GameReview = controls => { sent = controls; return new GameSessionReview(Plan(controls), @"C:\Fixture\preview.json", "hash", @"C:\Fixture\game-session"); };
        try
        {
            GameSessionViewModel.PresetsPath = Path.Combine(fixtures, "launch-presets.json");
            var model = new GameSessionViewModel();
            await model.InitializeAsync();
            check(model.Presets.Select(preset => preset.Name).SequenceEqual(shipped.Select(preset => preset.Name)) && model.SelectedPreset is null && model.PresetPlaceholder == "Choose a preset",
                "The Games tab offers the shipped launch presets, with none picked on a fresh form");
            string Friendly(string name) => RooIndustries.OptimizationSuite.Helpers.Naming.FriendlyName(name);
            check(model.Launchers.Single().ToString() == Friendly("launcher.exe") && !model.Launchers.Single().ToString().Contains("PID", StringComparison.Ordinal),
                "The launcher list shows a launcher by name, without a process number");
            var inventory = App.Live.Inventory;
            var startedAt = GameSessionViewModel.LauncherStarted;
            try
            {
                App.Live.Inventory = new ProcessInventory { Processes = [new ProcessItem { Pid = 5002, Name = "steam.exe", Category = "backgroundApp" }, new ProcessItem { Pid = 5001, Name = "steam.exe", Category = "backgroundApp" }, inventory!.Processes![0]] };
                var opened = new DateTime(2026, 10, 24, 21, 41, 0, DateTimeKind.Local);
                var steam = Friendly("steam.exe");
                GameSessionViewModel.LauncherStarted = pid => pid == 5001 ? opened : pid == 5002 ? opened.AddMinutes(7) : null;
                var copies = new GameSessionViewModel();
                await copies.InitializeAsync();
                check(copies.Launchers.Select(choice => choice.ToString()).SequenceEqual([Friendly("launcher.exe"), steam + " (opened " + opened.ToString("t") + ")", steam + " (opened " + opened.AddMinutes(7).ToString("t") + ")"])
                    && copies.Launchers[1].Id == 5001 && copies.Launchers[2].Id == 5002,
                    "Two open copies of one launcher are told apart by when each opened, oldest first, while a single launcher shows just its name");
                GameSessionViewModel.LauncherStarted = pid => pid is 5001 or 5002 ? opened : null;
                copies = new GameSessionViewModel();
                await copies.InitializeAsync();
                check(copies.Launchers.Skip(1).Select(choice => choice.ToString()).SequenceEqual([steam + " (copy 1)", steam + " (copy 2)"]),
                    "Copies opened in the same minute are numbered instead of showing the same time");
                GameSessionViewModel.LauncherStarted = _ => null;
                copies = new GameSessionViewModel();
                await copies.InitializeAsync();
                check(copies.Launchers.Skip(1).Select(choice => choice.ToString()).SequenceEqual([steam + " (copy 1)", steam + " (copy 2)"]) && copies.Launchers[1].Id == 5001,
                    "Copies whose open time can't be read are numbered in process order");
            }
            finally { App.Live.Inventory = inventory; GameSessionViewModel.LauncherStarted = startedAt; }
            check(model.Settings.All(setting => setting.Options.Skip(1).Select(option => option.Value!.Value.GetRawText())
                .SequenceEqual(allowed[setting.Name]!["enum"]!.AsArray().Select(value => value!.ToJsonString()))), "Each session setting offers exactly the values a launch preset may use");
            check(model.Settings.Select(setting => setting.Label).SequenceEqual(["CPU priority", "Disk priority", "Memory priority", "GPU priority", "Power mode", "Priority boost"])
                && Setting(model, "priorityBoost").Options.Select(option => option.Label).SequenceEqual(["Keep current", "On", "Off"]),
                "Session settings have short plain names and Priority boost reads On or Off");
            check(ProcessControlsViewModel.Label("ioPriority") == "Disk priority" && ProcessControlsViewModel.Label("affinity") == "CPU cores"
                && ProcessControlsViewModel.Describe("priorityBoost", Json(true)) == "On" && ProcessControlsViewModel.Describe("priorityBoost", Json(false)) == "Off"
                && ProcessControlsViewModel.Describe("affinity", Json(new AffinityState(0, "0xFF"))) == "Cores 1–8"
                && ProcessControlsViewModel.Describe("affinity", Json(new AffinityState(0, "0x4"))) == "Core 3"
                && ProcessControlsViewModel.Describe("affinity", Json(new AffinityState(0, "0xD0F"))) == "Cores 1–4, 9, 11–12"
                && ProcessControlsViewModel.Describe("affinity", Json(new AffinityState(1, "0x3"))) == "Cores 1–2 in group 1",
                "Shared names read Disk priority and CPU cores, boost reads On or Off, and cores read as numbered ranges with a group only when it isn't the first");
            model.SelectedLauncher = model.Launchers.Single();
            check(model.Cores.Select(box => box.Label).SequenceEqual(Enumerable.Range(1, 12).Select(number => "Core " + number))
                && model.Cores.Select(box => box.AutomationId).SequenceEqual(Enumerable.Range(1, 12).Select(number => "GameSessionCore" + number))
                && Boxes(model, box => box.Enabled) == usable && model.Cores.All(box => box.Kind == (int.Parse(box.Label["Core ".Length..]) <= 8 ? "Performance" : "Efficiency"))
                && model.AllCores && Ticked(model) == usable && model.AffinityMask == launcherCores && !model.ShowCoresSummary && model.CoreHint.Length == 0
                && model.CoreChoices.Select(choice => choice.Label).SequenceEqual(["Performance cores", "Efficiency cores"]),
                "A launcher's cores show as one checkbox each with All cores checked, a reserved core and one the launcher can't use are disabled, hybrid cores say which kind they are, and the quick choices leave out all cores");
            var cores = model.AffinityMask;
            foreach (var preset in model.Presets)
            {
                model.SelectedPreset = preset;
                check(model.Settings.All(setting => preset.Settings.TryGetValue(setting.Name, out var value) ? setting.Selected.Value?.GetRawText() == value.GetRawText() : setting.Selected.Value is null)
                    && model.SelectedPreset == preset && model.PresetHint == preset.Description && model.AffinityMask == cores && model.AllCores,
                    "Picking " + preset.Name + " fills in exactly its settings, resets the rest to Keep current, preserves cores and shows its description");
            }
            var picked = model.Presets[0];
            model.SelectedPreset = picked;
            var edited = model.Settings.First(setting => !picked.Settings.ContainsKey(setting.Name));
            edited.Selected = edited.Options[^1];
            check(model.SelectedPreset is null && model.PresetPlaceholder == LaunchPresetCatalog.Custom && model.PresetHint == "Your own mix. Picking a preset changes the priorities but keeps your cores.",
                "Changing a setting after picking " + picked.Name + " shows Custom");
            edited.Selected = edited.Options[0];
            check(model.SelectedPreset is null && model.PresetPlaceholder == LaunchPresetCatalog.Custom, "Putting a setting back keeps Custom until a preset is picked again");
            model.GamePath = Path.Combine(fixtures, "game.exe"); model.KeepArmed = true;
            App.Operations.GameReviewScope = null;
            await model.PreviewCommand.ExecuteAsync(null);
            check(model.CanStart && App.Operations.GameReviewScope == true, "Review works with no launcher checkbox to tick and still tells the backend the launcher's other apps are covered");
            check(model.CanStart && !model.ReviewSummary.Contains("Preset:", StringComparison.Ordinal), "A custom review makes no preset claim even when the values happen to match one");
            var lines = Lines(model);
            check(lines.Contains("Cores: all") && !model.ReviewSummary.Contains("0x", StringComparison.OrdinalIgnoreCase) && !lines.Any(line => line.StartsWith("Other apps", StringComparison.Ordinal))
                && !model.ReviewSummary.Contains("Launch priorities apply", StringComparison.Ordinal) && lines[^1] == SavedLine,
                "Review says Cores: all for the launcher's own cores, shows no hex, adds no other-apps line when nothing reaches them, and ends with the plain saved-for-next-time line");
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
            Core(model, 1).IsChecked = false;
            check(!model.CanStart && model.ReviewSummary.Length == 0 && model.SelectedPreset == picked && model.PresetHint == picked.Description && !model.AllCores && model.AffinityMask == "0x3FE",
                "Unchecking a core after review clears Start, unchecks All cores and keeps " + picked.Name);
            await model.PreviewCommand.ExecuteAsync(null);
            check(model.CanStart && Lines(model)[1] == "Preset: " + picked.Name && Lines(model).Contains("Cores: 2–10"), "Reviewing cores picked after " + picked.Name + " still names the preset and lists the cores by number");
            model.SelectedPreset = model.Presets[1];
            check(model.AffinityMask == "0x3FE" && Ticked(model) == "2,3,4,5,6,7,8,9,10", "Picking another preset preserves the user's core choice");
            model.SelectedPreset = picked;
            var first = model.SelectedLauncher;
            App.Operations.ProcessReads = _ => Snapshot("0x3F");
            model.SelectedLauncher = new GameLauncherChoice(4200, "other.exe", "other");
            check(model.SelectedPreset == picked && model.PresetHint == picked.Description && model.AffinityMask == "0x3F" && model.AllCores && Boxes(model, box => box.Enabled) == "1,2,3,4,5,6",
                "Switching launchers after picking " + picked.Name + " loads the new launcher's cores and keeps the preset");
            App.Operations.ProcessReads = null;
            model.SelectedLauncher = first;
            check(model.SelectedPreset == picked && model.AffinityMask == launcherCores && model.AllCores, "Switching back keeps the preset and reloads the first launcher's cores");
            foreach (var box in model.Cores.Where(box => box.Enabled)) box.IsChecked = false;
            sent = null;
            await model.PreviewCommand.ExecuteAsync(null);
            check(!model.AllCores && model.AffinityMask.Length == 0 && !model.CanPreview && !model.CanStart && sent is null && model.CoreHint == NoCore,
                "Unchecking every core unchecks All cores, disables Review and asks for at least one core");
            foreach (var box in model.Cores.Where(box => box.Enabled)) box.IsChecked = true;
            check(model.AllCores && model.AffinityMask == launcherCores && model.CanPreview && model.CoreHint.Length == 0, "Checking every core by hand checks All cores and uses the launcher's own cores");
            model.AllCores = false;
            check(Ticked(model).Length == 0 && model.AffinityMask.Length == 0 && !model.CanPreview && model.CoreHint == NoCore, "Unchecking All cores unchecks every core");
            Core(model, 11).IsChecked = true; Core(model, 12).IsChecked = true;
            model.AllCores = true;
            check(Ticked(model) == usable && model.AffinityMask == launcherCores && model.CanPreview && model.SelectedPreset == picked,
                "Checking All cores checks every core the launcher can use and never a disabled one");
            model.UseCoreChoice(model.CoreChoices.Single(choice => choice.Label == "Performance cores"));
            check(Ticked(model) == "1,2,3,4,5,6,7,8" && !model.AllCores && model.AffinityMask == "0xFF" && model.SelectedPreset == picked, "Performance cores checks Cores 1 to 8 and keeps the preset");
            model.UseCoreChoice(model.CoreChoices.Single(choice => choice.Label == "Efficiency cores"));
            check(Ticked(model) == "9,10" && model.AffinityMask == "0x300", "Efficiency cores checks only the efficiency cores the launcher can use");
            edited.Selected = edited.Options[^1];
            Pick(model, 1, 2, 3, 4, 5, 6, 7, 8);
            model.SelectedPreset = picked;
            await model.PreviewCommand.ExecuteAsync(null);
            lines = Lines(model);
            check(model.CanStart && lines[0] == "game.exe via launcher.exe" && lines[1] == "Preset: " + picked.Name && sent is not null && Written(sent) == Written(picked.Controls())
                && sent["affinity"].Deserialize<AffinityState>(OperationFiles.Json) == new AffinityState(0, "0xFF"),
                "Review sends exactly " + picked.Name + "'s settings with the chosen cores and the summary names the preset");
            check(lines.Contains("Cores: 1–8") && !model.ReviewSummary.Contains("0x", StringComparison.OrdinalIgnoreCase) && lines[^2] == "Other apps this launcher opens get the same cores." && lines[^1] == SavedLine,
                "Review lists Cores 1-8 by number, never as hex, and says other apps this launcher opens get the same cores");
            check(App.Operations.StartedSessions.Count == started && App.Operations.SavedLaunchProfiles.Count == saved,
                "Picking and reviewing presets never starts a session or saves a launch profile");
            var reviewed = sent!;
            await model.StartCommand.ExecuteAsync(null);
            check(App.Operations.StartedSessions.LastOrDefault()?.Plan.Controls == reviewed && App.Operations.SavedLaunchProfiles.LastOrDefault()?.Plan.Controls == reviewed,
                "Start, with no launcher checkbox ticked, and Save for next time use the reviewed plan as it was, so saved launch settings keep the exact values");
            var custom = new Dictionary<string, JsonElement>(reviewed) { ["memoryPriority"] = JsonSerializer.SerializeToElement(4) };
            App.Operations.LaunchProfiles = [new LaunchProfileEntry(@"C:\Fixture\profile-preset", Plan(reviewed)), new LaunchProfileEntry(@"C:\Fixture\profile-custom", Plan(custom))];
            await model.RefreshProfilesAsync();
            check(model.Profiles.Select(row => row.Title).SequenceEqual(["game.exe via launcher.exe · " + picked.Name + " preset", "game.exe via launcher.exe"]),
                "Saved launch settings name the preset their values match, and only that one");
            var turning = new TaskCompletionSource<string?>();
            App.Operations.ProfileTurnOff = root =>
            {
                App.Operations.LaunchProfiles = [App.Operations.LaunchProfiles[0] with { Enabled = false }, App.Operations.LaunchProfiles[1]];
                return turning.Task;
            };
            var shown = model.Profiles[0].Status;
            var turnOff = model.TurnOffProfileAsync(model.Profiles[0]);
            await model.RefreshProfilesAsync();
            check(model.Profiles[0].Status == shown, "While saved settings are turning off, their row keeps its text instead of flashing that a session still needs restoring");
            App.Operations.LaunchProfiles = [App.Operations.LaunchProfiles[1]];
            turning.SetResult(null);
            await turnOff;
            check(model.Status == "Saved settings turned off" && model.Profiles.Count == 1 && model.Profiles.All(row => !row.Status.StartsWith("Turned off", StringComparison.Ordinal)),
                "When turning off finishes, only its final message shows and the row is gone");

            App.Operations.GameSessions = [];
            var manual = new GameSessionViewModel();
            await manual.InitializeAsync();
            manual.SelectedLauncher = manual.Launchers.Single();
            Pick(manual, 1, 2, 3, 4, 7, 9, 10);
            check(manual.PresetPlaceholder == "Choose a preset" && manual.PresetHint == "Pick one to fill in the settings below. You can still change them.",
                "Custom cores alone leave the picker on Choose a preset, since presets don't set cores");
            var notified = new List<string?>();
            manual.PropertyChanged += (_, args) => notified.Add(args.PropertyName);
            manual.Settings[0].Selected = manual.Settings[0].Options[1];
            check(manual.PresetPlaceholder == LaunchPresetCatalog.Custom && notified.Contains(nameof(manual.PresetPlaceholder)) && notified.Contains(nameof(manual.PresetHint)),
                "Manual settings notify the picker to show Custom even when no preset was selected");
            manual.Settings[0].Selected = manual.Settings[0].Options[0];
            Setting(manual, "ioPriority").Selected = Option(Setting(manual, "ioPriority"), "Low");
            Setting(manual, "memoryPriority").Selected = Option(Setting(manual, "memoryPriority"), "Below normal");
            manual.GamePath = Path.Combine(fixtures, "game.exe");
            await manual.PreviewCommand.ExecuteAsync(null);
            check(manual.ReviewSummary == string.Join("\n", "game.exe via launcher.exe", "Disk priority: Low", "Memory priority: Below normal", "Cores: 1–4, 7, 9–10",
                    "Other apps this launcher opens get the same cores, disk priority and memory priority."),
                "A custom review lists each setting, the cores by number, and everything other apps this launcher opens also get");
            manual.AllCores = true;
            await manual.PreviewCommand.ExecuteAsync(null);
            check(Lines(manual).Contains("Cores: all") && Lines(manual)[^1] == "Other apps this launcher opens get the same disk priority and memory priority.",
                "With all cores the review names only disk and memory priority for the launcher's other apps");
            Setting(manual, "ioPriority").Selected = Setting(manual, "ioPriority").Options[0];
            await manual.PreviewCommand.ExecuteAsync(null);
            check(Lines(manual)[^1] == "Other apps this launcher opens get the same memory priority.", "With only memory priority chosen the review names just that for the launcher's other apps");
            App.Operations.GameStartFailure = "Session startup failed: " + ProtectedSessions.LauncherClosed;
            try
            {
                await manual.StartCommand.ExecuteAsync(null);
                await manual.ObserveAsync();
                check(manual.Status == "Session startup needs attention." && manual.Detail.Contains(ProtectedSessions.LauncherClosed, StringComparison.Ordinal) && !manual.CanStop && !manual.CanRecover,
                    "A start that failed before changing anything keeps its plain reason on screen instead of switching to Session state unavailable");
            }
            finally { App.Operations.GameStartFailure = null; App.Operations.RemovedSessions.Clear(); }

            var desired = new AffinityState(0, "0xFF");
            ProtectedGameState Game(int processId, Dictionary<string, JsonElement> controls) => new()
            {
                Identity = new RunningProcess(processId, "2", Path.Combine(fixtures, "game.exe")),
                Fields = [.. controls.Select(pair => new ProtectedFieldState { Name = pair.Key, Route = "native", Status = "applied", Observed = new ControlRead(true, pair.Key == "affinity" ? Json(desired) : pair.Value, null) })],
            };
            ProtectedSessionState Session(params ProtectedGameState[] games) => new()
            {
                SchemaVersion = 1, Preview = Plan(reviewed), PreviewPath = "", ReviewHash = "", Host = new RunningProcess(4200, "1", @"C:\Fixture\host.exe"), Status = "active", RegistryStatus = "applied",
                JobStatus = "applied", DesiredAffinity = desired, LauncherJournal = null, Games = [.. games], Errors = [], UpdatedAtUtc = DateTime.UtcNow,
            };
            var partial = new Dictionary<string, JsonElement>(reviewed.Where(pair => pair.Key != "affinity"));
            check(GameSessionDisplay.Title(new(Session(Game(4300, reviewed)), true, null)) == "Active · all settings confirmed", "A session whose game reads back every setting says all settings are confirmed");
            check(GameSessionDisplay.Title(new(Session(Game(4300, partial)), true, null)) == "Partly applied · check each setting below", "A session missing a setting says it's partly applied and to check each setting");
            check(GameSessionDisplay.Title(new(Session(), true, null), launcherCores) == "New cores are set · launch the game normally", "New cores before the game starts say they're set and to launch the game");
            check(GameSessionDisplay.Title(new(Session(Game(4300, reviewed)), true, null), launcherCores) == "Switching cores · checking the game", "New cores while the game runs say they're switching and being checked");

            var state = Session(Game(4300, reviewed));
            App.Operations.GameSessions = [new GameSessionEntry(@"C:\Fixture\game-session", new ProtectedSessionStatus(state, true, null), "profile-preset")];
            var gate = new TaskCompletionSource();
            App.Operations.ProcessReadGate = gate;
            var reopened = new GameSessionViewModel();
            await reopened.InitializeAsync();
            check(reopened.SelectedSession is not null && !reopened.CanEdit && reopened.Cores.Count == 0 && reopened.ShowCoresSummary && reopened.CoresSummary == "Cores: 1–8" && !reopened.CanSwitch,
                "A reopened session shows its cores as text until its launcher has been read");
            App.Operations.ProcessReadGate = null;
            gate.SetResult();
            for (var wait = 0; wait < 50 && reopened.Cores.Count == 0; wait++) await Task.Delay(20);
            check(Ticked(reopened) == "1,2,3,4,5,6,7,8" && !reopened.AllCores && reopened.AffinityMask == "0xFF" && !reopened.ShowCoresSummary && reopened.SelectedPreset?.Id == picked.Id,
                "After its launcher is read, a reopened " + picked.Name + " session checks exactly the cores it asked for and still shows the preset");
            check(reopened.Status == "Active · all settings confirmed" && reopened.Fields.Count == reviewed.Count && reopened.Fields.All(field => !field.Label.Contains("PID", StringComparison.Ordinal))
                && reopened.Fields.Single(field => field.Label == "CPU cores") is { Requested: "Cores 1–8", Observed: "Cores 1–8", Result: "Applied" },
                "Applied settings for one game name each setting without a process number and show cores by number");
            Core(reopened, 9).IsChecked = true;
            check(reopened.CanSwitch && reopened.CanChooseCores && reopened.AffinityMask == "0x1FF" && reopened.SelectedPreset?.Id == picked.Id, "Choosing other cores in a running " + picked.Name + " session keeps the preset");
            Pick(reopened);
            check(!reopened.CanSwitch && reopened.CanChooseCores && reopened.CoreHint == NoCore, "Unchecking every core in a running session blocks Change cores and leaves the boxes editable");
            string? switched = null;
            App.Operations.GameSwitch = (_, mask) => { switched = mask; state.DesiredAffinity = new AffinityState(0, mask); state.UpdatedAtUtc = DateTime.UtcNow; return new ProtectedSessionStatus(state, true, null); };
            reopened.AllCores = true;
            await reopened.SwitchCoresCommand.ExecuteAsync(null);
            check(switched == launcherCores && reopened.Detail == "Switching to all cores. Check Current below." && reopened.Status == "Switching cores · checking the game"
                && reopened.Fields.Single(field => field.Label == "CPU cores") is { Requested: "All cores", Observed: "Cores 1–8", Result: "Switching cores" },
                "Changing to all cores says it's switching and shows All cores next to the cores the game still reads");
            state.Games[0].Fields.Single(field => field.Name == "affinity").Observed = ControlRead.From(new AffinityState(0, launcherCores));
            await reopened.ObserveAsync();
            check(reopened.Fields.Single(field => field.Label == "CPU cores") is { Requested: "All cores", Observed: "All cores" }, "Once the game reads the launcher's own cores, Applied settings says All cores on both sides");
            Pick(reopened, 1, 2, 3, 4, 5, 6, 7, 8);
            await reopened.SwitchCoresCommand.ExecuteAsync(null);
            check(switched == "0xFF" && reopened.Detail == "Switching to cores 1–8. Check Current below."
                && reopened.Fields.Single(field => field.Label == "CPU cores") is { Requested: "Cores 1–8", Observed: "All cores", Result: "Switching cores" },
                "Once the game confirms all cores, changing to Cores 1-8 says which cores it's switching to");
            var pair = Session(Game(4300, reviewed), Game(4301, reviewed));
            pair.Games[1].Fields.Single(field => field.Name == "affinity").Status = "released";
            App.Operations.GameSessions = [new GameSessionEntry(@"C:\Fixture\game-session-pair", new ProtectedSessionStatus(pair, true, null), null)];
            var several = new GameSessionViewModel();
            await several.InitializeAsync();
            check(several.Fields.Count == 2 * reviewed.Count && several.Fields.All(field => field.Label.EndsWith(" · PID 4300", StringComparison.Ordinal) || field.Label.EndsWith(" · PID 4301", StringComparison.Ordinal))
                && several.Fields.Single(field => field.Label == "CPU cores · PID 4301") is { Observed: "Session limit removed", Result: "Core limit removed" },
                "With two game processes each row names its process, and a released core limit says Core limit removed");

            var preparing = Path.Combine(root, "game-session-preparing", "session");
            App.Operations.GameSessions = [new GameSessionEntry(preparing, new ProtectedSessionStatus(null, true, null))];
            App.Operations.GameStop = stopped =>
            {
                App.Operations.RemovedSessions.Add(stopped);
                App.Operations.GameSessions = [new GameSessionEntry(stopped, new ProtectedSessionStatus(null, false, null))];
                return new ProtectedSessionStatus(null, false, null);
            };
            try
            {
                var cancelling = new GameSessionViewModel();
                await cancelling.InitializeAsync();
                check(cancelling.Status == "Preparing the session" && cancelling.CanStop, "A start still in progress shows as preparing and can be stopped");
                await cancelling.StopCommand.ExecuteAsync(null);
                await cancelling.ObserveAsync();
                check(cancelling.Status == "Didn't start · nothing was changed" && cancelling.Detail == "" && !cancelling.CanStop,
                    "Stop on a start still in progress says it didn't start and changed nothing, and keeps saying so after the next refresh");
            }
            finally { App.Operations.GameStop = null; App.Operations.RemovedSessions.Clear(); }

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
            (App.Live.Inventory, App.Operations.ProcessSnapshot, App.Operations.GameSessions, App.Operations.LaunchProfiles, GameSessionViewModel.PresetsPath, AppLog.Observer, App.Operations.GameReview, App.Operations.GameSwitch) = before;
            App.Operations.ProfileTurnOff = null;
            App.Operations.StartedSessions.RemoveRange(started, App.Operations.StartedSessions.Count - started);
            App.Operations.SavedLaunchProfiles.RemoveRange(saved, App.Operations.SavedLaunchProfiles.Count - saved);
            App.Operations.ProcessReads = null;
            App.Operations.ProcessReadGate = null;
            App.Operations.GameReviewScope = null;
            Directory.Delete(root, true);
        }
    }
}
