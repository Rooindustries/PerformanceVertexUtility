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
    public override string ToString() => Rule.Name + (Rule.Enabled ? " · on" : " · off");
}
public sealed record GovernorRuleRow(string Name, string State, string Requested, string Observed);

public static class GovernorDisplay
{
    public const string Running = "Roo Industries Governor is running. It keeps your rules active when this app is closed and starts when you sign in.";
    public const string Paused = "Paused";
    public const string Pausing = "Pausing";
    public const string Stopped = "Stopped";
    public const string NotResponding = "Not responding";
    public const string Off = "Roo Industries Governor is off. Save a rule to turn it on.";
    public const string Denied = "Windows denied access to this setting for this app";
    public const string StoppedRestarts = "The governor stopped. It starts again by itself within a minute, or press Start governor.";
    public const string StoppedStays = "The governor stopped and won't start again by itself. Press Start governor to start it.";
    public const string StoppedUnknown = "The governor stopped. Press Start governor to start it.";
    public static string StoppedFailed(int code) => "The governor stopped and its last automatic start failed (error 0x" + code.ToString("X8") + "), so it may not start again by itself. Press Start governor to start it.";
    public const string NotRunningApp = "The app is not running right now.";
    public const string PausedRule = "Not applied right now because the governor is paused.";
    public const string StoppedRule = "Not applied right now because the governor is stopped.";
    public const string AttentionRule = "Not checked right now because the governor needs attention.";
    public const string RetryHint = " Press Put settings back to try again.";

    public static string Key(RunningProcess process) => GovernorProbe.Key(process);

    public static PolicyInstance[] Live(GovernorSnapshot snapshot) => snapshot.Worker.State?.Instances
        .Where(instance => instance.Status is "active" or "applying" or "conflict" && snapshot.Exited?.Contains(Key(instance.Process)) != true).ToArray() ?? [];

    public static PolicyInstance[] Holding(GovernorSnapshot snapshot) => Live(snapshot)
        .Where(instance => !(instance.Status == "applying" && snapshot.Unapplied?.Contains(instance.JournalPath) == true)).ToArray();

    public static int Apps(IEnumerable<PolicyInstance> instances) => instances.Select(instance => Key(instance.Process)).Distinct().Count();
    public static int Changed(GovernorSnapshot snapshot) => Apps(Holding(snapshot).Where(instance => instance.Status is "active" or "applying"));
    public static int Kept(GovernorSnapshot snapshot) => Apps(Holding(snapshot).Where(instance => instance.Status == "conflict"));
    public static string Count(int apps) => apps == 1 ? "1 app" : apps + " apps";
    public static string StillHave(int apps) => apps == 1 ? "1 app still has" : apps + " apps still have";

    public static string State(GovernorSnapshot snapshot)
    {
        var (summary, worker) = (snapshot.Summary, snapshot.Worker);
        var unreadable = summary.UnreadableRules is { Length: > 0 };
        var off = !summary.Paused && summary.EnabledRules == 0 && summary.RulesError is null && !unreadable && summary.SecurityProblem is null or "missing";
        if (worker.HostRunning is null && !off || worker.HostRunning == true && worker.Error is not null) return "notResponding";
        if (summary.Paused) return Changed(snapshot) > 0 ? "pausing" : "paused";
        if (off) return "off";
        if (summary.RulesError is not null || unreadable && summary.EnabledRules == 0 || !summary.Secured) return "notResponding";
        if (worker.HostRunning == false) return "stopped";
        return worker.State?.Status == "running" ? "running" : "notResponding";
    }

    public static bool CanRetry(GovernorSnapshot snapshot, string state) => state is "off" or "paused" && snapshot.Worker.HostRunning == false && Kept(snapshot) > 0;

    public static string Headline(string state) => state switch { "running" => Running, "paused" => Paused, "pausing" => Pausing, "stopped" => Stopped, "off" => Off, _ => NotResponding };

