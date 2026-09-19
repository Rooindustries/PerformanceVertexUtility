using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public sealed record ControlOption(string Label, JsonElement? Value)
{
    public override string ToString() => Label;
}

public partial class ProcessControlRow : ObservableObject
{
    public string Name { get; }
    public string Label { get; }
    [ObservableProperty] private string _current = "";
    [ObservableProperty] private bool _available;
    public ControlOption[] Options { get; }
    [ObservableProperty] private ControlOption _selected;
    public ProcessControlRow(string name, string label, ControlRead current, ControlOption[] options)
    {
        Name = name; Label = label;
        Options = new[] { new ControlOption("Keep current", null) }.Concat(options).ToArray();
        _selected = Options[0];
        Update(current);
    }
    public void Update(ControlRead current)
    {
        Available = current.Known && current.Error is null && current.Value is not null;
        Current = Available ? "Current: " + ProcessControlsViewModel.Describe(Name, current.Require()) : "Unavailable: " + (current.Error?.Message ?? "The control could not be read.");
    }
}

public partial class LogicalCpuChoice : ObservableObject
{
    public LogicalCpu Cpu { get; }
    public string Label => $"G{Cpu.Group} · CPU {Cpu.Index}";
    public string Detail => $"Core {Cpu.Core} · cache {Cpu.Cache}\nClass {Cpu.Efficiency}" + (Cpu.Parked ? " · parked" : "");
    [ObservableProperty] private bool _selected;
    public LogicalCpuChoice(LogicalCpu cpu) => Cpu = cpu;
}

public sealed record CpuMode(string Kind, string Label)
{
    public override string ToString() => Label;
}
public sealed record TopologyChoice(ushort Group, byte Index)
{
    public override string ToString() => $"Group {Group} · {Index}";
}
public sealed record SavedRuleChoice(SavedProcessRule Rule)
{
    public override string ToString() => Rule.Name + (Rule.Enabled ? " · enabled" : " · paused");
}

public partial class ProcessControlsViewModel : ObservableObject
{
    public ObservableCollection<CpuProcessChoice> Processes { get; } = new();
    public ObservableCollection<ProcessControlRow> Controls { get; } = new();
    public ObservableCollection<LogicalCpuChoice> Cpus { get; } = new();
    public ObservableCollection<TopologyChoice> TopologyChoices { get; } = new();
    public ObservableCollection<SavedRuleChoice> Rules { get; } = new();
    public CpuMode[] CpuModes { get; } = [new("unchanged", "Keep current"), new("windowsDefault", "Windows default"), new("logical", "Choose logical CPUs"),
        new("all", "All logical CPUs"), new("performance", "Performance cores"), new("efficiency", "Efficiency cores"), new("core", "One physical core"), new("cache", "Shared cache group"), new("numa", "NUMA node")];
    [ObservableProperty] private CpuProcessChoice? _selectedProcess;
    [ObservableProperty] private CpuMode _selectedCpuMode;
    [ObservableProperty] private TopologyChoice? _selectedTopology;
    [ObservableProperty] private SavedRuleChoice? _selectedRule;
    [ObservableProperty] private bool _oneThreadPerCore;
    [ObservableProperty] private bool _setHardAffinity;
    [ObservableProperty] private string _affinityMask = "";
    [ObservableProperty] private string _affinityLabel = "Hard-affinity CPU mask";
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _restoreAvailable;
    [ObservableProperty] private bool _hasLegacyCpuRecovery;
    [ObservableProperty] private bool _matchFilename;
    [ObservableProperty] private bool _pinExecutable;
    [ObservableProperty] private string _ruleName = "";
    [ObservableProperty] private string _status = "Choose an application to inspect its controls.";
    [ObservableProperty] private string _detail = "Changes use Windows process controls. Applications that deny access remain unchanged.";
    [ObservableProperty] private string _reviewSummary = "";
    [ObservableProperty] private string _workerSummary = "Saved rules have not been loaded.";
    [ObservableProperty] private string _ruleDetail = "";
    [ObservableProperty] private string _logonLabel = "Enable at sign-in";
    private ProcessControlSnapshot? _snapshot;
    private ProcessControlReview? _review;
    private string? _journal;
    private string? _editingRuleId;
    private PolicyWorkerRegistration? _worker;
    private int _selectionVersion;
    private ushort _affinityGroup;
    private Task _readTask = Task.CompletedTask;
    private bool _observing;

