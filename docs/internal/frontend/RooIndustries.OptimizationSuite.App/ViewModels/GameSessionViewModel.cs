using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class GameSessionSetting : ObservableObject
{
    public string Name { get; }
    public string Label => ProcessControlsViewModel.Label(Name);
    public ControlOption[] Options { get; }
    [ObservableProperty] private ControlOption _selected;
    partial void OnSelectedChanged(ControlOption value) { if (value is null) Selected = Options[0]; }
    public GameSessionSetting(string name)
    {
        Name = name;
        Options = new[] { new ControlOption("Keep current", null) }.Concat(ProcessControlsViewModel.Options(name)
            .Where(option => name != "gpuPriority" || option.Value?.GetInt32() != 5)).ToArray();
        _selected = Options[0];
    }
}

public sealed record GameCoreChoice(string Label, AffinityState Affinity)
{
    public override string ToString() => Label;
}
public sealed record GameSessionField(string Label, string Requested, string Observed, string Result);

public partial class GameSessionViewModel : ObservableObject
{
    public ObservableCollection<CpuProcessChoice> Launchers { get; } = new();
    public ObservableCollection<GameSessionEntry> Sessions { get; } = new();
    public ObservableCollection<GameCoreChoice> CoreChoices { get; } = new();
    public ObservableCollection<GameSessionField> Fields { get; } = new();
    public GameSessionSetting[] Settings { get; } = [new("cpuPriority"), new("ioPriority"), new("memoryPriority"), new("gpuPriority"), new("executionQoS"), new("priorityBoost")];
    [ObservableProperty] private CpuProcessChoice? _selectedLauncher;
    [ObservableProperty] private GameSessionEntry? _selectedSession;
    [ObservableProperty] private GameCoreChoice? _selectedCores;
    [ObservableProperty] private string _gamePath = "";
    [ObservableProperty] private string _affinityMask = "";
    [ObservableProperty] private bool _acceptLauncherScope;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private string _status = "Close the game, then choose its launcher and executable.";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private string _reviewSummary = "";
    private ProcessControlSnapshot? _launcher;
    private GameSessionReview? _review;
    private ProtectedSessionStatus? _current;
    private string? _sessionRoot;
    private string? _pendingAffinity;
    private int _version;
    private bool _observing;

    public GameSessionViewModel()
    {
        foreach (var setting in Settings) setting.PropertyChanged += SettingChanged;
    }

    public bool CanEdit => !Busy && _sessionRoot is null;
    public bool HasLauncher => _launcher is not null || HasSession;
    public bool HasSession => _sessionRoot is not null;
    public bool HasReview => _review is not null;
    public bool CanPreview => CanEdit && _launcher is not null && SelectedLauncher?.Id == _launcher.Identity.ProcessId &&
        !string.IsNullOrWhiteSpace(GamePath) && !string.IsNullOrWhiteSpace(AffinityMask) && AcceptLauncherScope;
    public bool CanStart => CanEdit && _review is not null;
    public bool CanStop => !Busy && HasSession && _current?.HostRunning != null && !GameSessionDisplay.Restored(_current);
    public bool CanRecover => !Busy && HasSession && _current?.HostRunning == false && _current.State is not null && !GameSessionDisplay.Restored(_current);
    public bool CanSwitch => !Busy && _pendingAffinity is null && _current is { HostRunning: true, Error: null, State: not null } current &&
        DateTime.UtcNow - current.State.UpdatedAtUtc <= TimeSpan.FromSeconds(15) && current.State.Preview.Controls.ContainsKey("affinity") && _launcher is not null;
    public bool CanChooseCores => CanEdit || CanSwitch;
    public bool CanChooseSession => !Busy;

