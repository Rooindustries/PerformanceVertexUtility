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
            .Where(option => LaunchSupported(name, option.Value))).ToArray();
        _selected = Options[0];
    }

    internal static bool LaunchSupported(string name, JsonElement? value) => value is not { } chosen || name switch
    {
        "cpuPriority" => LaunchPriorities.CpuPriorities.Contains(chosen.GetString()),
        "ioPriority" => chosen.GetInt32() <= LaunchPriorities.MaxIoPriority,
        "gpuPriority" => chosen.GetInt32() != 5,
        _ => true,
    };
}

public sealed record GameCoreChoice(string Label, AffinityState Affinity)
{
    public override string ToString() => Label;
}

public sealed class GameCoreBox(byte index, string kind, bool enabled) : ObservableObject
{
    private bool _isChecked;
    public byte Index { get; } = index;
    public ulong Bit => 1UL << Index;
    public string Label => "Core " + (Index + 1);
    public string Kind { get; } = kind;
    public bool Enabled { get; } = enabled;
    public string AutomationId => "GameSessionCore" + (Index + 1);
    public bool IsChecked { get => _isChecked; set => SetProperty(ref _isChecked, value && Enabled); }
}
public sealed record GameSessionField(string Label, string Requested, string Observed, string Result);
public sealed record LaunchProfileRow(string Root, string Title, string Status);

public partial class GameSessionViewModel : ObservableObject
{
    public static string? PresetsPath { get; set; }
    public ObservableCollection<CpuProcessChoice> Launchers { get; } = new();
    public ObservableCollection<GameSessionEntry> Sessions { get; } = new();
    public ObservableCollection<GameCoreBox> Cores { get; } = new();
    public ObservableCollection<GameCoreChoice> CoreChoices { get; } = new();
    public ObservableCollection<GameSessionField> Fields { get; } = new();
    public ObservableCollection<LaunchProfileRow> Profiles { get; } = new();
    public GameSessionSetting[] Settings { get; } = [new("cpuPriority"), new("ioPriority"), new("memoryPriority"), new("gpuPriority"), new("executionQoS"), new("priorityBoost")];
    public LaunchPreset[] Presets { get; private set; } = [];
    [ObservableProperty] private LaunchPreset? _selectedPreset;
    [ObservableProperty] private CpuProcessChoice? _selectedLauncher;
    [ObservableProperty] private GameSessionEntry? _selectedSession;
    [ObservableProperty] private string _gamePath = "";
    [ObservableProperty] private bool _keepArmed;
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
    private bool _matching;
    private bool _customPreset;
    private string? _presetsError;
    private ulong _coreMask;
    private ulong _allowedMask;
    private bool _syncingCores;

    public GameSessionViewModel()
    {
        foreach (var setting in Settings) setting.PropertyChanged += SettingChanged;
    }

    public bool CanEdit => !Busy && _sessionRoot is null;
    public bool HasLauncher => _launcher is not null || HasSession;
    public bool HasSession => _sessionRoot is not null;
    public bool HasReview => _review is not null;
    public bool CanPreview => CanEdit && _launcher is not null && SelectedLauncher?.Id == _launcher.Identity.ProcessId &&
        !string.IsNullOrWhiteSpace(GamePath) && _coreMask != 0;
    public bool CanStart => CanEdit && _review is not null;
    public bool CanStop => !Busy && HasSession && _current?.HostRunning != null && !GameSessionDisplay.Restored(_current);
    public bool CanRecover => !Busy && HasSession && _current?.HostRunning == false && _current.State is not null && !GameSessionDisplay.Restored(_current);
    private bool SessionTakesCores => !Busy && _pendingAffinity is null && _current is { HostRunning: true, Error: null, State: not null } current &&
        DateTime.UtcNow - current.State.UpdatedAtUtc <= TimeSpan.FromSeconds(15) && current.State.Preview.Controls.ContainsKey("affinity") && _launcher is not null;
    public bool CanSwitch => SessionTakesCores && _coreMask != 0;
    public bool CanChooseCores => CanEdit || SessionTakesCores;
    public bool CanChooseSession => !Busy;
    private bool AnyChosen => Settings.Any(setting => setting.Selected.Value is not null);
    public string PresetPlaceholder => _customPreset || AnyChosen ? LaunchPresetCatalog.Custom : "Choose a preset";
    public string PresetHint => _presetsError ?? SelectedPreset?.Description
        ?? (_customPreset || AnyChosen ? "Your own mix. Picking a preset changes the priorities but keeps your cores." : "Pick one to fill in the settings below. You can still change them.");