    public ProcessControlsViewModel() => _selectedCpuMode = CpuModes[0];
    public bool CanEdit => !Busy && !RestoreAvailable;
    public bool HasProcess => _snapshot is not null;
    public bool ShowLogicalCpus => SelectedCpuMode.Kind == "logical" || SetHardAffinity;
    public bool ShowTopology => SelectedCpuMode.Kind is "core" or "cache" or "numa";
    public bool CanPreview => CanEdit && _snapshot is not null && (Controls.Any(row => row.Available && row.Selected.Value is not null) || SelectedCpuMode.Kind != "unchanged" || SetHardAffinity);
    public bool CanApply => !Busy && _review is not null && !RestoreAvailable;
    public bool CanRestore => !Busy && RestoreAvailable;
    public bool HasReview => _review is not null;
    public bool CanSaveRule => CanApply && !string.IsNullOrWhiteSpace(RuleName);
    public bool CanManageRule => !Busy && SelectedRule is not null;
    public bool CanManageWorker => !Busy;

    partial void OnBusyChanged(bool value) => NotifyState();
    partial void OnRestoreAvailableChanged(bool value) => NotifyState();
    partial void OnRuleNameChanged(string value) => OnPropertyChanged(nameof(CanSaveRule));
    partial void OnOneThreadPerCoreChanged(bool value) => Invalidate();
    partial void OnSetHardAffinityChanged(bool value) => Invalidate();
    partial void OnAffinityMaskChanged(string value) => Invalidate();
    partial void OnSelectedTopologyChanged(TopologyChoice? value) => Invalidate();
    partial void OnSelectedCpuModeChanged(CpuMode value)
    {
        TopologyChoices.Clear();
        if (_snapshot is not null && ShowTopology)
            foreach (var item in _snapshot.Topology.Select(cpu => new TopologyChoice(cpu.Group, value.Kind == "core" ? cpu.Core : value.Kind == "cache" ? cpu.Cache : cpu.Numa)).Distinct()) TopologyChoices.Add(item);
        SelectedTopology = TopologyChoices.FirstOrDefault();
        Invalidate();
    }
    partial void OnSelectedProcessChanged(CpuProcessChoice? value) { Invalidate(); _readTask = ReadProcessAsync(value, ++_selectionVersion); }
    partial void OnSelectedRuleChanged(SavedRuleChoice? value)
    {
        RuleDetail = value is null ? "" : value.Rule.ExecutablePath + "\n" + string.Join(", ", value.Rule.Controls.Keys.Select(Label))
            + (value.Rule.CpuSelection is null ? "" : " · CPU selection: " + value.Rule.CpuSelection.Kind);
        NotifyState();
    }

