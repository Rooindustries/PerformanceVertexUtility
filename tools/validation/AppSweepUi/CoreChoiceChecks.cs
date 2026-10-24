using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class CoreChoiceChecks
{
    private static readonly OperationOwner Owner = new("FIXTURE", "S-1-5-21-1-2-3-1001");
    private static ControlRead Read<T>(T value) => ControlRead.From(value);
    private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);

    private static LogicalCpu[] TwoCcds() => Enumerable.Range(0, 32)
        .Select(index => new LogicalCpu((uint)(256 + index), 0, (byte)index, (byte)(index / 2), (byte)(index / 16 * 16), 0, 0, false, false, false)).ToArray();

    private static LogicalCpu[] Hybrid() => Enumerable.Range(0, 8)
        .Select(index => new LogicalCpu((uint)(256 + index), 0, (byte)index, (byte)index, 0, 0, (byte)(index < 4 ? 1 : 0), false, false, false)).ToArray();

    private static Dictionary<string, ControlRead> Controls(string mask) => new()
    {
        ["cpuPriority"] = Read("Normal"), ["ioPriority"] = Read(2), ["gpuPriority"] = Read(2), ["memoryPriority"] = Read(5),
        ["executionQoS"] = Read(new PowerThrottling(0, 0)), ["priorityBoost"] = Read(true), ["cpuSets"] = Read(Array.Empty<uint>()), ["affinity"] = Read(new AffinityState(0, mask)),
    };

    private static ulong Mask(Dictionary<string, JsonElement>? controls)
        => controls is not null && controls.TryGetValue("affinity", out var affinity) ? ProcessTarget.ParseMask(affinity.Deserialize<AffinityState>(OperationFiles.Json)!.Mask) : 0;

    private static int[] Ticked(ProcessControlsViewModel page) => page.Cpus.Where(cpu => cpu.Selected).Select(cpu => (int)cpu.Cpu.Index).ToArray();

    internal static async Task ProcessesAsync(Action<bool, string> check)
    {
        var identity = new RunningProcess(123, "1", Path.Combine(Path.GetTempPath(), "game.exe"));
        var controls = Controls("0xFFFFFFFF");
        var (savedSnapshot, savedInventory, savedGovernor) = (App.Operations.ProcessSnapshot, App.Live.Inventory, App.Operations.Governor);
        Dictionary<string, JsonElement>? requested = null;
        App.Operations.ProcessSnapshot = new(identity, Read(0xfffffffeu), TwoCcds(), controls);
        App.Operations.Review = desired =>
        {
            requested = desired;
            return new(new() { SchemaVersion = 1, OperationId = "op", Owner = Owner, Identity = identity, Original = desired.Keys.ToDictionary(name => name, name => controls[name]), Desired = desired, TopologyHash = "topology" }, "preview.json", "hash", "journal.json");
        };
        async Task<ProcessControlsViewModel> Open()
        {
            var page = new ProcessControlsViewModel();
            await page.RefreshCommand.ExecuteAsync(null);
            page.SelectedProcess = page.Processes.Single();
            await (Task)typeof(ProcessControlsViewModel).GetField("_readTask", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(page)!;
            return page;
        }
        App.Live.Inventory = new ProcessInventory { Processes = [new ProcessItem { Pid = 123, Name = "game.exe", Category = "game" }] };
        try
        {
            var page = await Open();
            page.SetHardAffinity = true;
            foreach (var cpu in page.Cpus) cpu.Selected = cpu.Cpu.Index < 16;
            await page.PreviewCommand.ExecuteAsync(null);
            check(Mask(requested) == 0xFFFF,
                "Restricting a game to the ticked CPUs 0-15 (CPUs 16-31 off) reviews exactly those CPUs, not the CPUs it runs on now" + " | reviewed mask 0x" + Mask(requested).ToString("X") + " | " + page.Status + " " + page.Detail);
            check(page.ReviewSummary.Contains("CPU affinity: group 0 · 0xFFFFFFFF → group 0 · 0xFFFF", StringComparison.Ordinal),
                "The review shows the game moving from all 32 CPUs to CPUs 0-15" + " | " + page.ReviewSummary);

            page = await Open();
            page.SetHardAffinity = true;
            check(Ticked(page).SequenceEqual(Enumerable.Range(0, 32)) && ProcessTarget.ParseMask(page.AffinityMask) == 0xFFFFFFFF,
                "Turning on Restrict ticks the CPUs the app may use now, so the list matches its current affinity" + " | ticked " + string.Join(",", Ticked(page)));
            foreach (var cpu in page.Cpus.Where(cpu => cpu.Cpu.Index >= 16)) cpu.Selected = false;
            check(ProcessTarget.ParseMask(page.AffinityMask) == 0xFFFF && page.CanPreview, "Unticking CPUs 16-31 changes the mask to CPUs 0-15 right away" + " | " + page.AffinityMask);
            foreach (var cpu in page.Cpus) cpu.Selected = false;
            check(page.AffinityMask == "" && !page.CanPreview, "With no CPU ticked there is no restriction to review" + " | " + page.AffinityMask);
            page.AffinityMask = "0xF0";
            check(Ticked(page).SequenceEqual([4, 5, 6, 7]) && page.CanPreview, "Typing a mask ticks the CPUs it names" + " | ticked " + string.Join(",", Ticked(page)));
            page.AffinityMask = "0x100000000";
            check(!page.CanPreview && Ticked(page).SequenceEqual([4, 5, 6, 7]), "A mask naming a CPU outside the app's processor group can't be reviewed" + " | " + page.AffinityMask);

            page = await Open();
            page.SelectedCpuMode = page.CpuModes.Single(mode => mode.Kind == "logical");
            foreach (var cpu in page.Cpus) cpu.Selected = cpu.Cpu.Index < 8;
            page.SetHardAffinity = true;
            check(Ticked(page).SequenceEqual(Enumerable.Range(0, 8)) && ProcessTarget.ParseMask(page.AffinityMask) == 0xFFFFFFFF,
                "With preferred logical CPUs chosen, turning on Restrict keeps those ticks and leaves the Restrict mask at the app's current CPUs" + " | ticked " + string.Join(",", Ticked(page)) + " mask " + page.AffinityMask);
            page.UseCheckedAffinityCommand.Execute(null);
            check(ProcessTarget.ParseMask(page.AffinityMask) == 0xFF, "Use selected CPUs copies the preferred CPUs into the Restrict mask" + " | " + page.AffinityMask);
            page.Cpus.Single(cpu => cpu.Cpu.Index == 8).Selected = true;
            page.AffinityMask = "0xF0";
            check(Ticked(page).SequenceEqual(Enumerable.Range(0, 9)) && ProcessTarget.ParseMask(page.AffinityMask) == 0xF0 && page.CanPreview,
                "With preferred logical CPUs, ticking a CPU leaves the Restrict mask alone and typing a mask leaves the ticks alone" + " | ticked " + string.Join(",", Ticked(page)) + " mask " + page.AffinityMask);

            page = await Open();
            page.SelectedCpuMode = page.CpuModes.Single(mode => mode.Kind == "logical");
            foreach (var cpu in page.Cpus) cpu.Selected = cpu.Cpu.Index < 8;
            page.SelectedCpuMode = page.CpuModes.Single(mode => mode.Kind == "unchanged");
            page.SetHardAffinity = true;
            check(Ticked(page).SequenceEqual(Enumerable.Range(0, 32)) && ProcessTarget.ParseMask(page.AffinityMask) == 0xFFFFFFFF,
                "CPUs ticked in another CPU mode don't become the Restrict mask: turning on Restrict ticks the CPUs the app may use now" + " | ticked " + string.Join(",", Ticked(page)) + " mask " + page.AffinityMask);

            var rule = GovernorChecks.Rule("0123456789abcdef0123456789abcdef", "Game rule", identity.ExecutablePath, true) with
            {
                Controls = new() { ["affinity"] = Value(new AffinityState(0, "0xFF00")) },
                CpuSelection = new CpuSelection { Kind = "logical", TopologyHash = CpuSelection.Fingerprint(TwoCcds()), Processors = [new(0, 0), new(0, 1)] },
            };
            App.Operations.Governor = new(new PolicySummary(false, "missing", false, 1, 1, null), new PolicyWorkerStatus(null, false, null), [rule], new());
            page = await Open();
            await page.RefreshRulesCommand.ExecuteAsync(null);
            page.SelectedRule = page.Rules.Single();
            await page.EditRuleCommand.ExecuteAsync(null);
            check(page.SetHardAffinity && ProcessTarget.ParseMask(page.AffinityMask) == 0xFF00 && Ticked(page).SequenceEqual([0, 1]),
                "Edit rule keeps the rule's saved affinity and its saved preferred CPUs as they were" + " | mask " + page.AffinityMask + " ticked " + string.Join(",", Ticked(page)) + " | " + page.Status + " " + page.Detail);
            page.Cpus.Single(cpu => cpu.Cpu.Index == 2).Selected = true;
            check(ProcessTarget.ParseMask(page.AffinityMask) == 0xFF00 && Ticked(page).SequenceEqual([0, 1, 2]),
                "Ticking another preferred CPU on that rule leaves its separate affinity as saved" + " | mask " + page.AffinityMask + " ticked " + string.Join(",", Ticked(page)));
            page.AffinityMask = "0xF000";
            check(Ticked(page).SequenceEqual([0, 1, 2]) && page.CanPreview, "Typing a new affinity for that rule leaves its preferred CPUs as ticked" + " | ticked " + string.Join(",", Ticked(page)));

            App.Operations.ProcessSnapshot = new(identity, Read(0xfffffffeu), TwoCcds().Select(cpu => cpu.Index == 15 ? cpu with { Allocated = true } : cpu).ToArray(), controls);
            App.Operations.Governor = new(new PolicySummary(false, "missing", false, 1, 1, null), new PolicyWorkerStatus(null, false, null),
                [GovernorChecks.Rule("fedcba9876543210fedcba9876543210", "Affinity rule", identity.ExecutablePath, true) with { Controls = new() { ["affinity"] = Value(new AffinityState(0, "0xFF00")) } }], new());
            page = await Open();
            await page.RefreshRulesCommand.ExecuteAsync(null);
            page.SelectedRule = page.Rules.Single();
            await page.EditRuleCommand.ExecuteAsync(null);
            page.Cpus.Single(cpu => cpu.Cpu.Index == 7).Selected = true;
            check(ProcessTarget.ParseMask(page.AffinityMask) == 0xFF80 && Ticked(page).SequenceEqual(Enumerable.Range(7, 8)),
                "Ticking a CPU on a saved rule keeps the rule's CPU that another app reserved, which can't be ticked here" + " | mask " + page.AffinityMask + " ticked " + string.Join(",", Ticked(page)));
        }
        finally { (App.Operations.ProcessSnapshot, App.Live.Inventory, App.Operations.Governor) = (savedSnapshot, savedInventory, savedGovernor); App.Operations.Review = null; }
    }

    internal static async Task GamesAsync(Action<bool, string> check)
    {
        var launcher = new RunningProcess(77, "7", @"C:\Launcher\launcher.exe");
        var savedSnapshot = App.Operations.ProcessSnapshot;
        Dictionary<string, JsonElement>? requested = null;
        App.Operations.GameReview = controls =>
        {
            requested = controls;
            return new(new()
            {
                SchemaVersion = 1, OperationId = "op", Owner = Owner, Launcher = launcher, LauncherHash = new string('A', 64), GamePath = @"C:\Games\game.exe", GameHash = new string('B', 64),
                GameLength = 1, GameModifiedAtUtc = DateTime.UnixEpoch, TopologyHash = new string('C', 64), OriginalAffinity = new(0, "0xFFFFFFFF"), Controls = new(controls),
                OriginalLaunchSettings = new() { ImageKeyExisted = false, OptionsKeyExisted = false, Values = [] }, LauncherChanges = null, AcceptLauncherScope = true,
            }, "preview.json", "hash", "session");
        };
        GameSessionViewModel Open(LogicalCpu[] topology, string mask)
        {
            App.Operations.ProcessSnapshot = new(launcher, Read(0xfffffffeu), topology, Controls(mask));
            var games = new GameSessionViewModel { GamePath = @"C:\Games\game.exe" };
            games.SelectedLauncher = new CpuProcessChoice(77, "launcher.exe");
            return games;
        }
        string Offered(GameSessionViewModel games) => string.Join(", ", games.CoreChoices.Select(choice => choice.Label + " " + choice.Affinity.Mask));
        try
        {
            var games = Open(TwoCcds(), "0xFFFFFFFF");
            var io = games.Settings.Single(setting => setting.Name == "ioPriority");
            check(io.Options.Any(option => option.Value?.GetInt32() == 3), "The Games tab offers High I/O priority for the game" + " | offered: " + string.Join(", ", io.Options.Select(option => option.Label)));
            var first = games.CoreChoices.FirstOrDefault(choice => ProcessTarget.ParseMask(choice.Affinity.Mask) == 0xFFFF);
            var second = games.CoreChoices.FirstOrDefault(choice => ProcessTarget.ParseMask(choice.Affinity.Mask) == 0xFFFF0000);
            check(first is not null && second is not null && games.SelectedCores == games.CoreChoices[0] && ProcessTarget.ParseMask(games.CoreChoices[0].Affinity.Mask) == 0xFFFFFFFF,
                "On a CPU with two last-level cache groups, CPU cores offers each group, and all cores stay the default" + " | offered: " + Offered(games));
            check(first!.Label == "Cache group 1 (CPUs 0-15)" && second!.Label == "Cache group 2 (CPUs 16-31)", "Each cache group names its CPUs" + " | offered: " + Offered(games));
            games.SelectedCores = first;
            io.Selected = io.Options.Single(option => option.Value?.GetInt32() == 3);
            games.AcceptLauncherScope = true;
            await games.PreviewCommand.ExecuteAsync(null);
            check(requested is not null && requested["ioPriority"].GetInt32() == 3 && Mask(requested) == 0xFFFF && games.CanStart,
                "Reviewing High I/O with the first cache group sends exactly those settings and Start can be pressed" + " | " + games.Status + " " + games.Detail);
            check(games.ReviewSummary.Contains("I/O priority: High", StringComparison.Ordinal) && games.ReviewSummary.Contains("High I/O priority is set on the game once it starts and stays until you select Stop and restore.", StringComparison.Ordinal),
                "The review says when High I/O priority takes effect and how it comes back" + " | " + games.ReviewSummary);

            games = Open(TwoCcds(), "0xFFFF");
            check(games.CoreChoices.Count == 1, "When the launcher may only use one cache group, CPU cores offers no other group" + " | offered: " + Offered(games));
            games = Open(Hybrid(), "0xFF");
            check(games.CoreChoices.Select(choice => choice.Label).SequenceEqual(["All allowed cores", "Performance cores", "Efficiency cores"]),
                "A CPU with one cache keeps its performance and efficiency core choices" + " | offered: " + Offered(games));
        }
        finally { App.Operations.ProcessSnapshot = savedSnapshot; App.Operations.GameReview = null; }
    }
}