    public string AffinityMask => _coreMask == 0 ? "" : "0x" + _coreMask.ToString("X");
    public bool AllCores
    {
        get => Cores.Any(box => box.Enabled) && Cores.Where(box => box.Enabled).All(box => box.IsChecked);
        set
        {
            if (value != AllCores && CanChooseCores) SetCores(value ? _allowedMask : 0);
            else OnPropertyChanged();
        }
    }
    public string CoresText => CoreText(_coreMask, _allowedMask);
    public string CoresSummary => "Cores: " + CoresText;
    public bool ShowCoresSummary => Cores.Count == 0 && _coreMask != 0;
    public string CoreHint => Cores.Count > 0 && _coreMask == 0 ? "Pick at least one core." : "";
    private static string CoreText(ulong mask, ulong allowed) => mask == allowed ? "all" : ProcessControlsViewModel.CoreRanges(mask);
    private static ulong Mask(string? text)
    {
        try { return string.IsNullOrWhiteSpace(text) ? 0 : ProcessTarget.ParseMask(text.Trim()); }
        catch (Exception error) when (error is FormatException or OverflowException or ArgumentException) { return 0; }
    }

    public void UseCoreChoice(GameCoreChoice choice)
    {
        if (!CanChooseCores) return;
        var usable = Cores.Where(box => box.Enabled).Aggregate(0UL, (mask, box) => mask | box.Bit);
        var chosen = Mask(choice.Affinity.Mask) & usable;
        SetCores(chosen != 0 && chosen == usable ? _allowedMask : chosen);
    }

    private void SetCores(ulong mask)
    {
        _coreMask = mask;
        _syncingCores = true;
        try { foreach (var box in Cores) box.IsChecked = (mask & box.Bit) != 0; }
        finally { _syncingCores = false; }
        CoresChanged();
    }

