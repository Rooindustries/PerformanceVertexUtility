using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Security.AccessControl;
using System.Security.Principal;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public sealed record TweakChoice(string Id, string Name)
{
    public override string ToString() => Name;
}
public sealed record TweakAlternative(string Name, IRelayCommand OpenCommand);
public partial class WindowsTweakRow : ObservableObject
{
    public TweakDefinition Definition { get; }
    public string Id => Definition.Id;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(DetailsAccessibleName))]
    [NotifyPropertyChangedFor(nameof(ActionAccessibleName))]
    [NotifyPropertyChangedFor(nameof(SelectionAccessibleName))]
    [NotifyPropertyChangedFor(nameof(CurrentAccessibleName))]
    private string _name;
    public string Category => Definition.Category;
    public TweakPresentation Presentation { get; }
    public string SectionId => Presentation.Section;
    public string Topic => Presentation.Topic ?? Category;
    public string Icon => WindowsTweakPresentation.Icon(Definition);
    public bool IsNetwork => SectionId == "network";
    public string Scope => Definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address.Kind == "timer-startup") ? "This user" : Definition.Options.SelectMany(option => option.Changes).FirstOrDefault()?.Address.Hive switch
    {
        "CurrentUser" => "This user", "Users" => "Sign-in screen", "LocalMachine" => "Entire PC", _ => "This PC",
    };
    public string Context => Topic + " · " + Scope;
    public string Description => Presentation.Summary ?? Presentation.Description ?? "";
    public string Help => Presentation.Description ?? Definition.Description;
    public string Sources => string.Join(" · ", Definition.Sources.Select(source => source.Product).Distinct());
    public string Refresh => Definition.Refresh.StartsWith("Policy supports live refresh", StringComparison.OrdinalIgnoreCase) ? "" : Definition.Refresh switch { "none" => "", "restart" => "Restart Windows after applying", "sign-out" => "Sign out after applying", "reopen affected apps" => "Reopen affected apps after applying", "explorer-refresh" => "Reopen Explorer after applying", "new-windows-or-sign-out" => "Reopen affected apps or sign out", _ => Definition.Refresh };
    public string RefreshLabel => Definition.Refresh switch
    {
        "restart" or "Restart Windows." or "Restart Windows to activate adapter DNS settings." => "Restart Windows",
        "sign-out" => "Sign out",
        "reopen affected apps" or "Restart apps already open when policy changed." => "Reopen apps",
        "explorer-refresh" or "Refresh File Explorer." => "Reopen Explorer",
        "new-windows-or-sign-out" => "Reopen apps or sign out",
        "Browser restart required." => "Restart browser",
        "Restart Outlook." => "Restart Outlook",
        "Restart affected game." => "Restart game",
        "Adapter capability and provider determine whether reconnection/restart is needed." => "May need reconnect/restart",
        "Use input-settings refresh; verify effective cursor behavior." => "Refresh input settings",
        "Notify shell and affected apps; recheck visible result." => "Refresh shell and apps",
        "Sign out or restart Explorer as required by target build." => "Sign out/reopen Explorer",
        "Next applicable crash screen; do not trigger a crash to test." => "Next crash screen",
        "Next sign-in or sign-out." => "Next sign-in/out",
        "Restart affected applications; some existing processes may require reboot." => "May need app/PC restart",
        "Refresh taskbar." => "Refresh taskbar",
        _ => Refresh.Length == 0 ? "" : "See details",
    };
    public string DetailsAccessibleName => Name + " details";
    public string ActionAccessibleName => "Change " + Name + " to";
    public string SelectionAccessibleName => "Select " + Name + " for review";
    public string CurrentAccessibleName => Name + ": current value " + Current;
    public string ScopeAndRefresh => RefreshLabel.Length == 0 ? Scope : Scope + " · " + RefreshLabel;
    public string ActionAutomationId => Id + ".value";
    public string SelectionAutomationId => Id + ".select";
    public string DetailsAutomationId => Id + ".details";
    public TweakChoice[] Choices { get; }
    public TweakChoice[] ActionChoices { get; }
    public TweakAlternative[] Alternatives { get; }
    private TweakChoice _action;
    private bool _actionPicked;
    public TweakChoice Action
    {
        get => _action;
        set
        {
            if (value is null || !ActionChoices.Contains(value) || !SetProperty(ref _action, value)) return;
            _actionPicked = true;
            if (ToggleOn) Selected = value == AppliedChoice ? Choices[0] : value;
            OnPropertyChanged(nameof(ActionNote));
        }
    }
    private TweakChoice _selected;
    public TweakChoice Selected
    {
        get => _selected;
        set
        {
            if (value is null) return;
            var turningOff = _queuingRevert; _queuingRevert = false;
            if (!SetProperty(ref _selected, value)) { if (_pendingOff != turningOff) { _pendingOff = turningOff; SyncToggle(); NotifyPending(); } return; }
            _pendingOff = turningOff;
            if (!_pendingOff) AppliedChoice = FindApplied(_observed);
            if (value.Id.Length > 0 && !_pendingOff && ActionChoices.Contains(value)) _action = value;
            else if (value.Id.Length == 0 && AppliedChoice is not null) _action = AppliedChoice;
            SyncToggle(); NotifyPending(); OnPropertyChanged(nameof(Action)); OnPropertyChanged(nameof(ActionNote)); OnPropertyChanged(nameof(CanApplySelected)); OnPropertyChanged(nameof(ChoiceStatus));
        }
    }
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CurrentAccessibleName))]
    private string _current = "Not checked";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private bool _available;
    [ObservableProperty] private bool _toggleOn;
    private bool _syncingToggle;
    private bool _pendingOff;
    private bool _queuingRevert;
    private readonly TweakChoice _recommended;
    private readonly HashSet<string> _resetIds;
    private TweakSettingStatus? _observed;
    public TweakChoice? AppliedChoice { get; private set; }
    public bool IsApplied => AppliedChoice is not null;
    private static readonly string[] LackedHere = ["Win32 1060", "0x80070002", "Windows driver", "Office installation", "devices expose", "No active adapter", "is not installed", "is not available with", "Hard-linked file permissions", "doesn't let administrators change the"];
    private static bool PcLacks(string error) => !error.Contains("couldn't load its PowerShell commands", StringComparison.Ordinal)
        && (error.StartsWith("No choice applies", StringComparison.Ordinal) || LackedHere.Any(text => error.Contains(text, StringComparison.Ordinal)));
    private static bool NoRawPolicy(System.Text.Json.JsonElement value) => value.TryGetProperty(MitigationControl.SnapshotField, out var raw) && raw.ValueKind == System.Text.Json.JsonValueKind.Object
        && raw.TryGetProperty("MitigationOptions", out var options) && options.ValueKind == System.Text.Json.JsonValueKind.Null && raw.TryGetProperty("MitigationAuditOptions", out var audit) && audit.ValueKind == System.Text.Json.JsonValueKind.Null;
    private static string[] MitigationFields(TweakDefinition definition) => definition.Options.SelectMany(option => option.Controls ?? []).Where(control => control.Address.Kind == "mitigations" && control.Value.ValueKind == System.Text.Json.JsonValueKind.Object)
        .SelectMany(control => control.Value.EnumerateObject()).Where(property => property.Value.ValueKind is System.Text.Json.JsonValueKind.String or System.Text.Json.JsonValueKind.False or System.Text.Json.JsonValueKind.True).Select(property => property.Name).Distinct(StringComparer.Ordinal).ToArray();
    private static string? RegistryText(RegistryValueData value) => value.Type switch
    {
        4 when value.Bytes.Length == 4 => BitConverter.ToUInt32(value.Bytes).ToString(System.Globalization.CultureInfo.InvariantCulture),
        11 when value.Bytes.Length == 8 => BitConverter.ToUInt64(value.Bytes).ToString(System.Globalization.CultureInfo.InvariantCulture),
        1 or 2 when value.Bytes.Length % 2 == 0 && System.Text.Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0') is { Length: > 0 and <= 40 } text && !text.Contains('\0') => text,
        _ => null,
    };
    private static bool WindowsDefault(TweakSettingStatus status, Dictionary<string, System.Text.Json.JsonElement> defaults) =>
        status.Observations.All(read => read.Value is not { } data || defaults.TryGetValue(read.Address.ValueName!, out var value) && (value.ValueKind == System.Text.Json.JsonValueKind.Number
            ? data is { Type: 4, Bytes.Length: 4 } && value.TryGetUInt32(out var number) && BitConverter.ToUInt32(data.Bytes) == number
            : value.ValueKind == System.Text.Json.JsonValueKind.String && data is { Type: 1 or 2 } && data.Bytes.Length % 2 == 0 && System.Text.Encoding.Unicode.GetString(data.Bytes).TrimEnd('\0') == value.GetString()))
        && (status.Controls ?? []).All(control => defaults.TryGetValue(control.Address.Property, out var value) && ControlValues.Equal(control.Value, value));
    private bool PerDevice => Definition.Options.Any(option => option.Changes.Any(change => change.Selector is not null) || (option.Controls ?? []).Any(control => control.Address.Kind is "device-power" or "network-adapter"));
    private static bool DevicesDiffer(TweakSettingStatus status) => status.Observations is [var first, _, ..] observed && observed.Any(read => !TweakRead.SameValue(read.Value, first.Value))
        || status.Controls is [{ Value.ValueKind: System.Text.Json.JsonValueKind.Object } control] && control.Value.EnumerateObject().Select(device => device.Value.GetRawText()).Distinct(StringComparer.Ordinal).Count() > 1;
    private static string? AdapterFields(TweakControlRead control)
    {
        var devices = control.Value.EnumerateObject().Select(device => device.Value).ToArray();
        if (devices.Length == 0 || devices.Any(device => device.ValueKind != System.Text.Json.JsonValueKind.Object || device.GetRawText() != devices[0].GetRawText())
            || devices[0].EnumerateObject().Any(field => field.Value.ValueKind is not (System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False))) return null;
        var on = devices[0].EnumerateObject().Where(field => field.Value.ValueKind == System.Text.Json.JsonValueKind.True).Select(field => field.Name switch { "ipv4v1" => "IPv4 version 1", "ipv4" => "IPv4", "ipv6" => "IPv6", _ => field.Name }).ToArray();
        return on.Length == 0 ? null : "On for " + (on.Length == 1 ? on[0] : string.Join(", ", on[..^1]) + " and " + on[^1]);
    }
    private static string? ServiceState(TweakControlRead control) => (control.Address.Property, control.Value.ValueKind) switch
    {
        ("startup", System.Text.Json.JsonValueKind.Number) => control.Value.GetInt32() switch { 0 => "Boot", 1 => "System", 2 => "Automatic", 3 => "Manual", 4 => "Disabled", _ => null },
        ("running", System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False) => control.Value.GetBoolean() ? "Running" : "Stopped",
        ("delayed-start", System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False) => control.Value.GetBoolean() ? "Delayed start" : "No delayed start",
        _ => null,
    };
    public bool CouldNotCheck => _observed is { Error: { } error } && error != TweakEngine.FeaturesPending && !PcLacks(error);
    public bool CanRetry => CouldNotCheck;
    public RelayCommand RetryCommand { get; }
    public string RetryAutomationId => Id + ".retry";
    public bool UnavailableHere => !CouldNotCheck && _observed is { } status && (status.Supported == false || status.Error is { } error && PcLacks(error) || _onlyDefaultHere);
    public bool HasPendingChange => Selected.Id.Length > 0 && Selected != AppliedChoice;
    public TweakChoice? RevertChoice => ActionChoices.FirstOrDefault(choice => _resetIds.Contains(choice.Id))
        ?? (ActionChoices.Length == 2 && AppliedChoice is not null ? ActionChoices.First(choice => choice != AppliedChoice) : null);
    public string StateLabel => _pendingOff ? "Will turn off" : HasPendingChange ? "Will turn on" : IsApplied ? "On" : "Off";
    public bool HasToggle => ActionChoices.Length > 0;
    public bool HasValuePicker => ActionChoices.Length > 1;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowValuePicker))]
    [NotifyPropertyChangedFor(nameof(ShowValueText))]
    [NotifyPropertyChangedFor(nameof(SimpleState))]
    private bool _showDetails = true;
    public bool ShowValuePicker => ShowDetails && HasValuePicker;
    public bool ShowValueText => ShowDetails && !HasValuePicker;
    public string SimpleState => ShowDetails ? "" : CouldNotCheck ? "Couldn't check" : HasPendingChange || _pendingOff ? StateLabel + " · " + Action.Name : IsApplied ? "On · " + Action.Name : "";
    public string ToggleOnLabel => "On";
    public string ToggleOffLabel => "Off";
    public string ActionNote => Action.Name == "Use Windows default" ? "Clears this local override. Another Windows policy may still control the setting." : "";
    public bool CanApplySelected => CanApplyChoice(Selected.Id);
    public bool CanApplyChoice(string id) => id.Length > 0 && Available && _observed?.AvailableChoices?.Contains(id) != false;
    public string ChoiceStatus => _cannotRevert ? "Already on. This one can't be turned off from here." : Selected.Id.Length == 0 || CanApplySelected ? "" : "Selected · save for later";
    private bool _cannotRevert;
    private bool _onlyDefaultHere;
    partial void OnToggleOnChanged(bool value)
    {
        if (_syncingToggle || !HasToggle) return;
        _cannotRevert = false;
        if (value) Selected = Action == AppliedChoice ? Choices[0] : Action;
        else if (!IsApplied) Selected = Choices[0];
        else if (RevertChoice is { } revert) { _queuingRevert = true; Selected = revert; }
        else { _cannotRevert = true; Selected = Choices[0]; }
        SyncToggle(); NotifyPending();
    }
    private void SyncToggle()
    {
        _syncingToggle = true;
        ToggleOn = Selected.Id.Length > 0 ? !_pendingOff : IsApplied;
        _syncingToggle = false;
    }
    private void NotifyPending()
    {
        OnPropertyChanged(nameof(HasPendingChange)); OnPropertyChanged(nameof(StateLabel)); OnPropertyChanged(nameof(ChoiceStatus)); OnPropertyChanged(nameof(SimpleState));
    }
    private TweakChoice? FindApplied(TweakSettingStatus? status)
    {
        if (status is not { Supported: true, Error: null }) return null;
        var configured = ActionChoices.Where(choice => !_resetIds.Contains(choice.Id) && status.ConfiguredChoices.Contains(choice.Id)).ToArray();
        return configured.FirstOrDefault(choice => choice == _selected) ?? configured.FirstOrDefault(choice => choice == _recommended) ?? (_resetIds.Count > 0 ? configured.FirstOrDefault() : null);
    }
    public WindowsTweakRow(TweakDefinition definition, IReadOnlyDictionary<string, TweakDefinition> definitions, Action<string> showSetting, Action? retry = null)
    {
        RetryCommand = new RelayCommand(() => retry?.Invoke());
        Definition = definition; Presentation = WindowsTweakPresentation.For(definition); _name = Presentation.Name ?? definition.Name;
        Alternatives = (definition.Alternatives ?? []).Where(definitions.ContainsKey).Select(id => new TweakAlternative(
            (WindowsTweakPresentation.For(definitions[id]).Name ?? definitions[id].Name) + (definitions[id].Options.SelectMany(option => option.Changes).FirstOrDefault()?.Address.Hive == "LocalMachine" ? " · Entire PC" : " · This user"),
            new RelayCommand(() => showSetting(id)))).ToArray();
        Choices = [new("", "Keep current"), .. definition.Options.Where(option => option.SameAs is null).Select(option => new TweakChoice(option.Id, DisplayChoice(WindowsTweakPresentation.Choice(definition, option))))];
        ActionChoices = Choices.Skip(1).ToArray();
        _resetIds = definition.Options.Where(option => IsDefaultAction(option.Name) || IsDefaultAction(WindowsTweakPresentation.Choice(definition, option))).Select(option => option.Id).ToHashSet();
        _action = ActionChoices.FirstOrDefault(choice => !_resetIds.Contains(choice.Id)) ?? ActionChoices.First();
        _recommended = _action;
        _selected = Choices[0];
    }
    public static bool ReadableName(string name) => name.Trim().Length > 0 && char.IsLetterOrDigit(name.Trim()[0]);
    public static string DisplayChoice(string name) => name is "Remove this override" or "Not configured" ? "Use Windows default" : name;
    public string ChoiceId(string optionId) => Definition.Options.FirstOrDefault(option => option.Id == optionId)?.SameAs ?? optionId;
    private static bool IsDefaultAction(string name) => name is "Remove this override" or "Windows default" or "Use Windows default" or "Not configured" or "source-default" or "Return to previous plan" or "Remove boot override";
    public void Observe(TweakSettingStatus? status, TweakContext? context = null)
    {
        _observed = status;
        AppliedChoice = FindApplied(status);
        _cannotRevert = false;
        if (AppliedChoice is not null && Selected.Id.Length == 0 && _action != AppliedChoice) { _action = AppliedChoice; OnPropertyChanged(nameof(Action)); OnPropertyChanged(nameof(ActionNote)); }
        else if (AppliedChoice is null && Selected.Id.Length == 0 && !_actionPicked && _action == _recommended && status?.AvailableChoices is { } available && !available.Contains(_action.Id)
            && ActionChoices.FirstOrDefault(choice => available.Contains(choice.Id) && Definition.Options.Any(option => option.Id == choice.Id && option.Replaces == _action.Id)) is { } usable) { _action = usable; OnPropertyChanged(nameof(Action)); OnPropertyChanged(nameof(ActionNote)); }
        OnPropertyChanged(nameof(AppliedChoice)); OnPropertyChanged(nameof(IsApplied));
        Name = Presentation.Name ?? (status?.Controls?.FirstOrDefault() is { Address.Kind: "service", DisplayName: { } serviceName } && ReadableName(serviceName) ? serviceName : Definition.Name);
        Available = Choices.Length > 1 && status is { Supported: true, Error: null } && status.Controls?.Any(control => control.RestartPending) != true;
        Detail = status is null ? "Refresh to read this setting." : status.Controls?.Any(control => control.RestartPending) == true ? "Restart Windows to finish this feature change." : status.Error ?? (status.Supported == false ? "Not available on this Windows build or edition." : "");
        if (Detail.Length == 0) Detail = string.Join("\n", (status?.Controls ?? []).Where(control => control.Address.Kind is "timer" or "download-blocker" or "firewall-profile").Select(control => control.DisplayName).Where(text => !string.IsNullOrWhiteSpace(text)));
        var unset = status is not null && status.Observations.All(read => read.Value is null) && (status.Controls ?? []).All(read => read.Value.ValueKind == System.Text.Json.JsonValueKind.Null);
        _onlyDefaultHere = context is not null && status is { Supported: true, Error: null } && unset && Definition.Options.Where(option => !_resetIds.Contains(option.Id)).ToArray() is { Length: > 0 } actions
            && actions.All(option => !TweakEngine.SupportsWindows(Definition, option, context));
        Current = status?.Error == TweakEngine.FeaturesPending ? "Checking…" : CouldNotCheck ? "Couldn't check" : status is null ? "Not read" : status.Error is not null || _onlyDefaultHere ? "Not available here"
            : unset ? "No override"
            : status.ConfiguredChoices.Length > 0 ? string.Join(" / ", Choices.Where(choice => status.ConfiguredChoices.Contains(choice.Id)).Select(choice => choice.Name)) : "Custom value";
        if (Current.Length == 0) Current = "Unknown value";
        if (status is { Error: null, Controls: [var control] } && control.Address.Kind == "timer") Current = control.Value.GetBoolean() ? "Active" : "Stopped";
        if (status is { Error: null, ConfiguredChoices.Length: 0, Controls: [{ Address.Kind: "service" } service] } && ServiceState(service) is { } state) Current = state;
        if (status is { Error: null, ConfiguredChoices.Length: 0, Controls: [{ Address: { Kind: "filesystem", Property: "last-access" }, Value.ValueKind: System.Text.Json.JsonValueKind.Number } lastAccess] })
            Current = lastAccess.Value.GetInt32() switch { 2 => "Updated (Windows managed)", 3 => "Not updated (Windows managed)", _ => Current };
        if (status is { Error: null, ConfiguredChoices.Length: 0, Controls: [{ Address.Kind: "mitigations", Value.ValueKind: System.Text.Json.JsonValueKind.Object } policy] } && MitigationFields(Definition) is { Length: > 0 } fields
            && fields.All(field => policy.Value.TryGetProperty(field, out var value) && (value.ValueKind == System.Text.Json.JsonValueKind.String && value.GetString() == "NOTSET" || value.ValueKind == System.Text.Json.JsonValueKind.False)) && NoRawPolicy(policy.Value)) Current = "Windows default";
        if (Current == "Custom value" && status is { Error: null } && Presentation.Defaults is { } defaults && WindowsDefault(status, defaults)) Current = "Windows default";
        if (Current == "Custom value" && status is { Error: null } && PerDevice && DevicesDiffer(status)) Current = "Varies by device";
        if (Current == "Custom value" && status is { Error: null, Controls: [{ Address.Kind: "network-adapter", Value.ValueKind: System.Text.Json.JsonValueKind.Object } adapter] } && AdapterFields(adapter) is { } protocols) Current = protocols;
        if (Current == "Custom value" && status is { Error: null, Controls: null or [] } && status.Observations is [var first, ..] found
            && found.All(read => read.Value is not null && TweakRead.SameValue(read.Value, first.Value)) && RegistryText(first.Value!) is { } value) Current = "Custom value: " + value;
        if (_onlyDefaultHere) Detail = "This Windows edition or version doesn't use this setting. You can keep a saved choice for a matching installation.";
        else if (Detail.Contains("Office installation", StringComparison.Ordinal)) Detail = "Office was not detected. You can save this choice before installing it.";
        else if (Detail.StartsWith("No choice applies", StringComparison.Ordinal)) Detail = "This Windows or app version does not use this setting. You can keep a saved choice for a matching installation.";
        else if (Detail.Contains("Win32 1060", StringComparison.Ordinal)) Detail = "This Windows service is not installed.";
        else if (Detail.Contains("Hard-linked file permissions", StringComparison.Ordinal)) Detail = "Windows links this file to other copies, so its permissions can't be changed safely here.";
        else if (Detail.Contains("0x80070002", StringComparison.Ordinal) && Definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address.Kind == "scheduled-task")) Detail = "This Windows task is not installed.";
        else if (IsNetwork && status?.Error is { } error && !error.Contains("is not available with this Windows version", StringComparison.Ordinal)) Detail = !error.Contains("couldn't load its PowerShell commands", StringComparison.Ordinal) && (error.Contains("adapter", StringComparison.OrdinalIgnoreCase) || error.Contains("devices expose", StringComparison.OrdinalIgnoreCase))
            ? "The current adapter does not expose this option. You can save a choice for a compatible adapter." : "Windows could not read this preference. Refresh to try again.";
        OnPropertyChanged(nameof(CouldNotCheck)); OnPropertyChanged(nameof(CanRetry)); OnPropertyChanged(nameof(UnavailableHere));
        SyncToggle(); NotifyPending(); OnPropertyChanged(nameof(CanApplySelected));
    }
}
public sealed record WindowsProfileChoice(string Id, string? Name = null)
{
    public override string ToString() => Name ?? Id;
}
public sealed record WindowsChangeRow(string Name, string Before, string After, string Target);