    public static string Detail(string state, GovernorSnapshot snapshot)
    {
        var (summary, worker) = (snapshot.Summary, snapshot.Worker);
        var retry = CanRetry(snapshot, state) ? RetryHint : "";
        return state switch
        {
            "running" => (summary.EnabledRules == 1 ? "1 rule is on." : summary.EnabledRules + " rules are on.")
                + (worker.State?.Errors.FirstOrDefault(error => summary.UnreadableRules?.Contains(error) != true) is { Length: > 0 } problem ? " " + problem.TrimEnd('.') + "." : "")
                + (summary.UnreadableRules is { Length: > 0 } unread ? " " + string.Join(" ", unread).TrimEnd('.') + ". Those rules are not enforced." : ""),
            "pausing" => worker.HostRunning == true
                ? "Putting the old settings back for " + Count(Changed(snapshot)) + "."
                : StillHave(Changed(snapshot)) + " rule settings that were not put back. Press Pause governor to put them back.",
            "paused" => (Kept(snapshot) > 0
                ? "Your rules are saved but not used. Some apps kept a setting the governor could not put back." + retry
                : "Your rules are saved but not used. The apps got their old settings back.") + " Press Start governor to use your rules again.",
            "off" => worker.HostRunning is null ? "Roo Industries couldn't read the governor's last state, so it can't confirm every app got its old settings back" + Reason(worker.Error) + "."
                : Kept(snapshot) > 0 ? StillHave(Kept(snapshot)) + " a setting Roo Industries could not put back." + retry
                : Changed(snapshot) == 0 ? ""
                : worker.HostRunning == true ? "Putting the old settings back for " + Count(Changed(snapshot)) + "."
                : StillHave(Changed(snapshot)) + " rule settings that were not put back.",
            "stopped" => (worker.State?.Errors.FirstOrDefault() is { Length: > 0 } last ? last + " " : "")
                + (snapshot.ScheduledTask is null ? StoppedUnknown : snapshot.ScheduledTask.LastStartFailed && snapshot.ScheduledTask is { Registered: true, Enabled: true, RestartsEveryMinute: true } ? StoppedFailed(snapshot.ScheduledTask.LastResult)
                    : snapshot.ScheduledTask.Restarts ? StoppedRestarts : StoppedStays),
            _ => worker.HostRunning is null && summary.Paused
                    ? "Paused, but Roo Industries couldn't read the governor's state, so it can't confirm the old settings were put back" + Reason(worker.Error) + "."
                : worker.HostRunning == true && worker.Error is not null && summary.Paused
                    ? "Paused, but the governor is not answering, so the old settings may not be back yet. Press Pause governor to stop it and put them back."
                : summary.SecurityProblem is { } problem && problem != "missing" ? "The rules folder is not protected: " + problem + ". Press Start governor to repair it."
                : summary.RulesError is { } rulesError ? "Your saved rules could not be read: " + rulesError
                : summary.UnreadableRules is { Length: > 0 } damaged && summary.EnabledRules == 0 ? string.Join(" ", damaged)
                : worker.HostRunning == true && worker.Error is not null ? "The governor is not answering. Press Start governor to restart it."
                : worker.HostRunning == true && worker.State?.Status == "configurationError"
                    ? (worker.State.Errors.FirstOrDefault() is { Length: > 0 } unreadable ? unreadable.TrimEnd('.') + "." : "Your saved rules could not be read.")
                      + " The governor keeps checking and uses your rules again once they can be read."
                : worker.HostRunning == true ? (worker.State?.Errors.FirstOrDefault() is { Length: > 0 } failure ? failure.TrimEnd('.') + "." : "The governor reported a problem.") + " Press Start governor to restart it."
                : "The governor's status could not be read" + Reason(worker.Error) + ". Press Start governor to restart it.",
        };
    }

    private static string Reason(string? error) => error is { Length: > 0 } ? ": " + error.TrimEnd('.') : "";

    public static string Outcome(PolicyInstance instance, bool enforced)
        => instance.Status != "conflict" ? "kept" : instance.ErrorKind == "keepsChanging" || enforced ? "steppedBack" : "notPutBack";

    public static GovernorRuleRow[] Rows(GovernorSnapshot snapshot) => Rows(snapshot, State(snapshot));