    partial void OnBusyChanged(bool value) => NotifyState();
    partial void OnGamePathChanged(string value) => Invalidate();
    partial void OnAcceptLauncherScopeChanged(bool value) => Invalidate();
    partial void OnAffinityMaskChanged(string value) => Invalidate();
    partial void OnSelectedCoresChanged(GameCoreChoice? value) { if (value is not null) AffinityMask = value.Affinity.Mask; }
    public void NoteChanged()
    {
        Status = "Settings changed elsewhere";
        Detail = "Choose the launcher again, or clear it, to read its current values.";
    }
    partial void OnSelectedLauncherChanged(CpuProcessChoice? value)
    {
        if (_sessionRoot is not null) return;
        Invalidate(); _launcher = null; CoreChoices.Clear();
        _ = ReadLauncherAsync(value, ++_version);
    }
    partial void OnSelectedSessionChanged(GameSessionEntry? value)
    {
        ++_version; _review = null; ReviewSummary = ""; _launcher = null; CoreChoices.Clear();
        _pendingAffinity = null;
        _sessionRoot = value?.SessionRoot; _current = value?.Worker;
        if (value is not null)
        {
            if (value.Worker.State is { } state)
            {
                GamePath = state.Preview.GamePath; AcceptLauncherScope = state.Preview.AcceptLauncherScope;
                var launcher = new CpuProcessChoice(state.Preview.Launcher.ProcessId, Path.GetFileName(state.Preview.Launcher.ExecutablePath));
                if (!Launchers.Contains(launcher)) Launchers.Add(launcher);
                SelectedLauncher = launcher;
                foreach (var setting in Settings)
                {
                    if (!state.Preview.Controls.TryGetValue(setting.Name, out var desired)) { setting.Selected = setting.Options[0]; continue; }
                    if (setting.Name == "executionQoS") desired = JsonSerializer.SerializeToElement(desired.Deserialize<PowerThrottling>(OperationFiles.Json)!.ExecutionMode);
                    setting.Selected = setting.Options.FirstOrDefault(option => option.Value?.GetRawText() == desired.GetRawText()) ?? setting.Options[0];
                }
                CoreChoices.Add(new("Last requested cores", state.DesiredAffinity)); SelectedCores = CoreChoices[0];
            }
            ShowStatus(value.Worker); _ = ReadSessionLauncherAsync(value, _version);
        }
        NotifyState();
    }

    public async Task InitializeAsync()
    {
        await RefreshAsync();
        if (SelectedSession is null && Sessions.Count > 0)
            SelectedSession = Sessions.FirstOrDefault(entry => !GameSessionDisplay.Restored(entry.Worker)) ?? Sessions[0];
    }

    [RelayCommand]
    private Task RefreshAsync() => TryRefreshAsync();

