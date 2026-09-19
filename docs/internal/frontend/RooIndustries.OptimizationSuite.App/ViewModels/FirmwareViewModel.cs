using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class FirmwareViewModel : ObservableObject
{
    public static string Root => Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "firmware");
    private string? _packageDirectory;
    private string? _sessionDirectory;
    private string? _reviewHash;
    private readonly List<FirmwareSettingRow> _all = new();
    [ObservableProperty] private string _board = "Reading motherboard details…";
    [ObservableProperty] private string _bios = "";
    [ObservableProperty] private string _packageText = "Choose the SCEWIN folder supplied for your motherboard.";
    [ObservableProperty] private string _message = "";
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _changedOnly;
    [ObservableProperty] private string _stage = "setup";
    [ObservableProperty] private string _resultStatus = "";
    [ObservableProperty] private int _changedCount;
    public ObservableCollection<FirmwareSettingRow> Settings { get; } = new();
    public ObservableCollection<FirmwareChange> Changes { get; } = new();
    public ObservableCollection<FirmwareHistoryRow> History { get; } = new();
    public bool IsSetup => Stage == "setup";
    public bool IsEditing => Stage == "edit";
    public bool IsReview => Stage == "review";
    public bool IsResult => Stage == "result";
    public bool CanLoad => !Busy && _packageDirectory is not null;
    public bool CanReview => !Busy && IsEditing && ChangedCount > 0;
    public bool CanApply => !Busy && IsReview && _reviewHash is not null;
    public bool CanRestart => !Busy && ResultStatus == "restartRequired";
    public bool CanVerify => !Busy && IsResult;
    public bool CanOpenFiles => !Busy && _sessionDirectory is not null;
    public string? SessionDirectory => _sessionDirectory;
    public string ResultHeadline => Busy ? "Checking BIOS settings…" : ResultStatus switch
    {
        "restartRequired" => "Changes saved. Restart when ready.",
        "applied" => "Settings verified after restart.",
        "needsAttention" => "The import needs attention.",
        "importing" => "The previous import was interrupted.",
        _ => "Verification could not finish."
    };
    public string ChangesSummary => ChangedCount + (ChangedCount == 1 ? " change" : " changes");
    public string StepText => Stage switch { "setup" => "1  Set up  ·  2  Edit  ·  3  Review  ·  4  Restart", "edit" => "2  Edit settings", "review" => "3  Review changes", _ => "4  Verify and restart" };
    public string HistoryHelp => History.Count == 0 ? "No saved sessions yet. Load settings to create the first export." : "Reopen a session to verify after restart or review an undo.";
    public string ApplyLabel => "Apply " + Changes.Count + (Changes.Count == 1 ? " change" : " changes");
    partial void OnBusyChanged(bool value) { RefreshActions(); OnPropertyChanged(nameof(ResultHeadline)); }
    partial void OnStageChanged(string value)
    {
        foreach (var name in new[] { nameof(IsSetup), nameof(IsEditing), nameof(IsReview), nameof(IsResult), nameof(StepText) }) OnPropertyChanged(name);
        RefreshActions();
    }
    partial void OnResultStatusChanged(string value) { RefreshActions(); OnPropertyChanged(nameof(ResultHeadline)); }
    partial void OnChangedCountChanged(int value) { OnPropertyChanged(nameof(ChangesSummary)); RefreshActions(); }
    partial void OnSearchChanged(string value) => Filter();
    partial void OnChangedOnlyChanged(bool value) => Filter();
    private void RefreshActions()
    {
        foreach (var name in new[] { nameof(CanLoad), nameof(CanReview), nameof(CanApply), nameof(CanRestart), nameof(CanVerify), nameof(CanOpenFiles), nameof(ApplyLabel) }) OnPropertyChanged(name);
    }
    private FirmwareWorkflow Workflow() => new(new ScewinProvider(_packageDirectory ?? throw new InvalidOperationException("Choose a SCEWIN package first.")), Path.Combine(Root, "sessions"));

    public async Task InitializeAsync() => await RunAsync(async () =>
    {
        var identity = await Task.Run(ScewinProvider.CurrentIdentity);
        Board = identity.Board;
        var stamp = Regex.Match(identity.Bios, @" (?<date>\d{4}-\d{2}-\d{2})T[^ ]+$");
        Bios = stamp.Success && DateTime.TryParse(stamp.Groups["date"].Value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var released)
            ? identity.Bios[..stamp.Index] + " · " + released.ToString("d MMM yyyy", CultureInfo.CurrentCulture) : identity.Bios;
        var config = Path.Combine(Root, "workspace.json");
        if (File.Exists(config))
        {
            var saved = OperationFiles.Read<FirmwareWorkspace>(config);
            _ = new ScewinProvider(saved.PackageDirectory).PackageFingerprint;
            var package = OperationFiles.Read<FirmwarePackage>(Path.Combine(saved.PackageDirectory, "package.json"));
            _packageDirectory = saved.PackageDirectory;
            PackageText = "SCEWIN " + package.Version + " · Ready to load settings";
            RefreshActions();
        }
        LoadHistory();
    });

    public async Task SetUpAsync(string directory, FirmwarePackage reviewed) => await RunAsync(async () =>
    {
        _packageDirectory = await Task.Run(() => ScewinProvider.SetUp(directory, reviewed, Path.Combine(Root, "packages")));
        OperationFiles.Write(Path.Combine(Root, "workspace.json"), new FirmwareWorkspace(_packageDirectory));
        PackageText = "SCEWIN " + reviewed.Version + " · Ready to load settings";
        Stage = "setup"; _sessionDirectory = null; _reviewHash = null;
        Message = "Package saved. Load settings to check compatibility and save the original export.";
        RefreshActions();
    });

    public async Task LoadAsync() => await RunAsync(async () =>
    {
        Message = "Reading BIOS settings and saving the original export…";
        var workflow = Workflow();
        _sessionDirectory = await Task.Run(workflow.Load);
        LoadEditor(workflow.Read(_sessionDirectory));
        Message = "Choose only the settings you want to change. The original export is saved.";
        LoadHistory();
    });
    private void LoadEditor(FirmwareScript script)
    {
        _reviewHash = null;
        foreach (var row in _all) row.PropertyChanged -= SettingChanged;
        _all.Clear();
        foreach (var question in script.Questions)
        {
            var row = new FirmwareSettingRow(question);
            row.PropertyChanged += SettingChanged;
            _all.Add(row);
        }
        ChangedCount = 0; Stage = "edit"; ResultStatus = ""; Search = ""; ChangedOnly = false; Filter();
    }
    private void SettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(FirmwareSettingRow.Selection)) return;
        _reviewHash = null;
        ChangedCount = _all.Count(r => r.Changed);
        if (ChangedOnly) Filter();
    }
    private void Filter()
    {
        Settings.Clear();
        foreach (var row in _all.Where(r => (!ChangedOnly || r.Changed) && (r.Name + " " + r.Help).Contains(Search.Trim(), StringComparison.OrdinalIgnoreCase))) Settings.Add(row);
    }

    public async Task ReviewAsync() => await RunAsync(async () =>
    {
        if (_sessionDirectory is null) return;
        var workflow = Workflow();
        var script = workflow.Read(_sessionDirectory);
        var selected = _all.Where(r => script.Validate(r.Question, r.Selection) != script.Validate(r.Question, r.Question.Current)).ToDictionary(r => r.Question.Id, r => r.Selection);
        _reviewHash = await Task.Run(() => workflow.Review(_sessionDirectory, selected));
        ShowReview();
    });
    private void ShowReview()
    {
        var review = OperationFiles.Read<FirmwareReview>(Path.Combine(_sessionDirectory!, "review.json"), _reviewHash);
        Changes.Clear(); foreach (var change in review.Changes) Changes.Add(change);
        Stage = "review";
        Message = "These settings will be written to this motherboard. Firmware settings can prevent startup; the saved export can be restored only while the PC can boot and SCEWIN still works.";
        RefreshActions();
    }
    public void EditAgain() { if (Busy) return; Stage = "edit"; _reviewHash = null; Message = "Adjust your selections, then review them again."; RefreshActions(); }
    public async Task ApplyAsync() => await RunAsync(async () =>
    {
        if (!IsReview || _sessionDirectory is null || _reviewHash is null) return;
        Message = "Applying the reviewed changes. Keep the app open until verification finishes.";
        var journal = await Task.Run(() => Workflow().Apply(_sessionDirectory, _reviewHash));
        ShowResult(journal); LoadHistory();
    });
    public async Task VerifyAsync() => await RunAsync(async () =>
    {
        if (_sessionDirectory is null) return;
        ResultStatus = "";
        Message = "Reading the current BIOS values…";
        ShowResult(await Task.Run(() => Workflow().Verify(_sessionDirectory))); LoadHistory();
    });
    public async Task UndoAsync() => await RunAsync(async () =>
    {
        if (_sessionDirectory is null) return;
        var workflow = Workflow();
        _sessionDirectory = await Task.Run(() => workflow.ReviewUndo(_sessionDirectory));
        LoadEditor(workflow.Read(_sessionDirectory));
        _reviewHash = OperationFiles.HashFile(Path.Combine(_sessionDirectory, "review.json"));
        // Load the inverse choices too, so going back to edit retains the proposed undo.
        var review = OperationFiles.Read<FirmwareReview>(Path.Combine(_sessionDirectory, "review.json"), _reviewHash);
        foreach (var change in review.Changes) _all.Single(r => r.Question.Id == change.Id).Selection = change.After;
        _reviewHash = OperationFiles.HashFile(Path.Combine(_sessionDirectory, "review.json"));
        ShowReview(); LoadHistory();
    });
    public async Task OpenHistoryAsync(FirmwareHistoryRow row) => await RunAsync(() =>
    {
        _sessionDirectory = row.Directory;
        var workflow = Workflow();
        var script = workflow.Read(_sessionDirectory);
        var journal = Path.Combine(_sessionDirectory, "journal.json");
        if (File.Exists(journal)) ShowResult(OperationFiles.Read<FirmwareJournal>(journal));
        else { LoadEditor(script); Message = "Loaded the saved export. Current settings will be checked again before import."; }
        return Task.CompletedTask;
    });
    private void ShowResult(FirmwareJournal journal)
    {
        ResultStatus = journal.Status;
        Message = journal.Status == "importing" ? "The previous import was interrupted. Verify current settings and inspect its log before making another change." : journal.Message;
        Stage = "result";
    }
    private void LoadHistory()
    {
        History.Clear();
        var sessions = Path.Combine(Root, "sessions");
        if (!Directory.Exists(sessions)) { OnPropertyChanged(nameof(HistoryHelp)); return; }
        foreach (var directory in Directory.GetDirectories(sessions).OrderByDescending(Directory.GetCreationTimeUtc))
        {
            var sessionFile = Path.Combine(directory, "session.json");
            if (!File.Exists(sessionFile)) continue;
            var session = OperationFiles.Read<FirmwareSession>(sessionFile);
            var journalFile = Path.Combine(directory, "journal.json");
            var journal = File.Exists(journalFile) ? OperationFiles.Read<FirmwareJournal>(journalFile) : null;
            var state = journal?.Status switch { "restartRequired" => "Restart pending", "applied" => "Verified after restart", "importing" => "Import interrupted", "needsAttention" => "Needs verification", _ => "Original export" };
            History.Add(new(directory, session.CreatedAt.ToLocalTime().ToString("g") + " · " + state));
        }
        OnPropertyChanged(nameof(HistoryHelp));
    }
    private async Task RunAsync(Func<Task> operation)
    {
        if (Busy) return;
        Busy = true;
        try { await operation(); }
        catch (Exception ex) { Message = ex.Message; }
        finally { Busy = false; }
    }
}
public sealed record FirmwareWorkspace(string PackageDirectory);
public sealed record FirmwareHistoryRow(string Directory, string Label);

public partial class FirmwareSettingRow : ObservableObject
{
    public FirmwareQuestion Question { get; }
    public string Name => Question.Name;
    public string Help => Question.Help;
    public string Current => Question.DisplayValue(Question.Current);
    public FirmwareOption[] Options => Question.Options;
    public FirmwareOption? SelectedOption
    {
        get => Options.FirstOrDefault(option => option.Value == Selection);
        set { if (IsChoice && value is not null) Selection = value.Value; }
    }
    partial void OnSelectionChanged(string value) => OnPropertyChanged(nameof(SelectedOption));
    public bool IsChoice => Question.Kind == "choice";
    public bool IsNumeric => !IsChoice;
    public string NumberHint => Question.Kind == "decimal" ? "Decimal" : "Hexadecimal";
    public bool Changed => !string.Equals(Selection?.Trim(), Question.Current, StringComparison.OrdinalIgnoreCase);
    [ObservableProperty] private string _selection;
    public FirmwareSettingRow(FirmwareQuestion question) { Question = question; _selection = question.Current; }
}