public partial class WindowsTweaksViewModel : ObservableObject
{
    private readonly List<WindowsTweakRow> _all = new();
    private readonly List<TweakChoice> _presets = new();
    private TweakCatalog? _catalog;
    private TweakInspection? _inspection;
    private WindowsTweakReview? _review;
    private bool _loading;
    private long _revision;
    private TweakRecovery? _recovery;
    private bool _reviewingRecovery;
    private TweakChoiceFile? _savedChoices;
    private TweakSelection[]? _reviewedChoices;
    private bool _restoringChoices;
    private string _deferredDetail = "";
    private string? _focusedSetting;
    [ObservableProperty] private ObservableCollection<WindowsTweakRow> _rows = new();
    public TweakSection[] Sections { get; } = WindowsTweakPresentation.Sections();
    public ObservableCollection<string> Categories { get; } = new();
    public ObservableCollection<string> Sources { get; } = new();
    public ObservableCollection<WindowsProfileChoice> Profiles { get; } = new();
    public ObservableCollection<TweakChoice> Presets { get; } = new();
    public ObservableCollection<WindowsChangeRow> Changes { get; } = new();
    [ObservableProperty] private bool _showAdvanced = true;
    [ObservableProperty] private TweakSection? _selectedSection;
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private string _category = "All groups";
    [ObservableProperty] private string _source = "All sources";
    [ObservableProperty] private string _profileId = "my-settings";
    [ObservableProperty] private WindowsProfileChoice? _selectedProfile;
    [ObservableProperty] private TweakChoice? _selectedPreset;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _approved;
    [ObservableProperty] private bool _acceptedDataLoss;
    [ObservableProperty] private string _status = "Loading Windows settings…";
    [ObservableProperty] private string _staleNotice = "";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private string _summary = "";
    public WindowsTweaksViewModel() { _selectedSection = Sections[0]; }
    public const string FpsPresetId = "fps-boost";
    public bool HasFpsPreset => !Busy && !HasPendingRecovery && _catalog?.Presets.Any(preset => preset.Id == FpsPresetId) == true;
    [RelayCommand]
    private void SelectFpsPreset()
    {
        if (!HasFpsPreset) return;
        SelectedSection = Sections[0];
        SelectedPreset = null;
        SelectedPreset = new(FpsPresetId, _catalog!.Presets.Single(preset => preset.Id == FpsPresetId).Name);
    }
    public string SectionTitle => SelectedSection?.Name ?? "All tweaks";
    public string SectionDescription => SelectedSection?.Description ?? "";
    public string SectionIcon => SelectedSection?.Icon ?? Sections[0].Icon;
    public bool IsDebloat => SelectedSection?.Id == "debloat";
    public string VisibleCount => Rows.Count + " settings";
    partial void OnSelectedSectionChanged(TweakSection? value)
    {
        _focusedSetting = null; Search = ""; Category = "All groups"; UpdateTopics(); Filter(); FilterPresets("");
        foreach (var name in new[] { nameof(SectionTitle), nameof(SectionDescription), nameof(SectionIcon), nameof(IsDebloat) }) OnPropertyChanged(name);
    }
    public bool CanRefresh => !Busy;
    public bool CanEdit => !Busy && !HasPendingRecovery;
    public bool CanReviewRecovery => !Busy && HasPendingRecovery;
    public bool CanApproveReview => !Busy && (!HasPendingRecovery || _reviewingRecovery);
    public bool ShowProfileName => !ProfileId.StartsWith("file-permissions-", StringComparison.Ordinal) && !ProfileId.StartsWith("restore-point-", StringComparison.Ordinal);
    public bool CanReview => !Busy && !_staleLoad && !HasPendingRecovery && _catalog is not null && !string.IsNullOrWhiteSpace(ProfileId) && _all.Any(row => row.Selected.Id.Length > 0);
    public bool CanApply => !Busy && (_review is not null || _reviewedChoices is not null || _reviewingRecovery && _recovery?.Pending is not null) && Approved && (!HasDataLoss || AcceptedDataLoss);
    public bool HasDataLoss => _review?.Plan.DataLoss.Length > 0;
    public string DataLossText => string.Join("\n", _review?.Plan.DataLoss ?? []);
    public bool HasPendingRecovery => _recovery?.Pending is not null;
    public bool CanRestore => !Busy && !HasPendingRecovery && _inspection is not null && (_inspection.State?.Profiles.Any(profile => profile.Id == ProfileId.Trim()) == true || _savedChoices?.Profiles.Any(profile => profile.Id == ProfileId.Trim()) == true);
    public bool HasValueChanges => Changes.Count > 0;
    public bool HasReview => _review is not null || _reviewedChoices is not null || _reviewingRecovery;
    public bool HasRows => Rows.Count > 0;
    public bool ShowEmpty => !Busy && _inspection is not null && !HasRows;
    public bool CheckingRestart => _recovery?.Pending is { Phase: "awaiting-restart" } pending && _recovery.State?.History.Any(item => item.OperationId == pending.Plan.OperationId) == true;
    public string ApplyLabel => _reviewingRecovery ? CheckingRestart ? "Check restart completion" : "Recover interrupted changes" : _restoringChoices ? _review is null ? "Remove saved choices" : "Restore settings" : _review is null && _reviewedChoices is not null ? "Save choices" : _review?.Plan.Selections.Length == 0 ? "Restore settings" : _review is not null && Changes.Count == 0 ? "Save profile" : "3. Apply";
    public string SelectionText => _all.Count(row => row.HasPendingChange) switch { 0 => "No changes yet", 1 => "1 change", var count => count + " changes" };
    partial void OnShowAdvancedChanged(bool value) { foreach (var row in _all) row.ShowDetails = value; Filter(); }
    partial void OnSearchChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnCategoryChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnSourceChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnBusyChanged(bool value)
    {
        Notify();
        if (!value && _revalidatePending) { _revalidatePending = false; _ = RevalidateAsync(); }
    }
    private bool _revalidatePending;
    public async Task WaitForLoadAsync()
    {
        while (_refresh is { IsCompleted: false }) await _refresh;
    }
    partial void OnApprovedChanged(bool value) => Notify();
    partial void OnAcceptedDataLossChanged(bool value) => Notify();
    partial void OnProfileIdChanged(string value)
    {
        Invalidate();
        if (!_loading) SetSelectionStatus("Profile name changed", "Review the current selection before applying.");
    }
    partial void OnSelectedProfileChanged(WindowsProfileChoice? value)
    {
        if (_loading || value is null || !CanEdit) return;
        ProfileId = value.Id;
        LoadProfile(); _userPicked = true;
        foreach (var row in _all) _userRows.Add(row.Id);
        Filter();
        SetSelectionStatus("Profile loaded", "Review this profile before applying or restoring settings.");
    }
    partial void OnSelectedPresetChanged(TweakChoice? value)
    {
        if (_loading || value is null || _catalog is null || !CanEdit) return;
        var preset = _catalog.Presets.Single(item => item.Id == value.Id);
        var available = preset.Selections.Where(selection => _all.Any(row => row.Id == selection.SettingId && row.Choices.Any(choice => choice.Id == selection.OptionId))).ToArray();
        var conflicts = available.GroupBy(selection => selection.SettingId).Where(group => group.Select(selection => selection.OptionId).Distinct().Count() > 1).ToArray();
        if (conflicts.Length > 0) { Status = "This preset has conflicting choices"; Detail = string.Join(", ", conflicts.Select(group => _all.Single(row => row.Id == group.Key).Name)) + ". Choose these settings individually."; return; }
        _loading = true;
        foreach (var selection in available)
        {
            var row = _all.Single(item => item.Id == selection.SettingId);
            row.Selected = row.Choices.FirstOrDefault(choice => choice.Id == selection.OptionId) ?? row.Choices[0];
            _userRows.Add(row.Id);
        }
        _loading = false; _userPicked = true; Invalidate(); Notify(); Filter();
        SetSelectionStatus(available.Length == 1 ? "1 preset choice added" : available.Length + " preset choices added", "Review the selected values. Choices with missing requirements can be saved without changing Windows.");
    }
    private long _loadedGeneration = -2;
    private long _loadedTicks;
    private int _loadVersion;
    private Task? _refresh;
    private bool HasPicks => _all.Any(row => row.HasPendingChange);
    public bool HasPendingChanges => HasUserWork;
    private bool _userPicked;
    private readonly HashSet<string> _userRows = new(StringComparer.Ordinal);
    private bool HasUserWork => _userPicked || HasReview;
    public async Task RevalidateAsync()
    {
        while (_refresh is { IsCompleted: false }) await _refresh;
        if (_loadedGeneration == -2 || DataGeneration.Changing || DataGeneration.IsCurrent(_loadedGeneration)) return;
        if (Busy) { _revalidatePending = true; return; }
        if (HasUserWork) NoteChanged();
        else await LoadAsync(fresh: true);
    }
    private void NoteChanged() => StaleNotice = "Windows settings changed elsewhere. Your picks are kept and any review reads the current values; select Refresh to see them here (this clears your picks).";
    public async Task ShowAsync()
    {
        if (_loadedGeneration == -2) { await LoadAsync(fresh: false); return; }
        if (_focusedSetting is not null) { _focusedSetting = null; Search = ""; Filter(); }
        if (Busy) return;
        if (!DataGeneration.IsCurrent(_loadedGeneration))
        {
            if (HasUserWork) NoteChanged();
            else await LoadAsync(fresh: true);
        }
        else if (Environment.TickCount64 - _loadedTicks > 60000 && !HasReview && !HasPicks && _refresh is not { IsCompleted: false }) await (_refresh = RefreshStatusAsync());
    }
    private async Task RefreshStatusAsync()
    {
        var version = _loadVersion;
        var generation = DataGeneration.Changing ? -1 : DataGeneration.Current;
        TweakRecovery recovery; TweakInspection inspection;
        try
        {
            var recoveryRead = App.Operations.ReadWindowsRecoveryAsync(true);
            var inspectionRead = App.Operations.ReadWindowsTweaksAsync(true, streamed: false);
            try { recovery = await recoveryRead; }
            finally { _ = inspectionRead.ContinueWith(task => task.Exception, TaskScheduler.Default); }
            inspection = await inspectionRead;
        }
        catch (Exception error) { AppLog.Write("windows-settings", "Background status refresh failed: " + error.Message); _loadedTicks = Environment.TickCount64; return; }
        if (version != _loadVersion || generation != DataGeneration.Current || DataGeneration.Changing || Busy || HasReview || HasPicks || _catalog is null) return;
        var statuses = new Dictionary<string, TweakSettingStatus>(StringComparer.Ordinal);
        foreach (var item in inspection.Settings) if (!statuses.TryAdd(item.Id, item)) return;
        _loading = true;
        _recovery = recovery; _inspection = inspection;
        foreach (var row in _all) row.Observe(statuses.GetValueOrDefault(row.Id), inspection.Context);
        FillProfiles(inspection);
        LoadProfile(); Filter();
        _loading = false;
        SetLoadedStatus(inspection);
        Summary = "Windows build " + inspection.Context.WindowsBuild + " · " + inspection.Context.Edition;
        _loadedGeneration = generation; _loadedTicks = Environment.TickCount64;
        OnPropertyChanged(nameof(HasPendingRecovery)); Notify();
    }
    private void FillProfiles(TweakInspection inspection)
    {
        Profiles.Clear(); foreach (var profile in inspection.State?.Profiles ?? [])
        {
            var target = profile.Controls?.FirstOrDefault(claim => claim.Target.Address.Kind == "file-ownership")?.Target.Address.Target;
            var label = target is not null ? "File ownership: " + System.IO.Path.GetFileName(target.StartsWith("selected:", StringComparison.Ordinal) ? target[9..] : target)
                : profile.Id.StartsWith("restore-point-", StringComparison.Ordinal) ? "Restore-point temporary policy" : null;
            Profiles.Add(new(profile.Id, label));
        }
        foreach (var profile in (_savedChoices?.Profiles ?? []).Where(profile => Profiles.All(existing => existing.Id != profile.Id))) Profiles.Add(new(profile.Id, profile.Id + " · saved choices"));
    }
    [RelayCommand]
    private Task RefreshAsync() => LoadAsync(fresh: true);
    private Task LoadAsync(bool fresh) => Busy ? Task.CompletedTask : _refresh = LoadCoreAsync(fresh);
    private (TweakInspection Inspection, long Generation)? _partial;
    private bool _rowsReady;
    private void ShowPartial(TweakInspection partial, long generation, int version)
    {
        if (version != _loadVersion || !Busy || _inspection is not null || !DataGeneration.IsCurrent(generation)) return;
        _partial = (partial, generation);
        if (!_rowsReady) return;
        var statuses = new Dictionary<string, TweakSettingStatus>(StringComparer.Ordinal);
        foreach (var item in partial.Settings) if (!statuses.TryAdd(item.Id, item)) return;
        _loading = true;
        foreach (var row in _all) row.Observe(statuses.GetValueOrDefault(row.Id), partial.Context);
        _loading = false;
        Status = _all.Count + " settings · checking Windows features";
        Detail = "Settings that depend on Windows optional features are still being read. You can review changes once every setting is read.";
    }
    private bool _staleLoad;
    private async Task LoadCoreAsync(bool fresh)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            _staleLoad = false;
            await LoadOnceAsync(fresh || attempt > 0);
            if (_loadedGeneration != -1 || _inspection is null) break;
            _staleLoad = true;
            if (DataGeneration.Changing)
            {
                Status = "Windows settings changed while loading";
                Detail = "They are read again when the change finishes. Review is available after that.";
                break;
            }
            if (attempt == 2)
            {
                Status = "Windows settings kept changing while loading";
                Detail = "Select Refresh to read them again. Review is available after a complete read.";
            }
        }
        Notify();
    }
    private async Task LoadOnceAsync(bool fresh)
    {
        Busy = true; _inspection = null; StaleNotice = ""; _userPicked = false; _userRows.Clear(); Invalidate(); _loadVersion++;
        var version = _loadVersion; _partial = null; _rowsReady = false;
        var context = SynchronizationContext.Current;
        void OnPartial(TweakInspection partial, long partialGeneration)
        {
            if (context is null) ShowPartial(partial, partialGeneration, version);
            else context.Post(_ => ShowPartial(partial, partialGeneration, version), null);
        }
        App.Operations.WindowsTweaksPartial += OnPartial;
        var generation = DataGeneration.Changing ? -1 : DataGeneration.Current;
        var catalogRead = App.Operations.ReadWindowsTweakCatalogAsync(fresh);
        var choicesRead = App.Operations.ReadWindowsChoicesAsync();
        var recoveryRead = App.Operations.ReadWindowsRecoveryAsync(fresh);
        var inspectionRead = App.Operations.ReadWindowsTweaksAsync(fresh);
        try
        {
            var catalog = await catalogRead;
            _catalog = catalog.Catalog;
            foreach (var row in _all) row.PropertyChanged -= RowChanged;
            _all.Clear();
            var definitions = _catalog.Settings.ToDictionary(definition => definition.Id);
            foreach (var definition in _catalog.Settings)
            {
                var row = new WindowsTweakRow(definition, definitions, id =>
                {
                    SelectedSection = Sections.Single(section => section.Id == WindowsTweakPresentation.For(definitions[id]).Section);
                    Category = "All groups"; Source = "All sources"; ShowAdvanced = true; Search = WindowsTweakPresentation.For(definitions[id]).Name ?? definitions[id].Name;
                    _focusedSetting = id; Filter();
                }, () => _ = RefreshAsync());
                row.ShowDetails = ShowAdvanced; row.PropertyChanged += RowChanged; _all.Add(row);
            }
            Filter();
            UpdateSections();
            _rowsReady = true;
            if ((_partial ?? App.Operations.PendingWindowsTweaks) is { } early) ShowPartial(early.Inspection, early.Generation, version);
            _savedChoices = await choicesRead;
            _recovery = await recoveryRead;
            OnPropertyChanged(nameof(HasPendingRecovery));
            var inspection = await inspectionRead;
            _loading = true;
            _inspection = inspection;
            var statuses = new Dictionary<string, TweakSettingStatus>(StringComparer.Ordinal);
            foreach (var item in inspection.Settings) if (!statuses.TryAdd(item.Id, item)) throw new InvalidOperationException("Sequence contains more than one matching element");
            foreach (var row in _all) row.Observe(statuses.GetValueOrDefault(row.Id), inspection.Context);
            UpdateTopics();
            Fill(Sources, "All sources", _all.SelectMany(row => row.Definition.Sources.Select(source => source.Product)));
            if (!Categories.Contains(Category)) Category = "All groups";
            if (!Sources.Contains(Source)) Source = "All sources";
            OnPropertyChanged(nameof(Category)); OnPropertyChanged(nameof(Source));
            FillProfiles(inspection);
            _presets.Clear(); foreach (var preset in _catalog.Presets.Where(preset => !ControlPlanning.HiddenPresets.Contains(preset.Id))) _presets.Add(new(preset.Id, preset.Name));
            FilterPresets("");
            SelectedPreset = null; _loading = false;
            LoadProfile(); Filter();
            SetLoadedStatus(inspection);
            Summary = "Windows build " + inspection.Context.WindowsBuild + " · " + inspection.Context.Edition;
            _loadedGeneration = generation == DataGeneration.Current ? generation : -1; _loadedTicks = Environment.TickCount64;
        }
        catch (Exception error)
        {
            _ = Task.WhenAll(catalogRead, choicesRead, recoveryRead, inspectionRead).ContinueWith(task => task.Exception, TaskScheduler.Default);
            _loadedGeneration = -1; _inspection = null; foreach (var row in _all) row.Observe(null); LoadProfile(); Filter(); Status = "Couldn't load Windows settings."; Detail = error.Message;
        }
        finally { App.Operations.WindowsTweaksPartial -= OnPartial; _partial = null; _loading = false; Busy = false; }
    }
    private static void Fill(ObservableCollection<string> target, string first, IEnumerable<string> values)
    {
        target.Clear(); target.Add(first); foreach (var value in values.Distinct().Order(StringComparer.OrdinalIgnoreCase)) target.Add(value);
    }
    private string _profileLoaded = "";
    private void LoadProfile()
    {
        _loading = true; _profileLoaded = ProfileId.Trim();
        var selected = _savedChoices?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? _inspection?.State?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? [];
        foreach (var row in _all) row.Selected = row.Choices.FirstOrDefault(choice => selected.Any(item => item.SettingId == row.Id && row.ChoiceId(item.OptionId) == choice.Id)) ?? row.Choices[0];
        _loading = false; Invalidate(); Notify();
    }
    private void RowChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_loading || HasPendingRecovery || args.PropertyName != nameof(WindowsTweakRow.Selected)) return;
        _userPicked = true;
        if (sender is WindowsTweakRow row) _userRows.Add(row.Id);
        Invalidate();
        SetSelectionStatus("Selection changed", "Review the current selection before applying.");
    }
    private void SetSelectionStatus(string status, string detail)
    {
        if (HasPendingRecovery || _inspection is null) return;
        Status = status;
        Detail = detail;
    }
    private void UpdateSections()
    {
        foreach (var section in Sections)
        {
            section.Count = _all.Count(row => section.Id == "all" || row.SectionId == section.Id);
            section.SelectedCount = _all.Count(row => (section.Id == "all" || row.SectionId == section.Id) && row.HasPendingChange);
        }
    }
    private void UpdateTopics()
    {
        var selected = Category;
        Fill(Categories, "All groups", _all.Where(row => SelectedSection?.Id is null or "all" || row.SectionId == SelectedSection.Id).Select(row => row.Topic));
        Category = Categories.Contains(selected) ? selected : "All groups";
        OnPropertyChanged(nameof(Category));
    }
    [RelayCommand]
    private void ClearSelection()
    {
        if (!CanEdit) return;
        _loading = true; foreach (var row in _all) { row.Selected = row.Choices[0]; _userRows.Add(row.Id); } SelectedPreset = null; _loading = false; _userPicked = false; Invalidate(); Notify();
        if (StaleNotice.Length > 0 && !DataGeneration.Changing && !DataGeneration.IsCurrent(_loadedGeneration)) { _ = LoadAsync(fresh: true); return; }
        if (!ShowProfileName && _inspection?.State?.Profiles.Any(profile => profile.Id == ProfileId) != true) ProfileId = "my-settings";
        SetSelectionStatus("Nothing selected", "Choose settings, review the changes, then apply.");
    }
    [RelayCommand] private Task ReviewAsync() => Review(false);
    [RelayCommand] private Task ReviewRestoreAsync() => Review(true);
    private async Task Review(bool restore)
    {
        if (restore ? !CanRestore : !CanReview) return;
        Busy = true; Invalidate();
        var revision = _revision;
        try
        {
            var state = _inspection?.State;
            Func<WindowsTweakRow, string> choice = row => row.Selected.Id;
            if (!DataGeneration.IsCurrent(_loadedGeneration))
            {
                state = (await App.Operations.ReadWindowsRecoveryAsync(true)).State;
                var saved = await App.Operations.ReadWindowsChoicesAsync();
                if (revision != _revision) return;
                _savedChoices = saved;
                var profile = saved?.Profiles.SingleOrDefault(item => item.Id == _profileLoaded)?.Selections ?? state?.Profiles.SingleOrDefault(item => item.Id == _profileLoaded)?.Selections ?? [];
                choice = row => _userRows.Contains(row.Id) ? row.Selected.Id : profile.FirstOrDefault(item => item.SettingId == row.Id)?.OptionId ?? "";
            }
            if (revision != _revision) return;
            var chosen = _all.Select(row => (Row: row, Id: choice(row))).Where(item => item.Id.Length > 0).ToArray();
            var selections = restore ? Array.Empty<TweakSelection>() : chosen.Select(item => new TweakSelection(item.Row.Id, item.Id)).ToArray();
            if (!restore && selections.Length == 0) return;
            var selectedReady = restore ? selections : chosen.Where(item => item.Row.CanApplyChoice(item.Id)).Select(item => new TweakSelection(item.Row.Id, item.Id)).ToArray();
            var retained = restore ? Array.Empty<TweakSelection>() : (state?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? [])
                .Where(selection =>
                {
                    if (selectedReady.Any(selected => selected.SettingId == selection.SettingId)) return false;
                    var definition = _catalog!.Settings.SingleOrDefault(item => item.Id == selection.SettingId);
                    if (definition is null) return false;
                    var option = definition.Options.SingleOrDefault(item => item.Id == selection.OptionId);
                    return option is null || _inspection is null || TweakEngine.SupportsWindows(definition, option, _inspection.Context);
                }).ToArray();
            var ready = selectedReady.Concat(retained).ToArray();
            var deferred = restore ? Array.Empty<WindowsTweakRow>() : chosen.Where(item => !ready.Contains(new TweakSelection(item.Row.Id, item.Id))).Select(item => item.Row).ToArray();
            _deferredDetail = string.Join("\n", deferred.Select(row => row.Name + ": " + (row.Detail.Length == 0 ? "This choice needs a matching Windows or app version." : row.Detail)));
            _reviewedChoices = selections; _restoringChoices = restore;
            if (ready.Length == 0 && (!restore || state?.Profiles.Any(profile => profile.Id == ProfileId.Trim()) != true))
            {
                Status = _restoringChoices ? "Remove this saved profile" : "Save the selected choices";
                Detail = _restoringChoices ? "Only this profile's saved choices will be removed." : "These choices will be saved. Windows settings will stay unchanged until their requirements are met and you apply them.\n" + _deferredDetail;
                Notify(); return;
            }
            WindowsTweakReview review;
            try { review = await App.Operations.PreviewWindowsTweaksAsync(ProfileId.Trim(), ready); }
            catch (Exception error) when (!restore)
            {
                if (revision != _revision) return;
                Status = "Save choices; Windows review needs attention";
                Detail = "The requested choices can be saved, but no Windows changes will be applied.\n" + error.Message;
                Notify(); return;
            }
            if (revision != _revision) return;
            _review = review;
            foreach (var change in _review.Plan.Changes)
            {
                var ids = (state?.Profiles ?? []).Concat(_review.Plan.Profiles).SelectMany(profile => profile.Claims).Where(claim => claim.Target.Id == change.Before.Id).Select(claim => claim.SettingId).ToArray();
                var row = _all.FirstOrDefault(item => ids.Contains(item.Id));
                Changes.Add(new(row?.Name ?? change.Before.Address.ValueName ?? "Setting", DescribeSetting(row?.Definition, change.Before.Value), DescribeSetting(row?.Definition, change.After),
                    row?.Scope ?? (change.Before.Address.Hive == "CurrentUser" ? "This user" : "Entire PC")));
            }
            foreach (var change in _review.Plan.Controls?.Changes ?? []) AddNativeChange(change, (state?.Profiles ?? []).Concat(_review.Plan.Profiles));
            Status = Changes.Count == 0 ? "Selected values already match" : Changes.Count == 1 ? "1 change ready to review" : Changes.Count + " changes ready to review";
            Detail = restore ? "Shared settings stay active while another profile needs them." : Changes.Count == 0 ? "Save this profile to keep track of these choices." : "Review these values and confirm before applying.";
            if (deferred.Length > 0) Detail += "\n" + deferred.Length + " choices will be saved with requirements pending:\n" + _deferredDetail;
            if (_review.Plan.LeftAsChanged.Length > 0)
            {
                if (Changes.Count == 0) Status = "Windows already changed these settings";
                Detail += "\nWindows or another app changed or removed these, or they could not be read, so they stay as they are now:\n" + string.Join("\n", _review.Plan.LeftAsChanged.Select(id => _all.FirstOrDefault(row => row.Id == id)?.Name ?? id).Distinct());
            }
        }
        catch (Exception error) { Invalidate(); Status = "Couldn't prepare these changes."; Detail = error.Message; }
        finally { Busy = false; }
    }
    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (!CanApply) return;
        Busy = true;
        var choicesSaved = false;
        var windowsApplied = false;
        var restoring = _restoringChoices;
        var recovering = _reviewingRecovery;
        try
        {
            var choiceOnly = _review is null;
            var deferred = _deferredDetail;
            TweakApplyResult? result = null;
            using (RunningChanges.Begin())
            {
                if (recovering) await App.Operations.RecoverWindowsTweaksAsync(_recovery!.PendingHash!);
                else
                {
                    if (!restoring && _reviewedChoices is not null)
                    {
                        _savedChoices = await App.Operations.SaveWindowsChoicesAsync(_catalog!, ProfileId.Trim(), _reviewedChoices, _savedChoices?.Revision);
                        choicesSaved = true;
                    }
                    result = _review is null ? null : await App.Operations.ApplyWindowsTweaksAsync(_review, AcceptedDataLoss);
                    windowsApplied = result is not null;
                    if (restoring && _reviewedChoices is not null) _savedChoices = await App.Operations.SaveWindowsChoicesAsync(_catalog!, ProfileId.Trim(), _reviewedChoices, _savedChoices?.Revision);
                }
            }
            if (recovering) { Invalidate(); Busy = false; await RefreshAsync(); await WaitForLoadAsync(); return; }
            _inspection = null; Invalidate();
            Busy = false; await RefreshAsync(); await WaitForLoadAsync();
            if (_inspection is null) { Status = "Settings saved; current values could not be reloaded."; return; }
            Status = choiceOnly ? restoring ? "Saved choices removed" : "Choices saved" : result!.Changed ? "Windows settings saved" : "Profile saved";
            Detail = choiceOnly ? "No Windows settings were changed.\n" + deferred : result!.State.Notices.Length > 0 ? string.Join("\n", result.State.Notices) : deferred.Length > 0 ? "Applied the reviewed Windows changes. These saved choices still need their requirements:\n" + deferred : "Current settings have been refreshed. Follow the restart or sign-out notes shown with the settings.";
        }
        catch (Exception error)
        {
            Invalidate(); Busy = false; await RefreshAsync(); await WaitForLoadAsync();
            Status = windowsApplied ? restoring ? "Windows settings restored; saved choices need attention" : "Windows settings applied; saved choices need attention"
                : choicesSaved ? "Choices saved; Windows changes were not confirmed" : "Settings were not confirmed";
            Detail = error.Message + (HasPendingRecovery ? "\nReview the interrupted operation before applying more changes." : "");
        }
        finally { Busy = false; }
    }
    [RelayCommand]
    private void ReviewRecovery()
    {
        if (!CanReviewRecovery || _recovery?.Pending is not { } pending) return;
        Invalidate(); _reviewingRecovery = true;
        if (!CheckingRestart) foreach (var change in pending.Plan.Controls!.Changes.Take(pending.Attempted))
            AddNativeChange(new(change.Before with { Value = change.After }, change.Before.Value), (_recovery.State?.Profiles ?? []).Concat(pending.Plan.Profiles));
        Status = CheckingRestart ? "Check Windows feature changes after restarting" : "Review recovery of the interrupted operation";
        Detail = CheckingRestart ? "Restart Windows first. This checks the final feature states before closing the pending record." : "Only values still matching the interrupted operation will be restored. Newer edits are preserved.";
        Notify();
    }
    public const string OwnershipRefresh = "Re-take ownership (no value change)";
    private void AddNativeChange(ControlMutation change, IEnumerable<TweakProfile> profiles)
    {
        var read = change.Before;
        var claims = profiles.SelectMany(profile => profile.Controls ?? []).Where(claim => claim.Target.Id == read.Id).ToArray();
        var claimed = claims.Length > 0;
        var rows = claimed ? claims.Select(claim => claim.SettingId).Distinct().Select(id => _all.FirstOrDefault(row => row.Id == id)).OfType<WindowsTweakRow>().ToArray()
            : _all.Where(row => ControlsFor(row.Definition, read.Address, false).Any()).ToArray();
        if (ControlValues.Equal(read.Value, change.After))
        {
            var owner = rows.FirstOrDefault(row => row.Definition.Options.All(option => (option.Controls ?? []).All(control => control.Address == read.Address))) ?? rows.FirstOrDefault();
            var current = owner is null ? null : ControlChoice(owner, read, read.Value, claims.Where(claim => claim.SettingId == owner.Id).Select(claim => claim.OptionId).ToArray(), claimed);
            Changes.Add(new(owner?.Name ?? read.DisplayName ?? read.Address.Target, current ?? (owner is null ? DescribeControl(read.Address, read.Value) : ControlFallback(owner, read, read.Value, claimed)), OwnershipRefresh, owner?.Scope ?? "Entire PC"));
            return;
        }
        var shown = false;
        foreach (var row in rows)
        {
            var chosen = claims.Where(claim => claim.SettingId == row.Id).Select(claim => claim.OptionId).ToArray();
            var before = ControlChoice(row, read, read.Value, _restoringChoices ? chosen : [], claimed);
            var after = ControlChoice(row, read, change.After, _restoringChoices ? [] : chosen, claimed);
            if (before is null && after is null || before == after) continue;
            var name = row.Definition.Options.SelectMany(option => option.Controls ?? []).Select(control => control.Address).Distinct().Count() > 1
                ? _all.FirstOrDefault(other => other != row && ControlsFor(other.Definition, read.Address, false).Any() && other.Definition.Options.All(option => (option.Controls ?? []).All(control => control.Address == read.Address)))?.Name ?? row.Name
                : row.Name;
            Changes.Add(new(name, before ?? ControlFallback(row, read, read.Value, claimed), after ?? ControlFallback(row, read, change.After, claimed), row.Scope));
            shown = true;
        }
        if (shown) return;
        var scope = read.Address.Kind is "file-acl" or "file-ownership" ? (read.Address.Target.StartsWith("selected:", StringComparison.Ordinal) ? read.Address.Target[9..] : read.Address.Target) : "Entire PC";
        if (read.Address.Kind is "windows-features" or "mitigations" && read.Value.ValueKind == System.Text.Json.JsonValueKind.Object && change.After.ValueKind == System.Text.Json.JsonValueKind.Object)
        {
            var fields = change.After.EnumerateObject().Where(property => property.Name != MitigationControl.SnapshotField && !(read.Value.TryGetProperty(property.Name, out var old) && ControlValues.Equal(property.Value, old))).Select(property => property.Name).ToArray();
            var owners = _all.Where(row => ControlsFor(row.Definition, read.Address, false).Any(control => control.Value.ValueKind == System.Text.Json.JsonValueKind.Object && control.Value.EnumerateObject().Any(property => fields.Contains(property.Name)))).Select(row => row.Name).Distinct().ToArray();
            string Fields(System.Text.Json.JsonElement value) => string.Join("; ", fields.Select(field => field + ": " + (value.TryGetProperty(field, out var state) ? Humanize(state) : "Not set")));
            Changes.Add(new(owners.Length > 0 ? string.Join(", ", owners) : read.Address.Kind == "mitigations" ? "Windows security mitigations" : "Windows features", Fields(read.Value), Fields(change.After), scope));
            return;
        }
        Changes.Add(new(read.DisplayName ?? rows.FirstOrDefault()?.Name ?? read.Address.Target, DescribeControl(read.Address, read.Value), DescribeControl(read.Address, change.After), scope));
    }
    private static IEnumerable<ControlAssignment> ControlsFor(TweakDefinition definition, ControlAddress address, bool claimed)
        => definition.Options.SelectMany(option => option.Controls ?? []).Where(control => Same(control.Address, address, claimed));
    private static bool Same(ControlAddress control, ControlAddress read, bool claimed) => control == read || claimed && Loose(control, read);
    private static bool Loose(ControlAddress control, ControlAddress read) =>
        string.Equals(control.Kind, read.Kind, StringComparison.OrdinalIgnoreCase) && string.Equals(control.Property, read.Property, StringComparison.OrdinalIgnoreCase);
    private static string? ControlChoice(WindowsTweakRow row, TweakControlRead read, System.Text.Json.JsonElement value, string[] chosen, bool claimed)
    {
        if (value.ValueKind == System.Text.Json.JsonValueKind.Null) return "No override";
        claimed = claimed && row.Definition.Options.SelectMany(option => option.Controls ?? []).Where(control => Loose(control.Address, read.Address)).Select(control => control.Address.Target).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1;
        var matches = row.Definition.Options.Where(option =>
        {
            var controls = (option.Controls ?? []).Where(control => control.Address == read.Address).ToArray();
            if (controls.Length == 0) controls = (option.Controls ?? []).Where(control => Same(control.Address, read.Address, claimed)).ToArray();
            return controls.Length > 0 && controls.All(control => Matches(read, control, value));
        }).ToArray();
        var match = matches.FirstOrDefault(option => chosen.Contains(option.Id)) ?? matches.FirstOrDefault();
        return match is null ? null : Capitalize(row.Choices.First(choice => choice.Id == match.Id).Name);
    }
    private static bool Matches(TweakControlRead read, ControlAssignment control, System.Text.Json.JsonElement value)
    {
        try { return ControlComposition.Matches(new(read.Address.Target, "", read, read.Expand(control.Value, allowPending: true), control.Patch), value); }
        catch (Exception error) when (error is not OperationCanceledException) { return false; }
    }
    private static string ControlFallback(WindowsTweakRow row, TweakControlRead read, System.Text.Json.JsonElement value, bool claimed)
    {
        var patches = ControlsFor(row.Definition, read.Address, claimed).Where(control => control.Patch && control.Value.ValueKind == System.Text.Json.JsonValueKind.Object).ToArray();
        if (patches.Length == 0 || value.ValueKind != System.Text.Json.JsonValueKind.Object) return DescribeControl(read.Address, value);
        var field = patches[0].Value.EnumerateObject().First().Name;
        return value.TryGetProperty(field, out var state) ? Humanize(state) : "Not set";
    }
    private static string Capitalize(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];
    private static string Humanize(System.Text.Json.JsonElement value) => value.ValueKind switch
    {
        System.Text.Json.JsonValueKind.String => value.GetString() switch { "ON" => "On", "OFF" => "Off", "NOTSET" => "Not set", var text => text ?? "" },
        System.Text.Json.JsonValueKind.True => "On", System.Text.Json.JsonValueKind.False => "Off", System.Text.Json.JsonValueKind.Null => "Not set",
        _ => value.ToString(),
    };
    private static string DescribeControl(ControlAddress address, System.Text.Json.JsonElement value)
    {
        if (value.ValueKind == System.Text.Json.JsonValueKind.Null) return "No override";
        if (value.ValueKind is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False) return Switch(address.Property, value.GetBoolean());
        if (address.Kind == "service" && address.Property == "startup") return value.GetInt32() switch { 0 => "Boot", 1 => "System", 2 => "Automatic", 3 => "Manual", 4 => "Disabled", _ => value.ToString() };
        if (address.Kind == "hibernation") return value.GetProperty("mode").GetString() + " · Fast Startup " + (value.GetProperty("fastStartup").ValueKind == System.Text.Json.JsonValueKind.Null ? "not configured" : value.GetProperty("fastStartup").GetUInt32() == 0 ? "off" : "on");
        if (address.Kind == "hosts") return value.GetProperty("block").ValueKind == System.Text.Json.JsonValueKind.Null ? "No hosts block from this app" : "Reviewed hosts block present";
        if (address.Kind is "file-acl" or "file-ownership")
        {
            var acl = new RawAcl(Convert.FromBase64String(value.GetProperty("dacl").GetString()!), 0);
            var explicitRules = Enumerable.Range(0, acl.Count).Select(index => acl[index]).OfType<CommonAce>().Where(ace => (ace.AceFlags & AceFlags.Inherited) == 0)
                .Select(ace => (ace.AceQualifier == AceQualifier.AccessDenied ? "Deny " : "Allow ") + Account(ace.SecurityIdentifier.Value) + ": " + ((FileSystemRights)ace.AccessMask).ToString());
            return "Owner: " + Account(value.GetProperty("owner").GetString()!) + "\n" + string.Join("\n", explicitRules.DefaultIfEmpty("Permissions inherited from the parent folder"));
        }
        if (address.Kind == "power-plan") return "Active plan: " + value.GetProperty("active").GetString();
        if (value.ValueKind == System.Text.Json.JsonValueKind.Object && value.TryGetProperty("addresses", out var addresses)) return addresses.GetArrayLength() + " blocked addresses or ranges";
        if (address.Kind is "network-adapter" or "device-power" && value.ValueKind == System.Text.Json.JsonValueKind.Object)
            return string.Join(", ", value.EnumerateObject().GroupBy(device => device.Value.ValueKind is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False ? Switch(address.Property, device.Value.GetBoolean())
                : device.Value.ValueKind == System.Text.Json.JsonValueKind.Object ? string.Join(", ", device.Value.EnumerateObject().Select(item => item.Name + " " + Humanize(item.Value))) : Humanize(device.Value))
                .Select(group => group.Key + " on " + group.Count() + (group.Count() == 1 ? " device" : " devices")));
        if (value.ValueKind == System.Text.Json.JsonValueKind.Object)
        {
            var text = string.Join("; ", value.EnumerateObject().Where(property => property.Name != MitigationControl.SnapshotField).Select(property => property.Name + ": " + Humanize(property.Value)));
            return text.Length > 300 ? text[..300] + "…" : text;
        }
        return Humanize(value);
    }
    private static string Switch(string property, bool value) => property switch
    {
        "running" => value ? "Running" : "Stopped",
        "blocked" => value ? "Blocked" : "Not blocked",
        _ when property.StartsWith("disable", StringComparison.OrdinalIgnoreCase) => value ? "Disabled" : "Enabled",
        _ => value ? "Enabled" : "Disabled",
    };
    private static string Account(string sid)
    {
        if (sid == OperationOwner.Current().UserSid) return "this Windows user";
        if (sid == "S-1-1-0") return "Everyone";
        if (sid == "S-1-5-18") return "SYSTEM";
        if (sid == "S-1-5-32-544") return "Administrators";
        return sid;
    }
    private static string DescribeSetting(TweakDefinition? definition, RegistryValueData? value)
    {
        if (value is null) return "No override";
        if (definition is not null)
        {
            foreach (var option in definition.Options)
            {
                if (option.SameAs is not null || option.Changes is not [var change]) continue;
                var desired = change.Dword is { } number ? new RegistryValueData(change.Address.ValueName!, 4, BitConverter.GetBytes(number)) : change.Value;
                if (change.Token is { } token ? TweakTokens.Get(value, token.Name) == token.Value : change.Bits is null && TweakRead.SameValue(value, desired)) return WindowsTweakRow.DisplayChoice(WindowsTweakPresentation.Choice(definition, option));
            }
            if (WindowsTweakPresentation.For(definition).Section == "network") return "Custom preference";
        }
        return Describe(value);
    }
    private static string Describe(RegistryValueData? value) => value is null ? "No override" : value.Type == 4 ? BitConverter.ToUInt32(value.Bytes).ToString()
        : value.Type is 1 or 2 ? System.Text.Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0') : "Type " + value.Type + " · " + value.Bytes.Length + " bytes";
    public void FilterPresets(string text)
    {
        Presets.Clear(); foreach (var preset in _presets.Where(preset => preset.Name.Contains(text ?? "", StringComparison.OrdinalIgnoreCase) &&
            (SelectedSection?.Id is null or "all" || _catalog!.Presets.Single(item => item.Id == preset.Id).Selections.All(selection => _all.Any(row => row.Id == selection.SettingId && row.SectionId == SelectedSection.Id)))).Take(50)) Presets.Add(preset);
    }
    public void FindSetting(string query) { SelectedSection = Sections[0]; Search = query; }
    private void Filter()
    {
        var searching = !string.IsNullOrWhiteSpace(Search);
        Rows = new(_all.Where(row => (searching || SelectedSection?.Id is null or "all" || row.SectionId == SelectedSection.Id) && (_focusedSetting is null || row.Id == _focusedSetting) && (ShowAdvanced || row.HasPendingChange || !row.Definition.Advanced && !row.UnavailableHere) && (searching || Category == "All groups" || row.Topic == Category) && (Source == "All sources" || row.Definition.Sources.Any(source => source.Product == Source)) &&
            (!searching || (row.Name + " " + row.Description + " " + row.Sources).Contains(Search.Trim(), StringComparison.OrdinalIgnoreCase)))
            .OrderBy(row => row.IsNetwork ? row.Topic switch { "Connection" => 0, "Adapter" => 1, "Local network" => 2, "Wireless" => 3, "Firewall" => 4, "DNS" => 5, _ => 6 } : 0).ThenBy(row => row.Name, StringComparer.OrdinalIgnoreCase));
        OnPropertyChanged(nameof(HasRows)); OnPropertyChanged(nameof(ShowEmpty)); OnPropertyChanged(nameof(VisibleCount));
    }
    public async Task ReviewOwnershipAsync(string path)
    {
        if (!CanEdit) return;
        Busy = true; Invalidate();
        var before = DataGeneration.Snapshot();
        var own = DataGeneration.BeginOwn();
        try
        {
            var review = await App.Operations.PreviewOwnershipAsync(path);
            _catalog = (await App.Operations.ReadWindowsTweakCatalogAsync(true)).Catalog;
            ProfileId = review.Plan.ProfileId; _review = review;
            AcceptOwn(before, own);
            foreach (var change in review.Plan.Controls?.Changes ?? []) AddNativeChange(change, review.Plan.Profiles);
            Status = "Review file ownership"; Detail = path + "\nChanges this item's permissions only. File contents and child items are not changed.";
        }
        catch (Exception error) { Status = "Couldn't review file ownership."; Detail = error.Message; }
        finally { DataGeneration.EndOwn(); Busy = false; }
    }
    private void AcceptOwn(long before, DataGeneration.OwnChanges own)
    {
        if (_loadedGeneration >= 0 && _loadedGeneration == before && StaleNotice.Length == 0 && DataGeneration.OwnAccepted(before, own)) _loadedGeneration = before + own.Bumps;
    }
    public async Task OwnAsync(Func<Task> operation)
    {
        var before = DataGeneration.Snapshot();
        var own = DataGeneration.BeginOwn();
        try { await operation(); AcceptOwn(before, own); }
        finally { DataGeneration.EndOwn(); }
    }
    private void Invalidate() { _revision++; _reviewingRecovery = false; _review = null; _reviewedChoices = null; _restoringChoices = false; _deferredDetail = ""; Approved = false; AcceptedDataLoss = false; Changes.Clear(); Notify(); }
    private void Notify()
    {
        UpdateSections();
        foreach (var name in new[] { nameof(HasValueChanges), nameof(HasFpsPreset), nameof(ShowEmpty), nameof(CanRefresh), nameof(CanEdit), nameof(CanReviewRecovery), nameof(CanApproveReview), nameof(ShowProfileName), nameof(CanReview), nameof(CanApply), nameof(CanRestore), nameof(HasReview), nameof(HasDataLoss), nameof(DataLossText), nameof(ApplyLabel), nameof(SelectionText) }) OnPropertyChanged(name);
    }

    private void SetLoadedStatus(TweakInspection inspection)
    {
        if (_recovery?.Pending is { } pending)
        {
            Status = pending.Phase == "awaiting-restart"
                ? "Restart required to finish Windows settings recovery"
                : "Windows settings recovery needs review";
            Detail = pending.Phase == "awaiting-restart"
                ? "Restart Windows (choose Restart, not Shut down), then refresh and review recovery before selecting more settings."
                : "An earlier Windows settings change was interrupted. Review recovery before selecting more settings.";
            return;
        }
        Status = _all.Count + " settings";
        Detail = inspection.State?.Notices.Length > 0 ? string.Join("\n", inspection.State.Notices) : "Flip the switches you want, check the changes, then apply. Switches that are already on are already set on this PC.";
    }
}