    public static GovernorRuleRow[] Rows(GovernorSnapshot snapshot, string state)
    {
        var live = Live(snapshot);
        var holding = Holding(snapshot);
        var issues = snapshot.Worker.State?.Issues ?? [];
        return snapshot.Rules.Select(rule =>
        {
            var requested = string.Join(", ", rule.Controls.Select(pair => ProcessControlsViewModel.Label(pair.Key) + " " + ProcessControlsViewModel.Describe(pair.Key, pair.Value))
                .Concat(rule.CpuSelection is null ? Array.Empty<string>() : new[] { "Preferred CPUs " + (rule.CpuSelection.Processors is { Length: > 0 } chosen ? chosen.Length + " selected" : rule.CpuSelection.Kind switch
                { "windowsDefault" => "Windows default", "all" => "all", "performance" => "performance cores", "efficiency" => "efficiency cores", "core" => "one core", "cache" => "one cache group", "numa" => "one NUMA node", var kind => kind }) }));
            var enforced = rule.Enabled && state == "running";
            var mine = (enforced ? live : holding).Where(instance => instance.RuleId == rule.RuleId).ToArray();
            var lines = new List<(int Process, int Order, string Text)>();
            var held = new Dictionary<int, HashSet<string>>();
            foreach (var instance in mine)
            {
                var name = Path.GetFileName(instance.Process.ExecutablePath) + " (" + instance.Process.ProcessId + ")";
                snapshot.Journals.TryGetValue(instance.JournalPath, out var journal);
                string[] fields = instance.Field is { } field ? [field] : journal?.Changes.Select(change => change.Name).ToArray() ?? [];
                if (!held.TryGetValue(instance.Process.ProcessId, out var set)) held[instance.Process.ProcessId] = set = new(StringComparer.Ordinal);
                set.UnionWith(fields);
                var label = fields.Length == 0 ? "Settings" : string.Join(", ", fields.Select(ProcessControlsViewModel.Label));
                lines.Add((instance.Process.ProcessId, Order(fields.FirstOrDefault()), name + " · " + (enforced ? Enforced(instance, label, journal) : Leftover(instance, label))));
            }
            if (enforced)
                foreach (var issue in issues.Where(issue => issue.RuleId == rule.RuleId))
                {
                    var name = Path.GetFileName(issue.ExecutablePath ?? rule.ExecutablePath) + (issue.ProcessId is { } id ? " (" + id + ")" : "");
                    var taken = issue.ProcessId is { } pid && held.TryGetValue(pid, out var known) ? known : [];
                    var reason = issue.Kind == "denied" ? Denied : issue.Message;
                    if (issue.Field is { } named)
                    {
                        if (!taken.Contains(named)) lines.Add((issue.ProcessId ?? int.MaxValue, Order(named), name + " · " + ProcessControlsViewModel.Label(named) + " unavailable · " + reason));
                    }
                    else if (issue.Kind is "denied" or "error")
                        foreach (var each in ProcessPolicyStore.Fields(rule).Where(each => !taken.Contains(each)))
                            lines.Add((issue.ProcessId ?? int.MaxValue, Order(each), name + " · " + ProcessControlsViewModel.Label(each) + " unavailable · " + reason));
                    else lines.Add((issue.ProcessId ?? int.MaxValue, -1, name + " · " + (issue.Kind == "otherAccount" ? ProcessPolicyHost.OtherAccount : "unavailable · " + issue.Message)));
                }
            var details = lines.OrderBy(line => line.Process).ThenBy(line => line.Order).Select(line => line.Text).ToList();
            var headline = !rule.Enabled ? "Off" : state switch
            {
                "running" => details.Count == 0 ? NotRunningApp : null,
                "paused" or "pausing" => PausedRule,
                "stopped" => StoppedRule,
                _ => AttentionRule,
            };
            if (headline is not null) details.Insert(0, headline);
            return new GovernorRuleRow(rule.Name, rule.Enabled ? "On" : "Off", "Wanted: " + requested, "Now: " + string.Join("\n", details));
        }).ToArray();
    }

    private static int Order(string? field) => field is null ? -1 : Array.IndexOf(ProcessTarget.ControlNames, field);