    public async Task<bool> TryRefreshAsync()
    {
        if (Busy) return false;
        Busy = true;
        try
        {
            var selected = _sessionRoot;
            var entries = await App.Operations.ReadGameSessionsAsync();
            Sessions.Clear(); foreach (var entry in entries) Sessions.Add(entry);
            if (selected is not null) SelectedSession = Sessions.FirstOrDefault(entry => entry.SessionRoot == selected);
            if (_sessionRoot is null)
            {
                var inventory = await App.Live.GetProcessInventoryAsync();
                if (inventory?.Processes is null) throw new InvalidOperationException(App.Live.LastError ?? "The launcher list is unavailable.");
                SelectedLauncher = null; Launchers.Clear();
                foreach (var process in inventory.Processes.Where(process => process.Pid > 0 && process.Pid != Environment.ProcessId && !process.Protected && !process.Blocked && process.Category != "windowsCore").OrderBy(process => process.Name, StringComparer.OrdinalIgnoreCase))
                    Launchers.Add(new(process.Pid, process.Name ?? "Application"));
            }
            return true;
        }
        catch (Exception error) { Status = "Couldn't refresh game sessions."; Detail = error.Message; return false; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task NewSessionAsync()
    {
        if (Busy) return;
        await RefreshAsync();
        var outstanding = Sessions.FirstOrDefault(entry => !GameSessionDisplay.Restored(entry.Worker));
        if (outstanding is not null)
        {
            SelectedSession = outstanding;
            Detail = "Stop or recover the existing session before starting another.";
            return;
        }
        SelectedSession = null; _sessionRoot = null; _current = null; AcceptLauncherScope = false; Fields.Clear();
        Status = "Close the game, then choose its launcher and executable."; Detail = "";
        await RefreshAsync(); NotifyState();
    }

    private async Task ReadLauncherAsync(CpuProcessChoice? choice, int version)
    {
        if (choice is null) { NotifyState(); return; }
        try
        {
            var snapshot = await App.Operations.ReadProcessControlsAsync(choice.Id);
            if (version != _version || _sessionRoot is not null) return;
            LoadCores(snapshot, snapshot.Controls["affinity"].Require().Deserialize<AffinityState>(OperationFiles.Json)!);
            _launcher = snapshot; Status = "Choose priorities and CPU cores, then review your changes."; Detail = "";
        }
        catch (Exception error) { if (version == _version) { Status = "Couldn't read this launcher."; Detail = error.Message; } }
        finally { if (version == _version) NotifyState(); }
    }

    private async Task ReadSessionLauncherAsync(GameSessionEntry entry, int version)
    {
        if (entry.Worker.HostRunning != true || entry.Worker.State is not { } state) return;
        try
        {
            var snapshot = await App.Operations.ReadProcessControlsAsync(state.Preview.Launcher.ProcessId);
            state.Preview.Launcher.Verify(snapshot.Identity);
            if (CpuSelection.Fingerprint(snapshot.Topology) != state.Preview.TopologyHash) throw new InvalidOperationException("CPU topology changed. Stop and review the session again.");
            if (version != _version) return;
            LoadCores(snapshot, state.Preview.OriginalAffinity); _launcher = snapshot;
            var selected = CoreChoices.FirstOrDefault(choice => ProcessTarget.ParseMask(choice.Affinity.Mask) == ProcessTarget.ParseMask(state.DesiredAffinity.Mask));
            if (selected is null) { selected = new("Custom cores", state.DesiredAffinity); CoreChoices.Add(selected); }
            SelectedCores = selected;
        }
        catch (Exception error) { if (version == _version) Detail = error.Message; }
        finally { if (version == _version) NotifyState(); }
    }

    private void LoadCores(ProcessControlSnapshot snapshot, AffinityState original)
    {
        if (snapshot.Topology.Select(cpu => cpu.Group).Distinct().Count() != 1) throw new InvalidOperationException("Game sessions currently support one processor group.");
        CoreChoices.Clear(); CoreChoices.Add(new("All allowed cores", original));
        if (snapshot.Topology.Select(cpu => cpu.Efficiency).Distinct().Count() > 1)
        {
            foreach (var kind in new[] { "performance", "efficiency" })
            {
                var efficiency = kind == "performance" ? snapshot.Topology.Max(cpu => cpu.Efficiency) : snapshot.Topology.Min(cpu => cpu.Efficiency);
                var allowed = ProcessTarget.ParseMask(original.Mask);
                var mask = snapshot.Topology.Where(cpu => cpu.Group == original.Group && cpu.Efficiency == efficiency && cpu.Available)
                    .Aggregate(0UL, (value, cpu) => value | (1UL << cpu.Index)) & allowed;
                if (mask != 0) CoreChoices.Add(new(kind == "performance" ? "Performance cores" : "Efficiency cores", new(original.Group, "0x" + mask.ToString("X"))));
            }
        }
        SelectedCores = CoreChoices[0];
    }

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (!CanPreview) return;
        Busy = true;
        try
        {
            var controls = Settings.Where(setting => setting.Selected.Value is not null).ToDictionary(setting => setting.Name, setting => setting.Selected.Value!.Value);
            if (controls.TryGetValue("executionQoS", out var qos))
                controls["executionQoS"] = JsonSerializer.SerializeToElement(new PowerThrottling(0, 0).WithExecutionMode(qos.GetString()!), OperationFiles.Json);
            var group = _launcher!.Controls["affinity"].Require().Deserialize<AffinityState>(OperationFiles.Json)!.Group;
            controls["affinity"] = JsonSerializer.SerializeToElement(new AffinityState(group, AffinityMask.Trim()), OperationFiles.Json);
            _review = await App.Operations.PreviewGameSessionAsync(SelectedLauncher!.Id, GamePath.Trim(), controls, AcceptLauncherScope);
            ReviewSummary = Path.GetFileName(_review.Plan.GamePath) + " via " + Path.GetFileName(_review.Plan.Launcher.ExecutablePath) + "\n" +
                string.Join("\n", Settings.Where(setting => setting.Selected.Value is not null).Select(setting => setting.Label + ": " + setting.Selected.Label)) +
                "\nCores: " + AffinityMask.Trim() + "\nLauncher core limits and I/O/memory defaults also affect its other new child processes. Launch priorities apply to this game filename.";
            Status = "Review these settings, then select Start."; Detail = "Launch the game normally after the session reports Ready.";
        }
        catch (Exception error) { _review = null; ReviewSummary = ""; Status = "Couldn't prepare this session."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task StartAsync()
    {
        if (!CanStart) return;
        var review = _review!;
        Busy = true; _sessionRoot = review.SessionRoot;
        try { ShowStatus(await App.Operations.StartGameSessionAsync(review)); }
        catch (Exception error)
        {
            Status = "Session startup needs attention."; Detail = error.Message;
            try { _current = await App.Operations.ReadGameSessionAsync(review.SessionRoot); }
            catch (Exception readError) { _current = new(null, null, readError.Message); }
        }
        finally { _review = null; ReviewSummary = ""; Busy = false; }
        await RefreshAsync();
    }

    [RelayCommand] private Task StopAsync() => ManageAsync(false);
    [RelayCommand] private Task RecoverAsync() => ManageAsync(true);
    private async Task ManageAsync(bool recover)
    {
        if (recover ? !CanRecover : !CanStop) return;
        Busy = true;
        _pendingAffinity = null;
        try { ShowStatus(recover ? await App.Operations.RecoverGameSessionAsync(_sessionRoot!) : await App.Operations.StopGameSessionAsync(_sessionRoot!)); }
        catch (Exception error) { Status = "Session needs attention."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task SwitchCoresAsync()
    {
        if (!CanSwitch) return;
        Busy = true;
        try
        {
            var requested = AffinityMask.Trim();
            _pendingAffinity = requested;
            ShowStatus(await App.Operations.SwitchGameCoresAsync(_sessionRoot!, requested));
            Detail = "Core switch requested: " + requested + ". Check the current CPU affinity below.";
        }
        catch (Exception error) { _pendingAffinity = null; Status = "Couldn't switch cores."; Detail = error.Message; }
        finally { Busy = false; }
    }

    public async Task ObserveAsync()
    {
        if (Busy || _observing || _sessionRoot is null) return;
        _observing = true; var root = _sessionRoot; var version = _version;
        try
        {
            var result = await App.Operations.ReadGameSessionAsync(root);
            if (!Busy && version == _version && root == _sessionRoot) ShowStatus(result);
        }
        catch (Exception error)
        {
            if (!Busy && version == _version) { _current = new(_current?.State, null, error.Message); Status = "Session status unavailable."; Detail = error.Message; Fields.Clear(); NotifyState(); }
        }
        finally { _observing = false; }
    }

    private void ShowStatus(ProtectedSessionStatus current)
    {
        if (current.HostRunning == false || _pendingAffinity is not null && GameSessionDisplay.CoresMatch(current, _pendingAffinity)) _pendingAffinity = null;
        _current = current; Status = GameSessionDisplay.Title(current, _pendingAffinity); Fields.Clear();
        Detail = current.Error ?? (current.State is { } state ? string.Join("\n", state.Errors) : "No session state was returned. Refresh before retrying.");
        if (current.State is { } session)
        {
            foreach (var game in session.Games.Where(game => !game.Exited))
                foreach (var field in game.Fields)
                {
                    var requested = session.Preview.Controls.TryGetValue(field.Name, out var desired) ? ProcessControlsViewModel.Describe(field.Name, desired) : "Unknown";
                    if (field.Name == "affinity") requested = _pendingAffinity ?? session.DesiredAffinity.Mask;
                    var known = field.Observed is { Known: true, Error: null, Value: not null };
                    var observed = known ? ProcessControlsViewModel.Describe(field.Name, field.Observed!.Require()) : "Unavailable";
                    if (field.Status == "released") observed = "Session limit removed";
                    else if (field.Status == "restartRequired" && known) observed = "Last: " + observed;
                    var result = field.Name == "affinity" && _pendingAffinity is not null ? "Waiting for core-switch readback" : FieldResult(field.Status);
                    if (current.HostRunning is null || current.Error is not null || current.HostRunning == true && DateTime.UtcNow - session.UpdatedAtUtc > TimeSpan.FromSeconds(15)) result = "Last recorded: " + result;
                    Fields.Add(new(ProcessControlsViewModel.Label(field.Name) + " · PID " + game.Identity.ProcessId, requested, observed,
                        result + (field.Error is null ? "" : " · " + field.Error)));
                }
        }
        NotifyState();
    }

    private void SettingChanged(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == nameof(GameSessionSetting.Selected)) Invalidate(); }
    private static string FieldResult(string status) => status switch
    {
        "applied" => "Applied", "pending" => "Waiting", "initializing" => "Graphics starting", "awaitingRecovery" => "Preparing restore",
        "unavailable" => "Unavailable", "conflict" => "Changed elsewhere", "notApplied" => "Not applied", "restartRequired" => "Restart required",
        "restored" => "Restored", "expired" => "Game exited", "released" => "Core restriction released", "reapplyIntent" => "Reapplying", _ => "Needs attention",
    };
    private void Invalidate() { _review = null; ReviewSummary = ""; NotifyState(); }
    private void NotifyState()
    {
        foreach (var name in new[] { nameof(CanEdit), nameof(HasLauncher), nameof(HasSession), nameof(HasReview), nameof(CanPreview), nameof(CanStart), nameof(CanStop), nameof(CanRecover), nameof(CanSwitch), nameof(CanChooseCores), nameof(CanChooseSession) }) OnPropertyChanged(name);
    }
}
