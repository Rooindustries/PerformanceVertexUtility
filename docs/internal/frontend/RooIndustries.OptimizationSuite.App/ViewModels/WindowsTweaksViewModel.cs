using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
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
    [ObservableProperty] private string _name;
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
    public string ActionAutomationId => Id + ".value";
    public string SelectionAutomationId => Id + ".select";
    public string DetailsAutomationId => Id + ".details";
    public TweakChoice[] Choices { get; }
    public TweakChoice[] ActionChoices { get; }
    public TweakAlternative[] Alternatives { get; }
    private TweakChoice _action;
    public TweakChoice Action
    {
        get => _action;
        set
        {
            if (value is null || !ActionChoices.Contains(value) || !SetProperty(ref _action, value)) return;
            if (ToggleOn) Selected = value;
            OnPropertyChanged(nameof(ActionNote));
        }
    }
    private TweakChoice _selected;
    public TweakChoice Selected
    {
        get => _selected;
        set
        {
            if (value is null || !SetProperty(ref _selected, value)) return;
            if (value.Id.Length > 0 && ActionChoices.Contains(value)) _action = value;
            SyncToggle(); OnPropertyChanged(nameof(Action)); OnPropertyChanged(nameof(ActionNote)); OnPropertyChanged(nameof(CanApplySelected)); OnPropertyChanged(nameof(ChoiceStatus));
        }
    }
    [ObservableProperty] private string _current = "Not checked";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private bool _available;
    [ObservableProperty] private bool _toggleOn;
    private bool _syncingToggle;
    private TweakSettingStatus? _observed;
    public bool HasToggle => ActionChoices.Length > 0;
    public bool HasValuePicker => ActionChoices.Length > 1;
    public string ToggleOnLabel => "Selected";
    public string ToggleOffLabel => "Keep current";
    public string ActionNote => Action.Name == "Use Windows default" ? "Clears this local override. Another Windows policy may still control the setting." : "";
    public bool CanApplySelected => Selected.Id.Length > 0 && Available && _observed?.AvailableChoices?.Contains(Selected.Id) != false;
    public string ChoiceStatus => Selected.Id.Length == 0 || CanApplySelected ? "" : "Selected · save for later";
    partial void OnToggleOnChanged(bool value)
    {
        if (!_syncingToggle && HasToggle) Selected = value ? Action : Choices[0];
    }
    private void SyncToggle()
    {
        _syncingToggle = true;
        ToggleOn = Selected.Id.Length > 0;
        _syncingToggle = false;
    }
    public WindowsTweakRow(TweakDefinition definition, IReadOnlyDictionary<string, TweakDefinition> definitions, Action<string> showSetting)
    {
        Definition = definition; Presentation = WindowsTweakPresentation.For(definition); _name = Presentation.Name ?? definition.Name;
        Alternatives = (definition.Alternatives ?? []).Where(definitions.ContainsKey).Select(id => new TweakAlternative(
            (WindowsTweakPresentation.For(definitions[id]).Name ?? definitions[id].Name) + (definitions[id].Options.SelectMany(option => option.Changes).FirstOrDefault()?.Address.Hive == "LocalMachine" ? " · Entire PC" : " · This user"),
            new RelayCommand(() => showSetting(id)))).ToArray();
        Choices = [new("", "Keep current"), .. definition.Options.Select(option => new TweakChoice(option.Id, DisplayChoice(WindowsTweakPresentation.Choice(definition, option))))];
        ActionChoices = Choices.Skip(1).ToArray();
        var resetIds = definition.Options.Where(option => IsDefaultAction(option.Name) || IsDefaultAction(WindowsTweakPresentation.Choice(definition, option))).Select(option => option.Id).ToHashSet();
        _action = ActionChoices.FirstOrDefault(choice => !resetIds.Contains(choice.Id)) ?? ActionChoices.First();
        _selected = Choices[0];
    }
    public static string DisplayChoice(string name) => name is "Remove this override" or "Not configured" ? "Use Windows default" : name;
    private static bool IsDefaultAction(string name) => name is "Remove this override" or "Windows default" or "Use Windows default" or "Not configured" or "source-default" or "Return to previous plan" or "Remove boot override";
    public void Observe(TweakSettingStatus? status)
    {
        _observed = status;
        Name = Presentation.Name ?? (status?.Controls?.FirstOrDefault() is { Address.Kind: "service", DisplayName: { } serviceName } ? serviceName : Definition.Name);
        Available = Choices.Length > 1 && status is { Supported: true, Error: null } && status.Controls?.Any(control => control.RestartPending) != true;
        Detail = status is null ? "Refresh to read this setting." : status.Controls?.Any(control => control.RestartPending) == true ? "Restart Windows to finish this feature change." : status.Error ?? (status.Supported == false ? "Not available on this Windows build or edition." : "");
        if (Detail.Length == 0) Detail = string.Join("\n", (status?.Controls ?? []).Where(control => control.Address.Kind is "timer" or "download-blocker" or "firewall-profile").Select(control => control.DisplayName).Where(text => !string.IsNullOrWhiteSpace(text)));
        Current = status is null || status.Error is not null ? "Not read"
            : status.Observations.All(read => read.Value is null) && (status.Controls ?? []).All(read => read.Value.ValueKind == System.Text.Json.JsonValueKind.Null) ? "No override"
            : status.ConfiguredChoices.Length > 0 ? string.Join(" / ", Choices.Where(choice => status.ConfiguredChoices.Contains(choice.Id)).Select(choice => choice.Name)) : "Custom value";
        if (status is { Error: null, Controls: [var control] } && control.Address.Kind == "timer") Current = control.Value.GetBoolean() ? "Active" : "Stopped";
        if (Detail.Contains("Office installation", StringComparison.Ordinal)) Detail = "Office was not detected. You can save this choice before installing it.";
        else if (Detail.StartsWith("No choice applies", StringComparison.Ordinal)) Detail = "This Windows or app version does not use this setting. You can keep a saved choice for a matching installation.";
        else if (Detail.Contains("Win32 1060", StringComparison.Ordinal)) Detail = "This Windows service is not installed.";
        else if (Detail.Contains("0x80070002", StringComparison.Ordinal) && Definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address.Kind == "scheduled-task")) Detail = "This Windows task is not installed.";
        else if (IsNetwork && status?.Error is { } error) Detail = error.Contains("adapter", StringComparison.OrdinalIgnoreCase) || error.Contains("devices expose", StringComparison.OrdinalIgnoreCase)
            ? "The current adapter does not expose this option. You can save a choice for a compatible adapter." : "Windows could not read this preference. Refresh to try again.";
        SyncToggle(); OnPropertyChanged(nameof(CanApplySelected)); OnPropertyChanged(nameof(ChoiceStatus));
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
    public ObservableCollection<WindowsTweakRow> Rows { get; } = new();
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
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private string _summary = "";
    public WindowsTweaksViewModel() { _selectedSection = Sections[0]; }
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
    public bool CanReview => !Busy && !HasPendingRecovery && _catalog is not null && !string.IsNullOrWhiteSpace(ProfileId) && _all.Any(row => row.Selected.Id.Length > 0);
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
    public string ApplyLabel => _reviewingRecovery ? CheckingRestart ? "Check restart completion" : "Recover interrupted changes" : _restoringChoices ? _review is null ? "Remove saved choices" : "Restore settings" : _review is null && _reviewedChoices is not null ? "Save choices" : _review?.Plan.Selections.Length == 0 ? "Restore settings" : _review is not null && Changes.Count == 0 ? "Save profile" : "Apply settings";
    public string SelectionText => _all.Count(row => row.Selected.Id.Length > 0) + " selected";
    partial void OnShowAdvancedChanged(bool value) => Filter();
    partial void OnSearchChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnCategoryChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnSourceChanged(string value) { _focusedSetting = null; Filter(); }
    partial void OnBusyChanged(bool value) => Notify();
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
        LoadProfile();
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
        }
        _loading = false; Invalidate(); Notify();
        SetSelectionStatus(available.Length == 1 ? "1 preset choice added" : available.Length + " preset choices added", "Review the selected values. Choices with missing requirements can be saved without changing Windows.");
    }
    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        Busy = true; Invalidate();
        try
        {
            var catalog = await App.Operations.ReadWindowsTweakCatalogAsync();
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
                });
                row.PropertyChanged += RowChanged; _all.Add(row);
            }
            Filter();
            UpdateSections();
            _savedChoices = await App.Operations.ReadWindowsChoicesAsync();
            _recovery = await App.Operations.ReadWindowsRecoveryAsync();
            OnPropertyChanged(nameof(HasPendingRecovery));
            var inspection = await App.Operations.ReadWindowsTweaksAsync();
            _loading = true;
            _inspection = inspection;
            foreach (var row in _all) row.Observe(inspection.Settings.SingleOrDefault(item => item.Id == row.Id));
            UpdateTopics();
            Fill(Sources, "All sources", _all.SelectMany(row => row.Definition.Sources.Select(source => source.Product)));
            if (!Categories.Contains(Category)) Category = "All groups";
            if (!Sources.Contains(Source)) Source = "All sources";
            OnPropertyChanged(nameof(Category)); OnPropertyChanged(nameof(Source));
            Profiles.Clear(); foreach (var profile in inspection.State?.Profiles ?? [])
            {
                var target = profile.Controls?.FirstOrDefault(claim => claim.Target.Address.Kind == "file-ownership")?.Target.Address.Target;
                var label = target is not null ? "File ownership: " + System.IO.Path.GetFileName(target.StartsWith("selected:", StringComparison.Ordinal) ? target[9..] : target)
                    : profile.Id.StartsWith("restore-point-", StringComparison.Ordinal) ? "Restore-point temporary policy" : null;
                Profiles.Add(new(profile.Id, label));
            }
            foreach (var profile in _savedChoices.Profiles.Where(profile => Profiles.All(existing => existing.Id != profile.Id))) Profiles.Add(new(profile.Id, profile.Id + " · saved choices"));
            _presets.Clear(); foreach (var preset in _catalog.Presets) _presets.Add(new(preset.Id, preset.Name));
            FilterPresets("");
            SelectedPreset = null; _loading = false;
            LoadProfile(); Filter();
            SetLoadedStatus(inspection);
            Summary = "Windows build " + inspection.Context.WindowsBuild + " · " + inspection.Context.Edition;
        }
        catch (Exception error) { _inspection = null; foreach (var row in _all) row.Observe(null); LoadProfile(); Filter(); Status = "Couldn't load Windows settings."; Detail = error.Message; }
        finally { _loading = false; Busy = false; }
    }
    private static void Fill(ObservableCollection<string> target, string first, IEnumerable<string> values)
    {
        target.Clear(); target.Add(first); foreach (var value in values.Distinct().Order(StringComparer.OrdinalIgnoreCase)) target.Add(value);
    }
    private void LoadProfile()
    {
        _loading = true;
        var selected = _savedChoices?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? _inspection?.State?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? [];
        foreach (var row in _all) row.Selected = row.Choices.FirstOrDefault(choice => selected.Any(item => item.SettingId == row.Id && item.OptionId == choice.Id)) ?? row.Choices[0];
        _loading = false; Invalidate(); Notify();
    }
    private void RowChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_loading || !CanEdit || args.PropertyName != nameof(WindowsTweakRow.Selected)) return;
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
            section.SelectedCount = _all.Count(row => (section.Id == "all" || row.SectionId == section.Id) && row.Selected.Id.Length > 0);
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
        _loading = true; foreach (var row in _all) row.Selected = row.Choices[0]; SelectedPreset = null; _loading = false; Invalidate(); Notify();
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
            var selections = restore ? Array.Empty<TweakSelection>() : _all.Where(row => row.Selected.Id.Length > 0).Select(row => new TweakSelection(row.Id, row.Selected.Id)).ToArray();
            if (!restore && selections.Length == 0) return;
            var selectedReady = restore ? selections : _all.Where(row => row.CanApplySelected).Select(row => new TweakSelection(row.Id, row.Selected.Id)).ToArray();
            var retained = restore ? Array.Empty<TweakSelection>() : (_inspection?.State?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? [])
                .Where(selection => selectedReady.All(selected => selected.SettingId != selection.SettingId)).ToArray();
            var ready = selectedReady.Concat(retained).ToArray();
            var deferred = restore ? Array.Empty<WindowsTweakRow>() : _all.Where(row => row.Selected.Id.Length > 0 && !row.CanApplySelected).ToArray();
            _deferredDetail = string.Join("\n", deferred.Select(row => row.Name + ": " + (row.Detail.Length == 0 ? "This choice needs a matching Windows or app version." : row.Detail)));
            _reviewedChoices = selections; _restoringChoices = restore;
            if (ready.Length == 0 && _inspection?.State?.Profiles.Any(profile => profile.Id == ProfileId.Trim()) != true)
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
                var ids = (_inspection?.State?.Profiles ?? []).Concat(_review.Plan.Profiles).SelectMany(profile => profile.Claims).Where(claim => claim.Target.Id == change.Before.Id).Select(claim => claim.SettingId).ToArray();
                var row = _all.FirstOrDefault(item => ids.Contains(item.Id));
                Changes.Add(new(row?.Name ?? change.Before.Address.ValueName ?? "Setting", DescribeSetting(row?.Definition, change.Before.Value), DescribeSetting(row?.Definition, change.After),
                    row?.Scope ?? (change.Before.Address.Hive == "CurrentUser" ? "This user" : "Entire PC")));
            }
            foreach (var change in _review.Plan.Controls?.Changes ?? []) AddNativeChange(change);
            Status = Changes.Count == 0 ? "Selected values already match" : Changes.Count == 1 ? "1 change ready to review" : Changes.Count + " changes ready to review";
            Detail = restore ? "Shared settings stay active while another profile needs them." : Changes.Count == 0 ? "Save this profile to keep track of these choices." : "Review these values and confirm before applying.";
            if (deferred.Length > 0) Detail += "\n" + deferred.Length + " choices will be saved with requirements pending:\n" + _deferredDetail;
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
        try
        {
            if (_reviewingRecovery)
            {
                await App.Operations.RecoverWindowsTweaksAsync(_recovery!.PendingHash!);
                Invalidate(); Busy = false; await RefreshAsync(); return;
            }
            var choiceOnly = _review is null;
            var deferred = _deferredDetail;
            if (!restoring && _reviewedChoices is not null)
            {
                _savedChoices = await App.Operations.SaveWindowsChoicesAsync(_catalog!, ProfileId.Trim(), _reviewedChoices, _savedChoices?.Revision);
                choicesSaved = true;
            }
            var result = _review is null ? null : await App.Operations.ApplyWindowsTweaksAsync(_review, AcceptedDataLoss);
            windowsApplied = result is not null;
            if (restoring && _reviewedChoices is not null) _savedChoices = await App.Operations.SaveWindowsChoicesAsync(_catalog!, ProfileId.Trim(), _reviewedChoices, _savedChoices?.Revision);
            _inspection = null; Invalidate();
            Busy = false; await RefreshAsync();
            if (_inspection is null) { Status = "Settings saved; current values could not be reloaded."; return; }
            Status = choiceOnly ? restoring ? "Saved choices removed" : "Choices saved" : result!.Changed ? "Windows settings saved" : "Profile saved";
            Detail = choiceOnly ? "No Windows settings were changed.\n" + deferred : result!.State.Notices.Length > 0 ? string.Join("\n", result.State.Notices) : deferred.Length > 0 ? "Applied the reviewed Windows changes. These saved choices still need their requirements:\n" + deferred : "Current settings have been refreshed. Follow the restart or sign-out notes shown with the settings.";
        }
        catch (Exception error)
        {
            Invalidate(); Busy = false; await RefreshAsync();
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
            AddNativeChange(new(change.Before with { Value = change.After }, change.Before.Value));
        Status = CheckingRestart ? "Check Windows feature changes after restarting" : "Review recovery of the interrupted operation";
        Detail = CheckingRestart ? "Restart Windows first. This checks the final feature states before closing the pending record." : "Only values still matching the interrupted operation will be restored. Newer edits are preserved.";
        Notify();
    }
    private void AddNativeChange(ControlMutation change)
    {
        var row = _all.FirstOrDefault(item => item.Definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address == change.Before.Address));
        if (row?.IsNetwork == true)
        {
            string Label(System.Text.Json.JsonElement value)
            {
                if (value.ValueKind == System.Text.Json.JsonValueKind.Null) return "No override";
                var choice = row.Definition.Options.FirstOrDefault(option => (option.Controls ?? []).Any(control => control.Address == change.Before.Address && ControlValues.Equal(change.Before.Expand(control.Value, true), value)));
                return choice is null ? "Custom preference" : WindowsTweakRow.DisplayChoice(WindowsTweakPresentation.Choice(row.Definition, choice));
            }
            Changes.Add(new(row.Name, Label(change.Before.Value), Label(change.After), row.Scope));
            return;
        }
        var name = _catalog?.Settings.FirstOrDefault(row => row.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address == change.Before.Address))?.Name ?? change.Before.Address.Target;
        if (change.Before.Address.Kind is "windows-features" or "mitigations")
        {
            var fields = change.After.EnumerateObject().Where(property => property.Name != MitigationControl.SnapshotField && !ControlValues.Equal(property.Value, change.Before.Value.GetProperty(property.Name))).Select(property => property.Name).ToArray();
            Changes.Add(new(name, string.Join("; ", fields.Select(field => field + ": " + change.Before.Value.GetProperty(field))), string.Join("; ", fields.Select(field => field + ": " + change.After.GetProperty(field))), change.Before.Address.Kind + " · " + change.Before.Address.Target));
            return;
        }
        Changes.Add(new(name, DescribeControl(change.Before.Address, change.Before.Value), DescribeControl(change.Before.Address, change.After), change.Before.Address.Kind + " · " + change.Before.Address.Target + " · " + change.Before.Address.Property));
    }
    private static string DescribeControl(ControlAddress address, System.Text.Json.JsonElement value)
    {
        if (value.ValueKind == System.Text.Json.JsonValueKind.Null) return "No override";
        if (value.ValueKind is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False)
            return address.Property == "running" ? value.GetBoolean() ? "Running" : "Stopped" : value.GetBoolean() ? "Enabled" : "Disabled";
        if (address.Kind == "service" && address.Property == "startup") return value.GetInt32() switch { 0 => "Boot", 1 => "System", 2 => "Automatic", 3 => "Manual", 4 => "Disabled", _ => value.ToString() };
        if (address.Kind == "hibernation") return value.GetProperty("mode").GetString() + " · Fast Startup " + (value.GetProperty("fastStartup").ValueKind == System.Text.Json.JsonValueKind.Null ? "not configured" : value.GetProperty("fastStartup").GetUInt32() == 0 ? "off" : "on");
        if (address.Kind == "hosts") return value.GetProperty("block").ValueKind == System.Text.Json.JsonValueKind.Null ? "No Roo Industries hosts block" : "Reviewed hosts block present";
        if (address.Kind is "file-acl" or "file-ownership")
        {
            var acl = new RawAcl(Convert.FromBase64String(value.GetProperty("dacl").GetString()!), 0);
            var explicitRules = Enumerable.Range(0, acl.Count).Select(index => acl[index]).OfType<CommonAce>().Where(ace => (ace.AceFlags & AceFlags.Inherited) == 0)
                .Select(ace => (ace.AceQualifier == AceQualifier.AccessDenied ? "Deny " : "Allow ") + Account(ace.SecurityIdentifier.Value) + ": " + ((FileSystemRights)ace.AccessMask).ToString());
            return "Owner: " + Account(value.GetProperty("owner").GetString()!) + "\n" + string.Join("\n", explicitRules.DefaultIfEmpty("Permissions inherited from the parent folder"));
        }
        if (address.Kind == "power-plan") return "Active plan: " + value.GetProperty("active").GetString();
        if (value.ValueKind == System.Text.Json.JsonValueKind.Object && value.TryGetProperty("addresses", out var addresses)) return addresses.GetArrayLength() + " blocked addresses or ranges";
        var text = value.ToString(); return text.Length > 1000 ? text[..1000] + "…" : text;
    }
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
                if (option.Changes is not [var change]) continue;
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
        Rows.Clear();
        foreach (var row in _all.Where(row => (SelectedSection?.Id is null or "all" || row.SectionId == SelectedSection.Id) && (_focusedSetting is null || row.Id == _focusedSetting) && (ShowAdvanced || !row.Definition.Advanced) && (Category == "All groups" || row.Topic == Category) && (Source == "All sources" || row.Definition.Sources.Any(source => source.Product == Source)) &&
            (string.IsNullOrEmpty(Search) || (row.Name + " " + row.Description + " " + row.Sources).Contains(Search, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(row => row.IsNetwork ? row.Topic switch { "Connection" => 0, "Adapter" => 1, "Local network" => 2, "Wireless" => 3, "Firewall" => 4, "DNS" => 5, _ => 6 } : 0).ThenBy(row => row.Name, StringComparer.OrdinalIgnoreCase)) Rows.Add(row);
        OnPropertyChanged(nameof(HasRows)); OnPropertyChanged(nameof(ShowEmpty)); OnPropertyChanged(nameof(VisibleCount));
    }
    public async Task ReviewOwnershipAsync(string path)
    {
        if (!CanEdit) return;
        Busy = true; Invalidate();
        try
        {
            var review = await App.Operations.PreviewOwnershipAsync(path);
            _catalog = (await App.Operations.ReadWindowsTweakCatalogAsync()).Catalog;
            ProfileId = review.Plan.ProfileId; _review = review;
            foreach (var change in review.Plan.Controls?.Changes ?? []) AddNativeChange(change);
            Status = "Review file ownership"; Detail = path + "\nChanges this item's permissions only. File contents and child items are not changed.";
        }
        catch (Exception error) { Status = "Couldn't review file ownership."; Detail = error.Message; }
        finally { Busy = false; }
    }
    private void Invalidate() { _revision++; _reviewingRecovery = false; _review = null; _reviewedChoices = null; _restoringChoices = false; _deferredDetail = ""; Approved = false; AcceptedDataLoss = false; Changes.Clear(); Notify(); }
    private void Notify()
    {
        UpdateSections();
        foreach (var name in new[] { nameof(HasValueChanges), nameof(ShowEmpty), nameof(CanRefresh), nameof(CanEdit), nameof(CanReviewRecovery), nameof(CanApproveReview), nameof(ShowProfileName), nameof(CanReview), nameof(CanApply), nameof(CanRestore), nameof(HasReview), nameof(HasDataLoss), nameof(DataLossText), nameof(ApplyLabel), nameof(SelectionText) }) OnPropertyChanged(name);
    }

    private void SetLoadedStatus(TweakInspection inspection)
    {
        if (_recovery?.Pending is { } pending)
        {
            Status = pending.Phase == "awaiting-restart"
                ? "Restart required to finish Windows settings recovery"
                : "Windows settings recovery needs review";
            Detail = pending.Phase == "awaiting-restart"
                ? "Restart Windows, then refresh and review recovery before selecting more settings."
                : "An earlier Windows settings change was interrupted. Review recovery before selecting more settings.";
            return;
        }
        Status = _all.Count + " settings";
        Detail = inspection.State?.Notices.Length > 0 ? string.Join("\n", inspection.State.Notices) : "Choose settings, review the changes, then apply.";
    }
}