    private static string Enforced(PolicyInstance instance, string label, ProcessControlJournal? journal) => (instance.Status, instance.ErrorKind) switch
    {
        ("conflict", "keepsChanging") => label + " · " + ProcessPolicyHost.KeepsChanging,
        (_, "denied") => label + " unavailable · " + Denied,
        ("conflict", _) => label + " stepped back" + (instance.Error is { Length: > 0 } reason ? " · " + reason : ""),
        (_, "error") => label + " unavailable · " + (instance.Error is { Length: > 0 } failure ? failure : "Windows did not accept the requested value."),
        ("active", _) when journal?.Changes.Any(change => instance.Field is null || change.Name == instance.Field) == true => string.Join(", ", journal.Changes.Where(change => instance.Field is null || change.Name == instance.Field).Select(change => ProcessControlsViewModel.Label(change.Name) + " " +
            (change.Observed is { } observed ? ProcessControlsViewModel.Describe(change.Name, observed) : "unknown"))),
        _ => label + " starting",
    };

    private static string Leftover(PolicyInstance instance, string label) => (instance.Status, instance.ErrorKind) switch
    {
        ("conflict", "keepsChanging") => label + " · " + ProcessPolicyHost.KeepsChanging,
        ("conflict", "denied") => label + " could not be put back · " + Denied,
        ("conflict", _) => label + " could not be put back" + (instance.Error is { Length: > 0 } reason ? " · " + reason : ""),
        _ => label + " still set by this rule",
    };
}

public partial class ProcessControlsViewModel : ObservableObject
{
    public ObservableCollection<CpuProcessChoice> Processes { get; } = new();
    public ObservableCollection<ProcessControlRow> Controls { get; } = new();
    public ObservableCollection<LogicalCpuChoice> Cpus { get; } = new();
    public ObservableCollection<TopologyChoice> TopologyChoices { get; } = new();
    public ObservableCollection<SavedRuleChoice> Rules { get; } = new();
    public ObservableCollection<GovernorRuleRow> GovernorRules { get; } = new();
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
    [ObservableProperty] private bool _cpuSetsAvailable;
    [ObservableProperty] private bool _affinityAvailable;
    [ObservableProperty] private string _ruleName = "";
    [ObservableProperty] private string _status = "Choose an application to inspect its controls.";
    [ObservableProperty] private string _detail = "Changes use Windows process controls. Applications that deny access remain unchanged.";
    [ObservableProperty] private string _reviewSummary = "";
    [ObservableProperty] private string _governorHeadline = "Checking the Roo Industries Governor…";
    [ObservableProperty] private string _governorDetail = "";
    [ObservableProperty] private string _governorState = "unknown";
    [ObservableProperty] private bool _retryAvailable;
    [ObservableProperty] private string _ruleDetail = "";
    private ProcessControlSnapshot? _snapshot;
    private ProcessControlReview? _review;
    private string? _journal;
    private string? _editingRuleId;
    private int _selectionVersion;
    private ushort _affinityGroup;
    private Task _readTask = Task.CompletedTask;
    private bool _observing;

    public ProcessControlsViewModel() => _selectedCpuMode = CpuModes[0];
    public bool CanEdit => !Busy && !RestoreAvailable;
    public bool CanEditCpuSelection => CanEdit && CpuSetsAvailable;
    public bool CanEditAffinity => CanEdit && AffinityAvailable;
    public bool CanEditCpuChoices => CanEdit && (SelectedCpuMode.Kind == "logical" && CpuSetsAvailable || SetHardAffinity && AffinityAvailable);
    public bool HasProcess => _snapshot is not null;
    public bool ShowLogicalCpus => SelectedCpuMode.Kind == "logical" || SetHardAffinity;
    public bool ShowTopology => SelectedCpuMode.Kind is "core" or "cache" or "numa";
    public bool CanPreview => CanEdit && _snapshot is not null &&
        (SelectedCpuMode.Kind == "unchanged" || CpuSetsAvailable) && (!SetHardAffinity || AffinityAvailable) &&
        (Controls.Any(row => row.Available && row.Selected.Value is not null) || SelectedCpuMode.Kind != "unchanged" || SetHardAffinity);
    public bool CanApply => !Busy && _review is not null && !RestoreAvailable;
    public bool CanRestore => !Busy && RestoreAvailable;
    public bool HasReview => _review is not null;
    public bool CanSaveRule => CanApply && !string.IsNullOrWhiteSpace(RuleName);
    public bool CanManageRule => !Busy && SelectedRule is not null;
    public bool CanPauseGovernor => !Busy && GovernorState is "running" or "pausing" or "stopped" or "notResponding";
    public bool CanStartGovernor => !Busy && GovernorState is "paused" or "pausing" or "stopped" or "notResponding";
    public bool CanRetryRestore => !Busy && RetryAvailable;
    partial void OnRetryAvailableChanged(bool value) => NotifyState();

