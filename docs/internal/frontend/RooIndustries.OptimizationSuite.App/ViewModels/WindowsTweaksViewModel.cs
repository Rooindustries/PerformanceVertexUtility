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
public partial class WindowsTweakRow : ObservableObject
{
    public TweakDefinition Definition { get; }
    public string Id => Definition.Id;
    [ObservableProperty] private string _name;
    public string Category => Definition.Category;
    public string Scope => Definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address.Kind == "timer-startup") ? "This user" : Definition.Options.SelectMany(option => option.Changes).FirstOrDefault()?.Address.Hive switch
    {
        "CurrentUser" => "This user", "Users" => "Sign-in screen", "LocalMachine" => "Entire PC", _ => "This PC",
    };
    public string Context => Category + " · " + Scope;
    public string Description => Definition.Description;
    public string Sources => string.Join(" · ", Definition.Sources.Select(source => source.Product).Distinct());
    public string Refresh => Definition.Refresh.StartsWith("Policy supports live refresh", StringComparison.OrdinalIgnoreCase) || Definition.Refresh is "reopen affected apps" ? "" : Definition.Refresh switch { "none" => "", "restart" => "Restart Windows after applying", "sign-out" => "Sign out after applying", "explorer-refresh" => "Reopen Explorer after applying", "new-windows-or-sign-out" => "Reopen affected apps or sign out", _ => Definition.Refresh };
    public TweakChoice[] Choices { get; private set; }
    [ObservableProperty] private TweakChoice _selected;
    [ObservableProperty] private string _current = "Not checked";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private bool _available;
    partial void OnSelectedChanged(TweakChoice value) { if (value is null) Selected = Choices[0]; }
    public WindowsTweakRow(TweakDefinition definition)
    {
        Definition = definition; _name = definition.Name;
        Choices = [new("", "Keep current"), .. definition.Options.Select(option => new TweakChoice(option.Id, option.Name))];
        _selected = Choices[0];
    }
    public void Observe(TweakSettingStatus? status)
    {
        Choices = [Choices[0], .. Definition.Options.Where(option => status?.AvailableChoices?.Contains(option.Id) != false).Select(option => new TweakChoice(option.Id, option.Name))];
        Name = status?.Controls?.FirstOrDefault() is { Address.Kind: "service", DisplayName: { } serviceName } ? serviceName : Definition.Name;
        Available = Choices.Length > 1 && status is { Supported: true, Error: null } && status.Controls?.Any(control => control.RestartPending) != true;
        Detail = status?.Controls?.Any(control => control.RestartPending) == true ? "Restart Windows to finish this feature change." : status?.Error ?? (status?.Supported == false ? "Not available on this Windows build or edition." : "");
        if (Detail.Length == 0) Detail = string.Join("\n", (status?.Controls ?? []).Where(control => control.Address.Kind is "timer" or "download-blocker" or "firewall-profile").Select(control => control.DisplayName).Where(text => !string.IsNullOrWhiteSpace(text)));
        Current = status is null || status.Error is not null ? "Unavailable"
            : status.Observations.All(read => read.Value is null) && (status.Controls ?? []).All(read => read.Value.ValueKind == System.Text.Json.JsonValueKind.Null) ? "Not configured"
            : status.ConfiguredChoices.Length > 0 ? string.Join(" / ", Definition.Options.Where(choice => status.ConfiguredChoices.Contains(choice.Id)).Select(choice => choice.Name)) : "Custom value";
        if (status is { Error: null, Controls: [var control] } && control.Address.Kind == "timer") Current = control.Value.GetBoolean() ? "Active" : "Stopped";
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
    public ObservableCollection<WindowsTweakRow> Rows { get; } = new();
    public ObservableCollection<string> Categories { get; } = new();
    public ObservableCollection<string> Sources { get; } = new();
    public ObservableCollection<WindowsProfileChoice> Profiles { get; } = new();
    public ObservableCollection<TweakChoice> Presets { get; } = new();
    public ObservableCollection<WindowsChangeRow> Changes { get; } = new();
    [ObservableProperty] private bool _showAdvanced;
    [ObservableProperty] private bool _showUnavailable;
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private string _category = "All categories";
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
    public bool CanEdit => !Busy;
    public bool ShowProfileName => !ProfileId.StartsWith("file-permissions-", StringComparison.Ordinal) && !ProfileId.StartsWith("restore-point-", StringComparison.Ordinal);
    public bool CanReview => !Busy && !HasPendingRecovery && _catalog is not null && !string.IsNullOrWhiteSpace(ProfileId) && _all.Any(row => row.Selected.Id.Length > 0);
    public bool CanApply => !Busy && (_review is not null || _reviewingRecovery && _recovery?.Pending is not null) && Approved && (!HasDataLoss || AcceptedDataLoss);
    public bool HasDataLoss => _review?.Plan.DataLoss.Length > 0;
    public string DataLossText => string.Join("\n", _review?.Plan.DataLoss ?? []);
    public bool HasPendingRecovery => _recovery?.Pending is not null;
    public bool CanRestore => !Busy && _inspection?.State?.Profiles.Any(profile => profile.Id == ProfileId.Trim()) == true;
    public bool HasValueChanges => Changes.Count > 0;
    public bool HasReview => _review is not null || _reviewingRecovery;
    public bool HasRows => Rows.Count > 0;
    public bool ShowEmpty => !Busy && _inspection is not null && !HasRows;
    public bool CheckingRestart => _recovery?.Pending is { Phase: "awaiting-restart" } pending && _recovery.State?.History.Any(item => item.OperationId == pending.Plan.OperationId) == true;
    public string ApplyLabel => _reviewingRecovery ? CheckingRestart ? "Check restart completion" : "Recover interrupted changes" : _review?.Plan.Selections.Length == 0 ? "Restore settings" : _review is not null && Changes.Count == 0 ? "Save profile" : "Apply settings";
    public string SelectionText => _all.Count(row => row.Selected.Id.Length > 0) + " selected";
    partial void OnShowAdvancedChanged(bool value) => Filter();
    partial void OnShowUnavailableChanged(bool value) => Filter();
    partial void OnSearchChanged(string value) => Filter();
    partial void OnCategoryChanged(string value) => Filter();
    partial void OnSourceChanged(string value) => Filter();
    partial void OnBusyChanged(bool value) => Notify();
    partial void OnApprovedChanged(bool value) => Notify();
    partial void OnAcceptedDataLossChanged(bool value) => Notify();
    partial void OnProfileIdChanged(string value) { Invalidate(); Notify(); }
    partial void OnSelectedProfileChanged(WindowsProfileChoice? value)
    {
        if (_loading || value is null) return;
        ProfileId = value.Id;
        LoadProfile();
    }
    partial void OnSelectedPresetChanged(TweakChoice? value)
    {
        if (_loading || value is null || _catalog is null) return;
        var preset = _catalog.Presets.Single(item => item.Id == value.Id);
        var available = preset.Selections.Where(selection => _all.Any(row => row.Id == selection.SettingId && row.Available && row.Choices.Any(choice => choice.Id == selection.OptionId))).ToArray();
        var conflicts = available.GroupBy(selection => selection.SettingId).Where(group => group.Select(selection => selection.OptionId).Distinct().Count() > 1).ToArray();
        if (conflicts.Length > 0) { Status = "This preset has conflicting choices"; Detail = string.Join(", ", conflicts.Select(group => _all.Single(row => row.Id == group.Key).Name)) + ". Choose these settings individually."; return; }
        _loading = true;
        foreach (var selection in available)
        {
            var row = _all.Single(item => item.Id == selection.SettingId);
            row.Selected = row.Choices.FirstOrDefault(choice => choice.Id == selection.OptionId) ?? row.Choices[0];
        }
        _loading = false; Invalidate(); Notify();
        Status = available.Length + " preset choices added";
        Detail = available.Length == preset.Selections.Length ? "Review the selected values before applying." : (preset.Selections.Length - available.Length) + " choices are unavailable on this PC and were omitted.";
    }
    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        Busy = true; Invalidate();
        try
        {
            var catalog = await App.Operations.ReadWindowsTweakCatalogAsync();
            _recovery = await App.Operations.ReadWindowsRecoveryAsync();
            OnPropertyChanged(nameof(HasPendingRecovery));
            var inspection = await App.Operations.ReadWindowsTweaksAsync();
            _loading = true;
            _catalog = catalog.Catalog; _inspection = inspection;
            foreach (var row in _all) row.PropertyChanged -= RowChanged;
            _all.Clear();
            foreach (var definition in _catalog.Settings)
            {
                var row = new WindowsTweakRow(definition); row.Observe(inspection.Settings.SingleOrDefault(item => item.Id == definition.Id));
                row.PropertyChanged += RowChanged; _all.Add(row);
            }
            Fill(Categories, "All categories", _all.Select(row => row.Category));
            Fill(Sources, "All sources", _all.SelectMany(row => row.Definition.Sources.Select(source => source.Product)));
            if (!Categories.Contains(Category)) Category = "All categories";
            if (!Sources.Contains(Source)) Source = "All sources";
            OnPropertyChanged(nameof(Category)); OnPropertyChanged(nameof(Source));
            Profiles.Clear(); foreach (var profile in inspection.State?.Profiles ?? [])
            {
                var target = profile.Controls?.FirstOrDefault(claim => claim.Target.Address.Kind == "file-ownership")?.Target.Address.Target;
                var label = target is not null ? "File ownership: " + System.IO.Path.GetFileName(target.StartsWith("selected:", StringComparison.Ordinal) ? target[9..] : target)
                    : profile.Id.StartsWith("restore-point-", StringComparison.Ordinal) ? "Restore-point temporary policy" : null;
                Profiles.Add(new(profile.Id, label));
            }
            bool Available(TweakSelection selection) => _all.Any(row => row.Id == selection.SettingId && row.Available && row.Choices.Any(choice => choice.Id == selection.OptionId));
            _presets.Clear(); foreach (var preset in _catalog.Presets.Where(preset => preset.AvailableOnly ? preset.Selections.Any(Available) : preset.Selections.All(Available))) _presets.Add(new(preset.Id, preset.Name));
            FilterPresets("");
            SelectedPreset = null; _loading = false;
            LoadProfile(); Filter();
            Status = _all.Count(row => row.Available) + " available settings · " + _all.Count(row => !row.Available) + " unavailable";
            Detail = inspection.State?.Notices.Length > 0 ? string.Join("\n", inspection.State.Notices) : "Choose settings, review the changes, then apply.";
            Summary = "Windows build " + inspection.Context.WindowsBuild + " · " + inspection.Context.Edition;
        }
        catch (Exception error) { _inspection = null; foreach (var row in _all) row.Observe(null); Status = "Couldn't load Windows settings."; Detail = error.Message; }
        finally { _loading = false; Busy = false; }
    }
    private static void Fill(ObservableCollection<string> target, string first, IEnumerable<string> values)
    {
        target.Clear(); target.Add(first); foreach (var value in values.Distinct().Order(StringComparer.OrdinalIgnoreCase)) target.Add(value);
    }
    private void LoadProfile()
    {
        _loading = true;
        var selected = _inspection?.State?.Profiles.SingleOrDefault(profile => profile.Id == ProfileId.Trim())?.Selections ?? [];
        foreach (var row in _all) row.Selected = row.Choices.FirstOrDefault(choice => selected.Any(item => item.SettingId == row.Id && item.OptionId == choice.Id)) ?? row.Choices[0];
        _loading = false; Invalidate(); Notify();
    }
    private void RowChanged(object? sender, PropertyChangedEventArgs args) { if (!_loading && args.PropertyName == nameof(WindowsTweakRow.Selected)) { Invalidate(); Notify(); } }
    [RelayCommand]
    private void ClearSelection()
    {
        if (Busy) return;
        _loading = true; foreach (var row in _all) row.Selected = row.Choices[0]; SelectedPreset = null; _loading = false; Invalidate(); Notify();
        if (!ShowProfileName && _inspection?.State?.Profiles.Any(profile => profile.Id == ProfileId) != true) ProfileId = "my-settings";
        Status = "Nothing selected"; Detail = "Choose settings, review the changes, then apply.";
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
            var review = await App.Operations.PreviewWindowsTweaksAsync(ProfileId.Trim(), selections);
            if (revision != _revision) return;
            _review = review;
            foreach (var change in _review.Plan.Changes)
            {
                var ids = (_inspection?.State?.Profiles ?? []).Concat(_review.Plan.Profiles).SelectMany(profile => profile.Claims).Where(claim => claim.Target.Id == change.Before.Id).Select(claim => claim.SettingId).ToArray();
                var row = _all.FirstOrDefault(item => ids.Contains(item.Id));
                Changes.Add(new(row?.Name ?? change.Before.Address.ValueName ?? "Setting", DescribeSetting(row?.Definition, change.Before.Value), DescribeSetting(row?.Definition, change.After),
                    change.Before.Address.Hive + "\\" + change.Before.Address.KeyPath + " · " + change.Before.Address.ValueName));
            }
            foreach (var change in _review.Plan.Controls?.Changes ?? []) AddNativeChange(change);
            Status = Changes.Count == 0 ? "Selected values already match" : Changes.Count == 1 ? "1 change ready to review" : Changes.Count + " changes ready to review";
            Detail = restore ? "Shared settings stay active while another profile needs them." : Changes.Count == 0 ? "Save this profile to keep track of these choices." : "Review these values and confirm before applying.";
        }
        catch (Exception error) { Invalidate(); Status = "Couldn't prepare these changes."; Detail = error.Message; }
        finally { Busy = false; }
    }
    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (!CanApply) return;
        Busy = true;
        try
        {
            if (_reviewingRecovery)
            {
                await App.Operations.RecoverWindowsTweaksAsync(_recovery!.PendingHash!);
                Invalidate(); Busy = false; await RefreshAsync(); return;
            }
            var result = await App.Operations.ApplyWindowsTweaksAsync(_review!, AcceptedDataLoss);
            _inspection = null; Invalidate();
            Busy = false; await RefreshAsync();
            if (_inspection is null) { Status = "Settings saved; current values could not be reloaded."; return; }
            Status = result.Changed ? "Settings saved" : "No repeated setting changes";
            Detail = result.State.Notices.Length > 0 ? string.Join("\n", result.State.Notices) : "Current settings have been refreshed. Follow any restart or sign-out notes shown with the settings.";
        }
        catch (Exception error) { Invalidate(); Status = "Settings were not confirmed."; Detail = error.Message; }
        finally { Busy = false; }
    }
    [RelayCommand]
    private void ReviewRecovery()
    {
        if (Busy || _recovery?.Pending is not { } pending) return;
        Invalidate(); _reviewingRecovery = true;
        if (!CheckingRestart) foreach (var change in pending.Plan.Controls!.Changes.Take(pending.Attempted))
            AddNativeChange(new(change.Before with { Value = change.After }, change.Before.Value));
        Status = CheckingRestart ? "Check Windows feature changes after restarting" : "Review recovery of the interrupted operation";
        Detail = CheckingRestart ? "Restart Windows first. This checks the final feature states before closing the pending record." : "Only values still matching the interrupted operation will be restored. Newer edits are preserved.";
        Notify();
    }
    private void AddNativeChange(ControlMutation change)
    {
        var name = _catalog?.Settings.FirstOrDefault(row => row.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address == change.Before.Address))?.Name ?? change.Before.Address.Target;
        if (change.Before.Address.Kind is "windows-features" or "mitigations")
        {
            var fields = change.After.EnumerateObject().Where(property => !ControlValues.Equal(property.Value, change.Before.Value.GetProperty(property.Name))).Select(property => property.Name).ToArray();
            Changes.Add(new(name, string.Join("; ", fields.Select(field => field + ": " + change.Before.Value.GetProperty(field))), string.Join("; ", fields.Select(field => field + ": " + change.After.GetProperty(field))), change.Before.Address.Kind + " · " + change.Before.Address.Target));
            return;
        }
        Changes.Add(new(name, DescribeControl(change.Before.Address, change.Before.Value), DescribeControl(change.Before.Address, change.After), change.Before.Address.Kind + " · " + change.Before.Address.Target + " · " + change.Before.Address.Property));
    }
    private static string DescribeControl(ControlAddress address, System.Text.Json.JsonElement value)
    {
        if (value.ValueKind == System.Text.Json.JsonValueKind.Null) return "Not configured";
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
        if (value is null) return "Not configured";
        if (definition is not null)
        {
            foreach (var option in definition.Options)
            {
                if (option.Changes is not [var change]) continue;
                var desired = change.Dword is { } number ? new RegistryValueData(change.Address.ValueName!, 4, BitConverter.GetBytes(number)) : change.Value;
                if (change.Token is { } token ? TweakTokens.Get(value, token.Name) == token.Value : change.Bits is null && TweakRead.SameValue(value, desired)) return option.Name;
            }
        }
        return Describe(value);
    }
    private static string Describe(RegistryValueData? value) => value is null ? "Not configured" : value.Type == 4 ? BitConverter.ToUInt32(value.Bytes).ToString()
        : value.Type is 1 or 2 ? System.Text.Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0') : "Type " + value.Type + " · " + value.Bytes.Length + " bytes";
    public void FilterPresets(string text)
    {
        Presets.Clear(); foreach (var preset in _presets.Where(preset => preset.Name.Contains(text ?? "", StringComparison.OrdinalIgnoreCase)).Take(50)) Presets.Add(preset);
    }
    private void Filter()
    {
        Rows.Clear();
        foreach (var row in _all.Where(row => (ShowAdvanced || !row.Definition.Advanced) && (ShowUnavailable || row.Available) && (Category == "All categories" || row.Category == Category) && (Source == "All sources" || row.Definition.Sources.Any(source => source.Product == Source)) &&
            (string.IsNullOrEmpty(Search) || (row.Name + " " + row.Description + " " + row.Sources).Contains(Search, StringComparison.OrdinalIgnoreCase)))) Rows.Add(row);
        OnPropertyChanged(nameof(HasRows)); OnPropertyChanged(nameof(ShowEmpty));
    }
    public async Task ReviewOwnershipAsync(string path)
    {
        if (Busy) return;
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
    private void Invalidate() { _revision++; _reviewingRecovery = false; _review = null; Approved = false; AcceptedDataLoss = false; Changes.Clear(); Notify(); }
    private void Notify()
    {
        foreach (var name in new[] { nameof(HasValueChanges), nameof(ShowEmpty), nameof(CanEdit), nameof(ShowProfileName), nameof(CanReview), nameof(CanApply), nameof(CanRestore), nameof(HasReview), nameof(HasDataLoss), nameof(DataLossText), nameof(ApplyLabel), nameof(SelectionText) }) OnPropertyChanged(name);
    }
}