    private void CoreChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_syncingCores || args.PropertyName != nameof(GameCoreBox.IsChecked)) return;
        var usable = Cores.Where(box => box.Enabled).ToArray();
        _coreMask = usable.Length > 0 && usable.All(box => box.IsChecked) ? _allowedMask : usable.Where(box => box.IsChecked).Aggregate(0UL, (mask, box) => mask | box.Bit);
        CoresChanged();
    }

    private void ClearCores()
    {
        foreach (var box in Cores) box.PropertyChanged -= CoreChanged;
        Cores.Clear(); CoreChoices.Clear(); _coreMask = 0; _allowedMask = 0;
        CoresChanged();
    }

    private void CoresChanged()
    {
        Invalidate();
        foreach (var name in new[] { nameof(AffinityMask), nameof(AllCores), nameof(CoresText), nameof(CoresSummary), nameof(ShowCoresSummary), nameof(CoreHint) }) OnPropertyChanged(name);
    }

    partial void OnSelectedPresetChanged(LaunchPreset? value)
    {
        if (!_matching && value is not null)
        {
            Invalidate();
            _customPreset = false;
            _matching = true;
            try
            {
                foreach (var setting in Settings)
                    setting.Selected = value.Settings.TryGetValue(setting.Name, out var chosen) ? setting.Options.Single(option => option.Value?.GetRawText() == chosen.GetRawText()) : setting.Options[0];
            }
            finally { _matching = false; }
        }
        OnPropertyChanged(nameof(PresetPlaceholder)); OnPropertyChanged(nameof(PresetHint));
    }

    partial void OnBusyChanged(bool value) => NotifyState();
    partial void OnGamePathChanged(string value) => Invalidate();
    partial void OnKeepArmedChanged(bool value) => Invalidate();
    public void NoteChanged()
    {
        Status = "Settings changed elsewhere";
        Detail = "Choose the launcher again, or clear it, to read its current values.";
    }
    partial void OnSelectedLauncherChanged(CpuProcessChoice? value)
    {
        if (_sessionRoot is not null) return;
        Invalidate(); _launcher = null; ClearCores();
        _ = ReadLauncherAsync(value, ++_version);
    }
    partial void OnSelectedSessionChanged(GameSessionEntry? value)
    {
        ++_version; _review = null; ReviewSummary = ""; _launcher = null; ClearCores();
        _pendingAffinity = null;
        _sessionRoot = value?.SessionRoot; _current = value?.Worker; KeepArmed = value?.ProfileId is not null;
        if (value is not null)
        {
            if (value.Worker.State is { } state)
            {
                GamePath = state.Preview.GamePath;
                var launcher = new CpuProcessChoice(state.Preview.Launcher.ProcessId, Path.GetFileName(state.Preview.Launcher.ExecutablePath));
                if (!Launchers.Contains(launcher)) Launchers.Add(launcher);
                SelectedLauncher = launcher;
                foreach (var setting in Settings)
                {
                    if (!state.Preview.Controls.TryGetValue(setting.Name, out var desired)) { setting.Selected = setting.Options[0]; continue; }
                    if (setting.Name == "executionQoS") desired = JsonSerializer.SerializeToElement(desired.Deserialize<PowerThrottling>(OperationFiles.Json)!.ExecutionMode);
                    setting.Selected = setting.Options.FirstOrDefault(option => option.Value?.GetRawText() == desired.GetRawText()) ?? setting.Options[0];
                }
                _allowedMask = Mask(state.Preview.OriginalAffinity.Mask); SetCores(Mask(state.DesiredAffinity.Mask));
                MatchPreset();
            }
            ShowStatus(value.Worker); _ = ReadSessionLauncherAsync(value, _version);
        }
        NotifyState();
    }

    public async Task InitializeAsync()
    {
        LoadPresets();
        await RefreshAsync();
        await RefreshProfilesAsync();
        if (SelectedSession is null && Sessions.Count > 0)
            SelectedSession = Sessions.FirstOrDefault(entry => !GameSessionDisplay.Restored(entry.Worker)) ?? Sessions[0];
    }

    private void LoadPresets()
    {
        try { Presets = LaunchPresetCatalog.Read(PresetsPath ?? throw new FileNotFoundException("The launch preset list isn't installed.")).Presets; _presetsError = null; }
        catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
        {
            Presets = [];
            _presetsError = "Launch presets couldn't be loaded: " + error.Message; AppLog.Write("games", _presetsError);
        }
        OnPropertyChanged(nameof(Presets)); MatchPreset();
    }

    private void MatchPreset()
    {
        var controls = SettingControls();
        _matching = true;
        try { SelectedPreset = Presets.FirstOrDefault(preset => preset.Matches(controls)); }
        finally { _matching = false; }
        _customPreset = SelectedPreset is null && (AnyChosen || _sessionRoot is not null);
        OnPropertyChanged(nameof(PresetPlaceholder)); OnPropertyChanged(nameof(PresetHint));
    }

    private string PresetLabel(Dictionary<string, JsonElement> controls) => Presets.FirstOrDefault(preset => preset.Matches(controls)) is { } preset ? " · " + preset.Name + " preset" : "";

    private Dictionary<string, JsonElement> SettingControls()
    {
        var controls = Settings.Where(setting => setting.Selected.Value is not null).ToDictionary(setting => setting.Name, setting => setting.Selected.Value!.Value);
        if (controls.TryGetValue("executionQoS", out var qos))
            controls["executionQoS"] = JsonSerializer.SerializeToElement(new PowerThrottling(0, 0).WithExecutionMode(qos.GetString()!), OperationFiles.Json);
        return controls;
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
        SelectedSession = null; _sessionRoot = null; _current = null; KeepArmed = false; Fields.Clear();
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
            if (!string.IsNullOrWhiteSpace(GamePath) && string.Equals(Path.GetFileName(snapshot.Identity.ExecutablePath), Path.GetFileName(GamePath.Trim()), StringComparison.OrdinalIgnoreCase))
            {
                Status = "That's the game, not its launcher."; Detail = ProtectedSessions.LauncherIsGame; return;
            }
            LoadCores(snapshot, snapshot.Controls["affinity"].Require().Deserialize<AffinityState>(OperationFiles.Json)!);
            _launcher = snapshot; Status = "Choose priorities and CPU cores, then review your changes."; Detail = "";
        }
        catch (Exception error) { if (version == _version) { Status = "Couldn't read this launcher."; Detail = Closed(error) ? ProtectedSessions.LauncherClosed : error.Message; } }
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
            SetCores(Mask(state.DesiredAffinity.Mask));
            MatchPreset();
        }
        catch (Exception error) { if (version == _version) Detail = error.Message; }
        finally { if (version == _version) NotifyState(); }
    }

    private static bool Closed(Exception error)
        => error is ProcessEndedException || error.Message.Contains("OpenProcess failed with Win32 87", StringComparison.Ordinal) || error.Message == "The target process has exited.";

    private void LoadCores(ProcessControlSnapshot snapshot, AffinityState original)
    {
        if (snapshot.Topology.Select(cpu => cpu.Group).Distinct().Count() != 1) throw new InvalidOperationException("Game sessions currently support one processor group.");
        ClearCores();
        var allowed = ProcessTarget.ParseMask(original.Mask);
        var hybrid = snapshot.Topology.Select(cpu => cpu.Efficiency).Distinct().Count() > 1;
        var performance = snapshot.Topology.Max(cpu => cpu.Efficiency);
        foreach (var cpu in snapshot.Topology.Where(cpu => cpu.Group == original.Group && cpu.Index < 64).OrderBy(cpu => cpu.Index))
        {
            var box = new GameCoreBox(cpu.Index, hybrid ? cpu.Efficiency == performance ? "Performance" : "Efficiency" : "", cpu.Available && (allowed & (1UL << cpu.Index)) != 0);
            box.PropertyChanged += CoreChanged; Cores.Add(box);
        }
        if (hybrid)
        {
            foreach (var kind in new[] { "performance", "efficiency" })
            {
                var efficiency = kind == "performance" ? snapshot.Topology.Max(cpu => cpu.Efficiency) : snapshot.Topology.Min(cpu => cpu.Efficiency);
                var mask = snapshot.Topology.Where(cpu => cpu.Group == original.Group && cpu.Efficiency == efficiency && cpu.Available)
                    .Aggregate(0UL, (value, cpu) => value | (1UL << cpu.Index)) & allowed;
                if (mask != 0) CoreChoices.Add(new(kind == "performance" ? "Performance cores" : "Efficiency cores", new(original.Group, "0x" + mask.ToString("X"))));
            }
        }
        _allowedMask = allowed; SetCores(allowed);
    }

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (!CanPreview) return;
        Busy = true;
        try
        {
            var controls = SettingControls();
            var group = _launcher!.Controls["affinity"].Require().Deserialize<AffinityState>(OperationFiles.Json)!.Group;
            controls["affinity"] = JsonSerializer.SerializeToElement(new AffinityState(group, AffinityMask), OperationFiles.Json);
            _review = await App.Operations.PreviewGameSessionAsync(SelectedLauncher!.Id, GamePath.Trim(), controls, acceptLauncherScope: true);
            var launcher = Path.GetFileName(_review.Plan.Launcher.ExecutablePath);
            var original = Mask(_review.Plan.OriginalAffinity.Mask);
            var shared = new[] { _coreMask != original ? "cores" : null, controls.ContainsKey("ioPriority") ? "disk priority" : null, controls.ContainsKey("memoryPriority") ? "memory priority" : null }
                .OfType<string>().ToArray();
            var lines = new List<string> { Path.GetFileName(_review.Plan.GamePath) + " via " + launcher };
            if (SelectedPreset is { } preset) lines.Add("Preset: " + preset.Name);
            lines.AddRange(Settings.Where(setting => setting.Selected.Value is not null).Select(setting => setting.Label + ": " + setting.Selected.Label));
            lines.Add("Cores: " + CoreText(_coreMask, original));
            if (shared.Length > 0) lines.Add("Other apps this launcher opens get the same " + (shared.Length == 1 ? shared[0] : string.Join(", ", shared[..^1]) + " and " + shared[^1]) + ".");
            if (KeepArmed) lines.Add("Saved for next time: these turn back on whenever " + launcher + " opens while this app is open. After a restart, open the app once and they're back. Turn them off under Saved launch settings.");
            ReviewSummary = string.Join("\n", lines);
            Status = "Review these settings, then select Start."; Detail = "Launch the game normally after the session reports Ready.";
        }
        catch (Exception error) { _review = null; ReviewSummary = ""; Status = "Couldn't prepare this session."; Detail = Closed(error) ? ProtectedSessions.LauncherClosed : error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task StartAsync()
    {
        if (!CanStart) return;
        var review = _review!;
        var keep = KeepArmed;
        if (keep)
        {
            try { App.Operations.RequireNoLaunchProfile(review.Plan); }
            catch (Exception error) { Status = "Couldn't save these settings for next time."; Detail = error.Message; return; }
        }
        Busy = true; _sessionRoot = review.SessionRoot;
        string? saved = null;
        try
        {
            ShowStatus(await App.Operations.StartGameSessionAsync(review));
            if (keep)
            {
                try { await App.Operations.SaveLaunchProfileAsync(review); saved = "Saved for next time. These settings turn back on whenever " + Path.GetFileName(review.Plan.Launcher.ExecutablePath) + " opens while the app is open."; }
                catch (Exception error) { saved = "The session started, but its settings weren't saved for next time: " + error.Message; }
            }
        }
        catch (Exception error)
        {
            Status = "Session startup needs attention."; Detail = error.Message;
            try { _current = await App.Operations.ReadGameSessionAsync(review.SessionRoot); }
            catch (Exception readError) { _current = new(null, null, readError.Message); }
        }
        finally { _review = null; ReviewSummary = ""; Busy = false; }
        await RefreshAsync();
        await RefreshProfilesAsync();
        if (saved is not null) Detail = saved;
    }

    public async Task RefreshProfilesAsync()
    {
        try
        {
            var rows = (await App.Operations.ReadLaunchProfilesAsync()).Select(entry => new LaunchProfileRow(entry.Root, entry.Title + PresetLabel(entry.Saved.Controls), OptimizerService.DescribeLaunchProfile(entry))).ToArray();
            if (rows.SequenceEqual(Profiles)) return;
            Profiles.Clear(); foreach (var row in rows) Profiles.Add(row);
        }
        catch (Exception error) { AppLog.Write("profiles", "Saved launch settings couldn't be listed: " + error.Message); }
    }

    public async Task TurnOffProfileAsync(LaunchProfileRow row)
    {
        while (Busy) await Task.Delay(100);
        if (Profiles.FirstOrDefault(item => item.Root == row.Root) is not { } current) return;
        row = current;
        Busy = true;
        string status, detail;
        try
        {
            var problem = await App.Operations.DisableLaunchProfileAsync(row.Root);
            status = problem is null ? "Saved settings turned off" : "Saved settings turned off, but a session needs attention";
            detail = problem ?? row.Title + " is back to its original settings. They won't turn on again by themselves.";
        }
        catch (Exception error) { status = "Couldn't turn off the saved settings."; detail = error.Message; }
        finally { Busy = false; }
        await RefreshAsync();
        await RefreshProfilesAsync();
        Status = status; Detail = detail;
    }

    public async Task SessionsChangedAsync()
    {
        await RefreshProfilesAsync();
        if (Busy || _review is not null || _sessionRoot is null && (SelectedLauncher is not null || !string.IsNullOrWhiteSpace(GamePath))) return;
        if (!await TryRefreshAsync()) return;
        if (SelectedSession is { } current && !GameSessionDisplay.Restored(current.Worker)) return;
        if (Sessions.FirstOrDefault(entry => !GameSessionDisplay.Restored(entry.Worker)) is { } armed) SelectedSession = armed;
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
            var requested = AffinityMask;
            var text = CoresText;
            _pendingAffinity = requested;
            ShowStatus(await App.Operations.SwitchGameCoresAsync(_sessionRoot!, requested));
            Detail = (text == "all" ? "Switching to all cores" : "Switching to cores " + text) + ". Check Current below.";
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
            var games = session.Games.Where(game => !game.Exited).ToArray();
            foreach (var game in games)
                foreach (var field in game.Fields)
                {
                    var requested = session.Preview.Controls.TryGetValue(field.Name, out var desired) ? ProcessControlsViewModel.Describe(field.Name, desired) : "Unknown";
                    if (field.Name == "affinity")
                    {
                        var cores = _pendingAffinity ?? session.DesiredAffinity.Mask;
                        requested = Mask(cores) == Mask(session.Preview.OriginalAffinity.Mask) ? "All cores" : ProcessControlsViewModel.CoreList(cores);
                    }
                    var known = field.Observed is { Known: true, Error: null, Value: not null };
                    var observed = known ? ProcessControlsViewModel.Describe(field.Name, field.Observed!.Require()) : "Unavailable";
                    if (known && field.Name == "affinity" && field.Observed!.Require().Deserialize<AffinityState>(OperationFiles.Json) is { } now &&
                        now.Group == session.Preview.OriginalAffinity.Group && Mask(now.Mask) == Mask(session.Preview.OriginalAffinity.Mask)) observed = "All cores";
                    if (field.Status == "released") observed = "Session limit removed";
                    else if (field.Status == "restartRequired" && known) observed = "Last: " + observed;
                    var result = field.Name == "affinity" && _pendingAffinity is not null ? "Switching cores" : FieldResult(field.Status);
                    if (current.HostRunning is null || current.Error is not null || current.HostRunning == true && DateTime.UtcNow - session.UpdatedAtUtc > TimeSpan.FromSeconds(15)) result = "Last recorded: " + result;
                    Fields.Add(new(ProcessControlsViewModel.Label(field.Name) + (games.Length > 1 ? " · PID " + game.Identity.ProcessId : ""), requested, observed,
                        result + (field.Error is null ? "" : " · " + field.Error)));
                }
        }
        NotifyState();
    }

    private void SettingChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(GameSessionSetting.Selected)) return;
        Invalidate();
        UseCustomPreset();
    }
    private void UseCustomPreset()
    {
        if (_matching) return;
        _customPreset = true; SelectedPreset = null;
        OnPropertyChanged(nameof(PresetPlaceholder)); OnPropertyChanged(nameof(PresetHint));
    }
    private static string FieldResult(string status) => status switch
    {
        "applied" => "Applied", "pending" => "Waiting", "initializing" => "Graphics starting", "awaitingRecovery" => "Preparing restore",
        "unavailable" => "Unavailable", "conflict" => "Changed elsewhere", "notApplied" => "Not applied", "restartRequired" => "Restart required",
        "restored" => "Restored", "expired" => "Game exited", "released" => "Core limit removed", "reapplyIntent" => "Reapplying", _ => "Needs attention",
    };
    private void Invalidate() { _review = null; ReviewSummary = ""; NotifyState(); }
    private void NotifyState()
    {
        foreach (var name in new[] { nameof(CanEdit), nameof(HasLauncher), nameof(HasSession), nameof(HasReview), nameof(CanPreview), nameof(CanStart), nameof(CanStop), nameof(CanRecover), nameof(CanSwitch), nameof(CanChooseCores), nameof(CanChooseSession) }) OnPropertyChanged(name);
    }
}