    partial void OnBusyChanged(bool value) => NotifyState();
    partial void OnGovernorStateChanged(string value) => NotifyState();
    partial void OnRestoreAvailableChanged(bool value) => NotifyState();
    partial void OnCpuSetsAvailableChanged(bool value) => NotifyState();
    partial void OnAffinityAvailableChanged(bool value) => NotifyState();
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
    private Task RefreshAsync() => TryRefreshAsync();

    public async Task<bool> TryRefreshAsync()
    {
        if (!CanEdit) return false;
        Busy = true;
        try
        {
            var inventory = await App.Live.GetProcessInventoryAsync();
            if (inventory?.Processes is null) throw new InvalidOperationException(App.Live.LastError ?? "The process list is unavailable.");
            SelectedProcess = null;
            Processes.Clear();
            foreach (var process in inventory.Processes.Where(item => item.Pid > 0 && item.Pid != Environment.ProcessId && item.Category != "windowsCore" && !item.Protected && !item.Blocked).OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase))
                Processes.Add(new(process.Pid, process.Name ?? "Process"));
            return true;
        }
        catch (Exception error) { Status = "Couldn't refresh applications."; Detail = error.Message; return false; }
        finally { Busy = false; }
    }

    private async Task ReadProcessAsync(CpuProcessChoice? process, int version)
    {
        _snapshot = null; Controls.Clear(); Cpus.Clear(); _editingRuleId = null; SelectedCpuMode = CpuModes[0]; SetHardAffinity = false; OneThreadPerCore = false;
        CpuSetsAvailable = false; AffinityAvailable = false; _affinityGroup = 0; AffinityMask = ""; AffinityLabel = "Hard-affinity CPU mask";
        if (process is null) { NotifyState(); return; }
        Busy = true;
        try
        {
            var snapshot = await App.Operations.ReadProcessControlsAsync(process.Id);
            if (version != _selectionVersion) return;
            if (snapshot.Protection.Require().GetUInt32() != 0xfffffffe) throw new InvalidOperationException("Windows reports a protected application. Choose another process.");
            _snapshot = snapshot;
            var affinity = snapshot.Controls["affinity"];
            CpuSetsAvailable = Readable(snapshot.Controls["cpuSets"]);
            AffinityAvailable = Readable(affinity);
            if (AffinityAvailable)
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
            Detail = "Preferred CPUs: " + DescribeRead("cpuSets", snapshot.Controls["cpuSets"]) + ". Hard affinity: " + DescribeRead("affinity", affinity) + ".";
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
            if (!AffinityAvailable) throw new InvalidOperationException("The process affinity could not be read.");
            controls["affinity"] = Value(new AffinityState(_affinityGroup, AffinityMask.Trim()));
        }
        CpuSelection? selection = null;
        if (SelectedCpuMode.Kind != "unchanged")
        {
            if (!CpuSetsAvailable) throw new InvalidOperationException("The preferred CPU state could not be read.");
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
            if ((await App.Operations.ReadGovernorAsync()).Summary.SecurityProblem is not (null or "missing")) await App.Operations.PolicyWorkerAsync("Sync");
            var saved = await App.Operations.SaveRuleAsync(rule);
            _editingRuleId = saved.RuleId;
            Status = "Rule saved. Starting the Roo Industries Governor…";
            var registration = await App.Operations.PolicyWorkerAsync("Sync");
            await RefreshRulesAsync();
            Status = registration.Paused ? "Rule saved. The governor is paused, so press Start governor to use it." : "Rule saved and on.";
            Detail = "The Roo Industries Governor keeps this rule on after you close the app. If another app changes the same setting, Roo Industries puts it back up to three times and then steps back for that app.";
            Invalidate();
        }
        catch (Exception error) { Status = "Saved rules need attention."; Detail = error.Message; await TryRefreshRulesAsync(); }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RefreshRulesAsync()
    {
        var selected = SelectedRule?.Rule.RuleId;
        var snapshot = await App.Operations.ReadGovernorAsync();
        Rules.Clear();
        foreach (var rule in snapshot.Rules) Rules.Add(new(rule));
        SelectedRule = Rules.FirstOrDefault(item => item.Rule.RuleId == selected) ?? Rules.FirstOrDefault();
        ShowGovernor(snapshot);
    }

    private void ShowGovernor(GovernorSnapshot snapshot)
    {
        GovernorState = GovernorDisplay.State(snapshot);
        GovernorHeadline = GovernorDisplay.Headline(GovernorState);
        GovernorDetail = GovernorDisplay.Detail(GovernorState, snapshot);
        RetryAvailable = GovernorDisplay.CanRetry(snapshot, GovernorState);
        var rows = GovernorDisplay.Rows(snapshot, GovernorState);
        if (rows.SequenceEqual(GovernorRules)) return;
        GovernorRules.Clear();
        foreach (var row in rows) GovernorRules.Add(row);
    }

    private void ShowGovernorError(Exception error)
    {
        GovernorState = "notResponding";
        GovernorHeadline = GovernorDisplay.NotResponding;
        GovernorDetail = "The governor's status could not be read: " + error.Message.TrimEnd('.') + ".";
        RetryAvailable = false;
        GovernorRules.Clear();
    }

    public async Task ObserveAsync()
    {
        if (Busy || _observing) return;
        _observing = true;
        var version = _selectionVersion;
        try
        {
            GovernorSnapshot? governor = null;
            Exception? unreadable = null;
            try { governor = await App.Operations.ReadGovernorAsync(); }
            catch (Exception error) { unreadable = error; }
            if (Busy || version != _selectionVersion) return;
            if (governor is not null) ShowGovernor(governor);
            else ShowGovernorError(unreadable!);
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
            CpuSetsAvailable = Readable(fresh.Controls["cpuSets"]);
            AffinityAvailable = Readable(fresh.Controls["affinity"]);
            Detail = "Preferred CPUs: " + DescribeRead("cpuSets", fresh.Controls["cpuSets"]) + ". Hard affinity: " + DescribeRead("affinity", fresh.Controls["affinity"]) + ".";
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
            if ((await App.Operations.ReadGovernorAsync()).Summary.SecurityProblem is not (null or "missing")) await App.Operations.PolicyWorkerAsync("Sync");
            if (delete) await App.Operations.DeleteRuleAsync(SelectedRule!.Rule.RuleId);
            else
            {
                var fresh = (await App.Operations.ReadGovernorAsync()).Rules.FirstOrDefault(rule => rule.RuleId == SelectedRule!.Rule.RuleId)
                    ?? throw new InvalidOperationException("This rule was deleted. Refresh the rules list.");
                await App.Operations.SaveRuleAsync(fresh with { Enabled = !fresh.Enabled });
            }
            await App.Operations.PolicyWorkerAsync("Sync");
            await RefreshRulesAsync();
            Status = delete ? "Rule deleted." : "Rule updated.";
            Detail = "Turning off or deleting a rule gives the app its old settings back.";
        }
        catch (Exception error) { Status = "Couldn't update the rule."; Detail = error.Message; await TryRefreshRulesAsync(); }
        finally { Busy = false; }
    }

    public async Task<bool> TryRefreshRulesAsync()
    {
        try { await RefreshRulesAsync(); return true; }
        catch (Exception) { return false; }
    }

    [RelayCommand]
    private async Task PauseGovernorAsync() => await GovernorAsync("Pause", "Governor paused.");
    [RelayCommand]
    private async Task StartGovernorAsync() => await GovernorAsync("Resume", "Governor started.");
    [RelayCommand]
    private async Task RetryRestoreAsync()
    {
        if (Busy || !RetryAvailable) return;
        Busy = true;
        try
        {
            await App.Operations.RetryGovernorRestoreAsync();
            var snapshot = await App.Operations.ReadGovernorAsync();
            await RefreshRulesAsync();
            Status = snapshot.Worker.HostRunning is null ? "Couldn't confirm the old settings are back."
                : RetryAvailable || GovernorDisplay.Holding(snapshot).Length > 0 ? "Some settings still could not be put back." : "The old settings are back.";
            Detail = "";
        }
        catch (Exception error) { Status = "Couldn't put the settings back."; Detail = error.Message; }
        finally { Busy = false; }
    }
    private async Task GovernorAsync(string action, string done)
    {
        if (Busy) return;
        Busy = true;
        try
        {
            await App.Operations.PolicyWorkerAsync(action);
            await RefreshRulesAsync();
            Status = done;
            Detail = "";
        }
        catch (Exception error) { Status = "The governor needs attention."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void Invalidate() { _review = null; ReviewSummary = ""; NotifyState(); }
    private void NotifyState()
    {
        foreach (var property in new[] { nameof(CanEdit), nameof(CanEditCpuSelection), nameof(CanEditAffinity), nameof(CanEditCpuChoices), nameof(HasProcess), nameof(ShowLogicalCpus), nameof(ShowTopology), nameof(CanPreview), nameof(CanApply), nameof(CanRestore), nameof(HasReview), nameof(CanSaveRule), nameof(CanManageRule), nameof(CanPauseGovernor), nameof(CanStartGovernor), nameof(CanRetryRestore) }) OnPropertyChanged(property);
    }
    private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    private static ControlOption Option<T>(string label, T value) => new(label, Value(value));
    internal static ControlOption[] Options(string name) => name switch
    {
        "cpuPriority" => new[] { "Idle", "BelowNormal", "Normal", "AboveNormal", "High", "Realtime" }.Select(value => Option(value switch { "BelowNormal" => "Below normal", "AboveNormal" => "Above normal", "Realtime" => "Realtime · can freeze your PC", _ => value }, value)).ToArray(),
        "ioPriority" => [Option("Very low", 0), Option("Low", 1), Option("Normal", 2), Option("High · Windows support varies", 3)],
        "gpuPriority" => [Option("Idle", 0), Option("Below normal", 1), Option("Normal", 2), Option("Above normal", 3), Option("High", 4), Option("Realtime · can freeze your PC", 5)],
        "memoryPriority" => [Option("Very low", 1), Option("Low", 2), Option("Medium", 3), Option("Below normal", 4), Option("Normal", 5)],
        "executionQoS" => [Option("Windows managed", "systemManaged"), Option("Eco", "eco"), Option("High performance", "high")],
        "priorityBoost" => [Option("Allow dynamic boosts", true), Option("Disable dynamic boosts", false)],
        _ => throw new ArgumentException("Unknown control.", nameof(name)),
    };
    public static string Label(string name) => name switch
    {
        "cpuPriority" => "CPU priority", "ioPriority" => "I/O priority", "gpuPriority" => "GPU priority", "memoryPriority" => "Memory priority",
        "executionQoS" => "Power mode", "priorityBoost" => "Priority boost", "cpuSets" => "Preferred CPUs", "affinity" => "CPU affinity", _ => name,
    };
    private static bool Readable(ControlRead read) => read.Known && read.Error is null && read.Value is { ValueKind: not (JsonValueKind.Null or JsonValueKind.Undefined) };
    private static string DescribeRead(string name, ControlRead read)
    {
        if (Readable(read)) return Describe(name, read.Value!.Value);
        return "unavailable" + (read.Error?.Message is { Length: > 0 } error ? " · " + error : "");
    }
    public static string Describe(string name, JsonElement value) => name switch
    {
        "executionQoS" => value.Deserialize<PowerThrottling>(OperationFiles.Json)?.ExecutionMode switch { "systemManaged" => "Windows managed", "eco" => "Eco", "high" => "High performance", _ => "unknown" },
        "affinity" => value.Deserialize<AffinityState>(OperationFiles.Json) is { } affinity ? "group " + affinity.Group + " · " + affinity.Mask : "unknown",
        "cpuSets" => value.GetArrayLength() == 0 ? "Windows default" : value.GetArrayLength() + " selected",
        "priorityBoost" => value.GetBoolean() ? "allowed" : "disabled",
        "cpuPriority" => value.GetString() switch { "BelowNormal" => "Below normal", "AboveNormal" => "Above normal", "RealTime" => "Realtime", var text => text ?? "unknown" },
        "ioPriority" or "gpuPriority" or "memoryPriority" => Options(name).SingleOrDefault(option => option.Value?.GetInt32() == value.GetInt32())?.Label.Split(" · ")[0] ?? value.ToString(),
        _ => value.ToString(),
    };
}