    public async Task InitializeAsync()
    {
        await RefreshAsync();
        try
        {
            HasLegacyCpuRecovery = App.Operations.FindLastJournal("cpu") is not null;
            _journal = App.Operations.FindLastJournal("process");
            if (_journal is not null)
            {
                var state = OperationFiles.Read<ProcessControlJournal>(_journal);
                RestoreAvailable = state.Status is not ("restored" or "expired");
                if (RestoreAvailable) { Status = "A previous process change has recovery data."; Detail = "Restore it before making another direct change. Saved rules are managed separately."; }
            }
            await RefreshRulesAsync();
        }
        catch (Exception error) { Status = "Saved controls need attention."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (!CanEdit) return;
        Busy = true;
        try
        {
            var inventory = await App.Live.GetProcessInventoryAsync();
            if (inventory?.Processes is null) throw new InvalidOperationException(App.Live.LastError ?? "The process list is unavailable.");
            SelectedProcess = null;
            Processes.Clear();
            foreach (var process in inventory.Processes.Where(item => item.Pid > 0 && item.Pid != Environment.ProcessId && item.Category != "windowsCore" && !item.Protected && !item.Blocked).OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase))
                Processes.Add(new(process.Pid, process.Name ?? "Process"));
        }
        catch (Exception error) { Status = "Couldn't refresh applications."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private async Task ReadProcessAsync(CpuProcessChoice? process, int version)
    {
        _snapshot = null; Controls.Clear(); Cpus.Clear(); _editingRuleId = null; SelectedCpuMode = CpuModes[0]; SetHardAffinity = false; OneThreadPerCore = false;
        if (process is null) { NotifyState(); return; }
        Busy = true;
        try
        {
            var snapshot = await App.Operations.ReadProcessControlsAsync(process.Id);
            if (version != _selectionVersion) return;
            if (snapshot.Protection.Require().GetUInt32() != 0xfffffffe) throw new InvalidOperationException("Windows reports a protected application. Choose another process.");
            _snapshot = snapshot;
            var affinity = snapshot.Controls["affinity"];
            if (affinity.Known && affinity.Error is null)
            {
                var value = affinity.Require().Deserialize<AffinityState>(OperationFiles.Json)!;
                _affinityGroup = value.Group;
                AffinityMask = value.Mask;
                AffinityLabel = "Hard-affinity mask · group " + value.Group;
            }
            foreach (var name in new[] { "cpuPriority", "ioPriority", "gpuPriority", "memoryPriority", "executionQoS", "priorityBoost" })
            {
                var row = new ProcessControlRow(name, Label(name), snapshot.Controls[name], Options(name));
                row.PropertyChanged += Changed;
                Controls.Add(row);
            }
            foreach (var cpu in snapshot.Topology.OrderBy(cpu => cpu.Group).ThenBy(cpu => cpu.Index))
            {
                var choice = new LogicalCpuChoice(cpu);
                choice.PropertyChanged += Changed;
                Cpus.Add(choice);
            }
            RuleName = Path.GetFileNameWithoutExtension(snapshot.Identity.ExecutablePath);
            Status = "Controls for " + process.Name;
            Detail = "Current CPU Sets: " + Describe("cpuSets", snapshot.Controls["cpuSets"].Require()) + ". Current hard affinity: " + Describe("affinity", snapshot.Controls["affinity"].Require()) + ".";
        }
        catch (Exception error) { if (version == _selectionVersion) { Status = "Process controls are unavailable."; Detail = error.Message; } }
        finally { if (version == _selectionVersion) Busy = false; NotifyState(); }
    }

    private void Changed(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == "Selected") Invalidate(); }

    private (Dictionary<string, JsonElement> Controls, CpuSelection? Selection) Desired()
    {
        var snapshot = _snapshot ?? throw new InvalidOperationException("Choose a running process.");
        var controls = Controls.Where(row => row.Available && row.Selected.Value is not null).ToDictionary(row => row.Name, row => row.Selected.Value!.Value);
        if (controls.TryGetValue("executionQoS", out var qos))
            controls["executionQoS"] = Value(snapshot.Controls["executionQoS"].Require().Deserialize<PowerThrottling>(OperationFiles.Json)!.WithExecutionMode(qos.GetString()!));
        var selected = Cpus.Where(cpu => cpu.Selected && cpu.Cpu.Available).Select(cpu => cpu.Cpu).ToArray();
        if (SetHardAffinity)
        {
            controls["affinity"] = Value(new AffinityState(_affinityGroup, AffinityMask.Trim()));
        }
        CpuSelection? selection = null;
        if (SelectedCpuMode.Kind != "unchanged")
        {
            selection = new CpuSelection
            {
                Kind = SelectedCpuMode.Kind, TopologyHash = CpuSelection.Fingerprint(snapshot.Topology),
                Processors = SelectedCpuMode.Kind == "logical" ? selected.Select(cpu => new CpuCoordinate(cpu.Group, cpu.Index)).ToArray() : null,
                Group = ShowTopology ? SelectedTopology?.Group : null, Index = ShowTopology ? SelectedTopology?.Index : null,
                OneThreadPerCore = SelectedCpuMode.Kind != "windowsDefault" && OneThreadPerCore,
            };
            selection.Resolve(snapshot.Topology);
        }
        return (controls, selection);
    }

    [RelayCommand]
    private void UseCheckedAffinity()
    {
        try
        {
            var selected = Cpus.Where(cpu => cpu.Selected && cpu.Cpu.Available).Select(cpu => cpu.Cpu).ToArray();
            if (selected.Length == 0 || selected.Any(cpu => cpu.Group != _affinityGroup)) throw new InvalidOperationException("Select CPUs in the process's current processor group for hard affinity.");
            AffinityMask = "0x" + selected.Aggregate(0ul, (mask, cpu) => mask | (1ul << cpu.Index)).ToString("X");
        }
        catch (Exception error) { Status = "Couldn't build the hard-affinity mask."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (!CanPreview) return;
        Busy = true;
        try
        {
            var desired = Desired();
            _review = await App.Operations.PreviewControlsAsync(SelectedProcess!.Id, desired.Controls, desired.Selection);
            ReviewSummary = string.Join("\n", _review.Plan.Desired.Select(pair => Label(pair.Key) + ": " + Describe(pair.Key, _review.Plan.Original[pair.Key].Require()) + " → " + Describe(pair.Key, pair.Value)));
            Status = "Review the requested controls.";
            Detail = "Apply once changes this process instance. Save rule applies to matching launches while the rule worker runs.";
        }
        catch (Exception error) { Invalidate(); Status = "Couldn't prepare these controls."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (!CanApply || _review is null) return;
        Busy = true;
        try { _journal = _review.JournalPath; ShowResult(await App.Operations.ApplyControlsAsync(_review)); Invalidate(); }
        catch (Exception error) { Status = "The change was not confirmed."; Detail = error.Message; RestoreAvailable = _journal is not null && File.Exists(_journal); }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RestoreAsync()
    {
        if (!CanRestore || _journal is null) return;
        Busy = true;
        try { ShowResult(await App.Operations.RestoreControlsAsync(_journal)); Invalidate(); }
        catch (Exception error) { Status = "Recovery needs attention."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void ShowResult(ProcessControlJournal result)
    {
        RestoreAvailable = result.Status is not ("restored" or "expired");
        Status = result.Status switch { "applied" => "Process controls applied and read back.", "restored" => "Original controls restored.", "expired" => "The process exited; its instance controls have ended.", _ => "Some controls need recovery." };
        Detail = string.Join("\n", result.Changes.Select(change => Label(change.Name) + ": " + change.Status + (change.Error is null ? "" : " · " + change.Error)));
    }

    [RelayCommand]
    private async Task SaveRuleAsync()
    {
        if (!CanSaveRule || _review is null) return;
        Busy = true;
        try
        {
            var desired = Desired();
            var path = _review.Plan.Identity.ExecutablePath;
            var rule = new SavedProcessRule
            {
                SchemaVersion = 1, RuleId = _editingRuleId ?? Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(),
                Name = RuleName.Trim(), Enabled = true, MatchMode = MatchFilename ? "filename" : "path", ExecutablePath = path,
                ExecutableHash = PinExecutable ? await Task.Run(() => OperationFiles.HashFile(path)) : null, Controls = desired.Controls, CpuSelection = desired.Selection,
                AffinityTopologyHash = desired.Controls.ContainsKey("affinity") ? _review.Plan.TopologyHash : null,
            };
            var saved = await App.Operations.SaveRuleAsync(rule);
            _editingRuleId = saved.RuleId;
            Status = "Rule saved. Starting its worker…";
            _worker = await App.Operations.PolicyWorkerAsync("Start");
            await RefreshRulesAsync();
            Status = "Rule saved; the worker is running.";
            Detail = "Rules continue after this window closes. Conflicting changes suspend that process instance for review.";
            Invalidate();
        }
        catch (Exception error) { Status = "Saved rules need attention."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RefreshRulesAsync()
    {
        var selected = SelectedRule?.Rule.RuleId;
        var rules = await App.Operations.ReadRulesAsync();
        Rules.Clear();
        foreach (var rule in rules) Rules.Add(new(rule));
        SelectedRule = Rules.FirstOrDefault(item => item.Rule.RuleId == selected) ?? Rules.FirstOrDefault();
        _worker = await App.Operations.PolicyWorkerAsync("Status");
        ShowWorker(_worker.Worker);
        LogonLabel = _worker.RunAtLogon ? "Disable at sign-in" : "Enable at sign-in";
    }

    private void ShowWorker(PolicyWorkerStatus state)
    {
        WorkerSummary = state.HostRunning == true ? "Worker running · " + state.State?.Instances.Count(instance => instance.Status == "active") + " active instances"
            : state.HostRunning == false ? "Worker stopped" : "Worker state is unknown";
        if (state.Error is not null) WorkerSummary += "\n" + state.Error;
        var issues = (state.State?.Errors ?? new()).Concat(state.State?.Instances.Where(instance => instance.Status == "conflict").Select(instance => instance.Process.ExecutablePath + ": " + instance.Error) ?? Enumerable.Empty<string>());
        if (issues.Any()) WorkerSummary += "\n" + string.Join("\n", issues);
    }

    public async Task ObserveAsync()
    {
        if (Busy || _observing) return;
        _observing = true;
        var version = _selectionVersion;
        try
        {
            var worker = await App.Operations.ReadPolicyStatusAsync();
            if (Busy || version != _selectionVersion) return;
            ShowWorker(worker);
            if (_snapshot is null) return;
            var fresh = await App.Operations.ReadProcessControlsAsync(_snapshot.Identity.ProcessId);
            if (Busy || version != _selectionVersion) return;
            _snapshot.Identity.Verify(fresh.Identity);
            if (CpuSelection.Fingerprint(_snapshot.Topology) != CpuSelection.Fingerprint(fresh.Topology)) throw new InvalidOperationException("CPU topology changed. Refresh the application before reviewing another selection.");
            if (_review is not null && _review.Plan.Original.Any(pair => !fresh.Controls[pair.Key].Known || fresh.Controls[pair.Key].Error is not null ||
                !ProcessTarget.Equivalent(pair.Key, pair.Value.Require(), fresh.Controls[pair.Key].Require())))
            {
                Invalidate();
                Status = "Controls changed after review. Preview again.";
            }
            _snapshot = fresh;
            foreach (var row in Controls) row.Update(fresh.Controls[row.Name]);
            NotifyState();
        }
        catch (Exception error)
        {
            if (Busy || version != _selectionVersion) return;
            _snapshot = null;
            Invalidate();
            Status = "Live controls need refreshing.";
            Detail = error.Message;
        }
        finally { _observing = false; }
    }

    [RelayCommand]
    private async Task ToggleRuleAsync() => await ManageRuleAsync(false);
    [RelayCommand]
    private async Task EditRuleAsync()
    {
        if (!CanManageRule || !CanEdit) return;
        var rule = SelectedRule!.Rule;
        try
        {
            var process = Processes.FirstOrDefault(item => string.Equals(Path.GetFileNameWithoutExtension(item.Name), Path.GetFileNameWithoutExtension(rule.ExecutablePath), StringComparison.OrdinalIgnoreCase));
            if (process is null) throw new InvalidOperationException("Start the rule's application and refresh the process list to review changed controls.");
            SelectedProcess = process;
            await _readTask;
            if (_snapshot is null || rule.MatchMode == "path" && !string.Equals(_snapshot.Identity.ExecutablePath, rule.ExecutablePath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Choose a running instance from the saved executable path before editing this rule.");
            _editingRuleId = rule.RuleId;
            RuleName = rule.Name;
            MatchFilename = rule.MatchMode == "filename";
            PinExecutable = rule.ExecutableHash is not null;
            foreach (var row in Controls)
            {
                if (!rule.Controls.TryGetValue(row.Name, out var desired)) { row.Selected = row.Options[0]; continue; }
                if (row.Name == "executionQoS") desired = Value(desired.Deserialize<PowerThrottling>(OperationFiles.Json)!.ExecutionMode);
                row.Selected = row.Options.Single(option => option.Value?.GetRawText() == desired.GetRawText());
            }
            SelectedCpuMode = CpuModes.Single(mode => mode.Kind == (rule.CpuSelection?.Kind ?? "unchanged"));
            OneThreadPerCore = rule.CpuSelection?.OneThreadPerCore == true;
            if (ShowTopology) SelectedTopology = TopologyChoices.SingleOrDefault(item => item.Group == rule.CpuSelection?.Group && item.Index == rule.CpuSelection.Index);
            foreach (var cpu in Cpus) cpu.Selected = rule.CpuSelection?.Processors?.Contains(new(cpu.Cpu.Group, cpu.Cpu.Index)) == true;
            SetHardAffinity = rule.Controls.ContainsKey("affinity");
            if (SetHardAffinity)
            {
                var affinity = rule.Controls["affinity"].Deserialize<AffinityState>(OperationFiles.Json)!;
                if (affinity.Group != _affinityGroup) throw new InvalidOperationException("The process is in another processor group. Review its hard affinity before saving.");
                AffinityMask = affinity.Mask;
            }
            Status = "Editing " + rule.Name;
            Detail = "Change the controls, then preview and save to replace this rule.";
        }
        catch (Exception error) { Status = "This rule needs review."; Detail = error.Message; }
    }
    [RelayCommand]
    private async Task DeleteRuleAsync() => await ManageRuleAsync(true);
    private async Task ManageRuleAsync(bool delete)
    {
        if (!CanManageRule) return;
        Busy = true;
        try
        {
            if (delete) await App.Operations.DeleteRuleAsync(SelectedRule!.Rule.RuleId);
            else await App.Operations.SaveRuleAsync(SelectedRule!.Rule with { Enabled = !SelectedRule.Rule.Enabled });
            await RefreshRulesAsync();
            Status = delete ? "Rule deleted." : "Rule updated.";
            Detail = "The worker restores controls it still owns when a rule is paused or deleted.";
        }
        catch (Exception error) { Status = "Couldn't update the rule."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task WorkerAsync(string action)
    {
        if (Busy) return;
        Busy = true;
        try
        {
            if (action == "Logon") action = _worker?.RunAtLogon == true ? "DisableLogon" : "EnableLogon";
            _worker = await App.Operations.PolicyWorkerAsync(action);
            await RefreshRulesAsync();
        }
        catch (Exception error) { Status = "The rule worker needs attention."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void Invalidate() { _review = null; ReviewSummary = ""; NotifyState(); }
    private void NotifyState()
    {
        foreach (var property in new[] { nameof(CanEdit), nameof(HasProcess), nameof(ShowLogicalCpus), nameof(ShowTopology), nameof(CanPreview), nameof(CanApply), nameof(CanRestore), nameof(HasReview), nameof(CanSaveRule), nameof(CanManageRule), nameof(CanManageWorker) }) OnPropertyChanged(property);
    }
    private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    private static ControlOption Option<T>(string label, T value) => new(label, Value(value));
    internal static ControlOption[] Options(string name) => name switch
    {
        "cpuPriority" => new[] { "Idle", "BelowNormal", "Normal", "AboveNormal", "High", "Realtime" }.Select(value => Option(value, value)).ToArray(),
        "ioPriority" => [Option("Very low", 0), Option("Low", 1), Option("Normal", 2), Option("High · Windows support varies", 3)],
        "gpuPriority" => [Option("Idle", 0), Option("Below normal", 1), Option("Normal", 2), Option("Above normal", 3), Option("High", 4), Option("Realtime", 5)],
        "memoryPriority" => [Option("Very low", 1), Option("Low", 2), Option("Medium", 3), Option("Below normal", 4), Option("Normal", 5)],
        "executionQoS" => [Option("Windows managed", "systemManaged"), Option("Eco", "eco"), Option("High performance", "high")],
        "priorityBoost" => [Option("Allow dynamic boosts", true), Option("Disable dynamic boosts", false)],
        _ => throw new ArgumentException("Unknown control.", nameof(name)),
    };
    public static string Label(string name) => name switch
    {
        "cpuPriority" => "CPU priority", "ioPriority" => "I/O priority", "gpuPriority" => "GPU priority", "memoryPriority" => "Memory priority",
        "executionQoS" => "Execution QoS", "priorityBoost" => "Dynamic priority boost", "cpuSets" => "CPU Sets", "affinity" => "Hard affinity", _ => name,
    };
    public static string Describe(string name, JsonElement value) => name switch
    {
        "executionQoS" => value.Deserialize<PowerThrottling>(OperationFiles.Json)?.ExecutionMode switch { "systemManaged" => "Windows managed", "eco" => "Eco", "high" => "High performance", _ => "unknown" },
        "affinity" => value.Deserialize<AffinityState>(OperationFiles.Json) is { } affinity ? "group " + affinity.Group + " · " + affinity.Mask : "unknown",
        "cpuSets" => value.GetArrayLength() == 0 ? "Windows default" : value.GetArrayLength() + " selected",
        "priorityBoost" => value.GetBoolean() ? "allowed" : "disabled",
        "cpuPriority" => value.GetString() switch { "BelowNormal" => "Below normal", "AboveNormal" => "Above normal", "RealTime" => "Realtime", var text => text ?? "unknown" },
        "ioPriority" or "gpuPriority" or "memoryPriority" => Options(name).SingleOrDefault(option => option.Value?.GetInt32() == value.GetInt32())?.Label ?? value.ToString(),
        _ => value.ToString(),
    };
}
