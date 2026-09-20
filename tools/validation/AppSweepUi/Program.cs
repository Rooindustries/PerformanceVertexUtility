using System.Reflection;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

var count = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    count++;
    Console.WriteLine("PASS " + message);
}

ControlRead Read<T>(T value) => ControlRead.From(value);
var error = new ApiError("fixture", "win32", 5, "read", "Controlled affinity read failure");
Dictionary<string, ControlRead> Controls(ControlRead cpuSets, ControlRead affinity) => new()
{
    ["cpuPriority"] = Read("Normal"),
    ["ioPriority"] = Read(2),
    ["gpuPriority"] = Read(2),
    ["memoryPriority"] = Read(5),
    ["executionQoS"] = Read(new PowerThrottling(0, 0)),
    ["priorityBoost"] = Read(true),
    ["cpuSets"] = cpuSets,
    ["affinity"] = affinity,
};
ProcessControlSnapshot Snapshot(ControlRead cpuSets, ControlRead affinity) => new(
    new RunningProcess(123, "1", @"C:\Fixture.exe"), Read(0xfffffffeu), [], Controls(cpuSets, affinity));
async Task ReadProcess(ProcessControlsViewModel model)
{
    var method = typeof(ProcessControlsViewModel).GetMethod("ReadProcessAsync", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("ReadProcessAsync is missing.");
    await ((Task?)method.Invoke(model, [new CpuProcessChoice(123, "Fixture"), 0])
        ?? throw new InvalidOperationException("ReadProcessAsync did not return a task."));
}

if (args is [] or ["process"])
{
    App.Operations.ProcessSnapshot = Snapshot(Read(Array.Empty<uint>()), ControlRead.Failed(error));
    var process = new ProcessControlsViewModel();
    await ReadProcess(process);
    Check(process.Status == "Controls for Fixture" && process.Controls.Count == 6 && process.Controls.All(row => row.Available),
        "A failed affinity read preserves neighboring process controls");
    Check(process.Detail.Contains("Hard affinity: unavailable", StringComparison.OrdinalIgnoreCase),
        "Process detail identifies only the failed affinity read as unavailable");
    process.Controls[0].Selected = process.Controls[0].Options[1];
    Check(process.CanPreview, "A readable process control remains reviewable beside a failed affinity read");
    process.Controls[0].Selected = process.Controls[0].Options[0];
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(process.CanPreview, "A legitimate empty CPU-set read remains available for a new CPU selection");
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "unchanged");
    process.SetHardAffinity = true;
    Check(!process.CanPreview, "An unavailable affinity read cannot be requested for review");

    App.Operations.ProcessSnapshot = Snapshot(new ControlRead(true, null, null), Read(new AffinityState(0, "0x3")));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(process.Status == "Controls for Fixture" && process.Detail.Contains("Preferred CPUs: unavailable", StringComparison.OrdinalIgnoreCase),
        "A missing CPU-set value preserves the readable affinity result");
    Check(!process.CanPreview, "An unavailable CPU-set read cannot be requested for review");

    var affinityValue = Read(new AffinityState(0, "0x3"));
    App.Operations.ProcessSnapshot = Snapshot(Read(Array.Empty<uint>()), new ControlRead(false, affinityValue.Value, null));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SetHardAffinity = true;
    Check(!process.CanPreview && process.Detail.Contains("Hard affinity: unavailable", StringComparison.OrdinalIgnoreCase),
        "Known false blocks affinity even when a value is present");

    var cpuSetValue = Read(Array.Empty<uint>());
    App.Operations.ProcessSnapshot = Snapshot(new ControlRead(true, cpuSetValue.Value, error), Read(new AffinityState(0, "0x3")));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(!process.CanPreview && process.Detail.Contains("Preferred CPUs: unavailable", StringComparison.OrdinalIgnoreCase),
        "An attached error blocks CPU selection even when known and value are favorable");
}

if (args is [] or ["startup"])
{
    App.Live.Classification = null;
    App.Live.LastError = "Controlled classification failure";
    var startup = new StartupServicesViewModel();
    await startup.InitializeAsync();
    Check(!startup.IsReady && startup.ErrorMessage == "Controlled classification failure",
        "A null process classification remains unavailable with the backend error");
    Check(typeof(StartupServicesViewModel).GetProperty("RetryCommand") is not null,
        "The unavailable startup state exposes a retry command");

    App.Live.Classification = new ProcessClassification { Processes = [] };
    App.Live.LastError = null;
    await startup.ReloadAsync();
    Check(startup.IsReady && startup.BackgroundCount == 0 && startup.LoadSummary == "No background processes reported.",
        "A successful empty classification is distinct from an unavailable read");

    App.Live.Classification = new ProcessClassification
    {
        Processes =
        [
            new ProcessItem { Pid = 10, Name = "fixture-launcher", Category = "launcher", WorkingSetBytes = 1024 },
            new ProcessItem { Pid = 11, Name = "fixture-background", Category = "backgroundApp", WorkingSetBytes = 2048, Protected = true },
        ],
    };
    await startup.ReloadAsync();
    Check(startup.IsReady && startup.BackgroundCount == 2 && startup.LauncherCount == 1 && startup.ProtectedCount == 1 && startup.BackgroundRows.Count == 2,
        "A populated classification projects its independent startup counts");
}

Console.WriteLine($"Completed {count} app sweep UI checks.");
