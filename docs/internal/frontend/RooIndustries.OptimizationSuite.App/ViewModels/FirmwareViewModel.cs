using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading;
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
    private CancellationTokenSource? _setupCancellation;
    private readonly List<FirmwareSettingRow> _all = new();
    private readonly Dictionary<string, FirmwareVerificationMatch> _verificationMatches = new();
    [ObservableProperty] private string _board = "Reading motherboard details…";
    [ObservableProperty] private string _bios = "";
    [ObservableProperty] private string _packageText = "First use downloads about 560 MB. Later visits use the saved SCEWIN package.";
    [ObservableProperty] private string _message = "";
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _changedOnly;
    [ObservableProperty] private string _stage = "setup";
    [ObservableProperty] private string _resultStatus = "";
    [ObservableProperty] private int _changedCount;
    public ObservableCollection<FirmwareSettingRow> Settings { get; } = new();
    public ObservableCollection<FirmwareSettingRow> TestedUnchangedSettings { get; } = new();
    public ObservableCollection<FirmwareChange> Changes { get; } = new();
    public ObservableCollection<FirmwareHistoryRow> History { get; } = new();
    public bool IsSetup => Stage == "setup";
    public bool IsEditing => Stage == "edit";
    public bool IsReview => Stage == "review";
    public bool IsResult => Stage == "result";
    public bool CanLoad => !Busy;
    public bool CanCancelSetup => _setupCancellation is not null;
    public string LoadLabel => _packageDirectory is null ? "Set up and load settings" : "Load settings";
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
    public bool HasTestedUnchangedSettings => TestedUnchangedSettings.Count > 0;
    public string TestedUnchangedSummary => "Did not change (" + TestedUnchangedSettings.Count + (TestedUnchangedSettings.Count == 1 ? " setting)" : " settings)");
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
        foreach (var name in new[] { nameof(CanLoad), nameof(CanCancelSetup), nameof(LoadLabel), nameof(CanReview), nameof(CanApply), nameof(CanRestart), nameof(CanVerify), nameof(CanOpenFiles), nameof(ApplyLabel) }) OnPropertyChanged(name);
    }
    private FirmwareWorkflow Workflow() => new(new ScewinProvider(_packageDirectory ?? throw new InvalidOperationException("Load settings to set up SCEWIN first.")), Path.Combine(Root, "sessions"));

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
            PackageText = PackageStatus(package);
            RefreshActions();
        }
        LoadHistory();
    });

    public async Task SetUpAsync(string directory, FirmwarePackage reviewed) => await RunAsync(async () =>
    {
        _packageDirectory = await Task.Run(() => ScewinProvider.SetUp(directory, reviewed, Path.Combine(Root, "packages")));
        OperationFiles.Write(Path.Combine(Root, "workspace.json"), new FirmwareWorkspace(_packageDirectory));
        PackageText = PackageStatus(reviewed);
        Stage = "setup"; _sessionDirectory = null; _reviewHash = null;
        Message = "Package saved. Load settings to check compatibility and save the original export.";
        RefreshActions();
    });

    public async Task LoadAsync() => await RunAsync(async () =>
    {
        if (_packageDirectory is null)
        {
            _setupCancellation = new CancellationTokenSource();
            RefreshActions();
            try
            {
                var setupCancellation = _setupCancellation;
                var progress = new Progress<string>(status => { if (_setupCancellation == setupCancellation) Message = status; });
                var directory = await new ScewinSetup().InstallAsync(Path.Combine(Root, "packages"), progress, _setupCancellation.Token);
                OperationFiles.Write(Path.Combine(Root, "workspace.json"), new FirmwareWorkspace(directory));
                _packageDirectory = directory;
                var package = OperationFiles.Read<FirmwarePackage>(Path.Combine(directory, "package.json"));
                PackageText = PackageStatus(package);
                _setupCancellation.Token.ThrowIfCancellationRequested();
            }
            finally
            {
                _setupCancellation.Dispose();
                _setupCancellation = null;
                RefreshActions();
            }
        }
        Message = "Reading BIOS settings and saving the original export…";
        var workflow = Workflow();
        _sessionDirectory = await Task.Run(workflow.Load);
        await LoadEditorAsync(workflow.Read(_sessionDirectory));
        Message = "Choose only the settings you want to change. The original export is saved.";
        LoadHistory();
    });
    public void CancelSetup() => _setupCancellation?.Cancel();
    private static string PackageStatus(FirmwarePackage package) => (package.Version == "Not specified" ? "SCEWIN" : "SCEWIN " + package.Version) + " · Ready to load settings";
    private async Task LoadEditorAsync(FirmwareScript script)
    {
        _reviewHash = null;
        foreach (var row in _all) row.PropertyChanged -= SettingChanged;
        _all.Clear();
        _verificationMatches.Clear();
        foreach (var question in script.Questions)
        {
            var row = new FirmwareSettingRow(question);
            row.PropertyChanged += SettingChanged;
            _all.Add(row);
        }
        ChangedCount = 0; Stage = "edit"; ResultStatus = ""; Search = ""; ChangedOnly = false; Filter();
        await LoadVerificationAsync(script, _sessionDirectory);
    }
    private void SettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(FirmwareSettingRow.Selection)) return;
        _reviewHash = null;
        ChangedCount = _all.Count(r => r.Changed);
        foreach (var row in _all)
        {
            if (row.Changed)
                row.SetVerification("Not tested", "This selected value has not been tested.", false);
            else if (_verificationMatches.TryGetValue(row.Question.Id, out var match))
                ApplyVerification(row, match);
        }
        Filter();
    }
    private void Filter()
    {
        Settings.Clear();
        TestedUnchangedSettings.Clear();
        foreach (var row in _all.Where(row => MatchesFilter(row, Search, ChangedOnly)))
        {
            if (ShouldCollapse(row)) TestedUnchangedSettings.Add(row);
            else Settings.Add(row);
        }
        OnPropertyChanged(nameof(HasTestedUnchangedSettings));
        OnPropertyChanged(nameof(TestedUnchangedSummary));
    }
    public static bool MatchesFilter(FirmwareSettingRow row, string search, bool changedOnly)
        => (!changedOnly || row.Changed) && (row.Name + " " + row.Help).Contains(search.Trim(), StringComparison.OrdinalIgnoreCase);
    public static bool ShouldCollapse(FirmwareSettingRow row) => row.IsTestedUnchanged && !row.Changed;

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
        await LoadEditorAsync(workflow.Read(_sessionDirectory));
        _reviewHash = OperationFiles.HashFile(Path.Combine(_sessionDirectory, "review.json"));
        var review = OperationFiles.Read<FirmwareReview>(Path.Combine(_sessionDirectory, "review.json"), _reviewHash);
        foreach (var change in review.Changes) _all.Single(r => r.Question.Id == change.Id).Selection = change.After;
        _reviewHash = OperationFiles.HashFile(Path.Combine(_sessionDirectory, "review.json"));
        ShowReview(); LoadHistory();
    });
    public async Task OpenHistoryAsync(FirmwareHistoryRow row) => await RunAsync(async () =>
    {
        _sessionDirectory = row.Directory;
        var workflow = Workflow();
        var script = workflow.Read(_sessionDirectory);
        var journal = Path.Combine(_sessionDirectory, "journal.json");
        if (File.Exists(journal)) ShowResult(OperationFiles.Read<FirmwareJournal>(journal));
        else { await LoadEditorAsync(script); Message = "Loaded the saved export. Current settings will be checked again before import."; }
    });
    private void ShowResult(FirmwareJournal journal)
    {
        ResultStatus = journal.Status;
        Message = journal.Status == "importing" ? "The previous import was interrupted. Verify current settings and inspect its log before making another change." : journal.Message;
        Stage = "result";
    }
    public async Task OpenSettingsAsync() => await RunAsync(async () =>
    {
        if (_sessionDirectory is null) return;
        await LoadEditorAsync(Workflow().Read(_sessionDirectory));
        Message = "Choose only the settings you want to change. Tested settings that did not change are retained in the collapsed menu.";
    });
    private async Task LoadVerificationAsync(FirmwareScript script, string? sessionDirectory)
    {
        if (sessionDirectory is null || _packageDirectory is null) return;
        var verificationRoot = Path.Combine(Root, "verification");
        if (!Directory.Exists(verificationRoot)) return;
        var packageDirectory = _packageDirectory;
        IReadOnlyList<FirmwareVerificationMatch> matching;
        try
        {
            matching = await Task.Run(async () =>
            {
                var session = OperationFiles.Read<FirmwareSession>(Path.Combine(sessionDirectory, "session.json"));
                var originalPath = Path.Combine(sessionDirectory, "original.txt");
                if (OperationFiles.HashFile(originalPath) != session.BackupHash) return Array.Empty<FirmwareVerificationMatch>();
                var currentIdentity = ScewinProvider.CurrentIdentity();
                var packageFingerprint = new ScewinProvider(packageDirectory).PackageFingerprint;
                return await new FirmwareVerificationStore(verificationRoot).ReadMatchingTrialsAsync(currentIdentity, packageFingerprint, originalPath);
            });
        }
        catch { matching = Array.Empty<FirmwareVerificationMatch>(); }
        _verificationMatches.Clear();
        foreach (var match in matching)
        {
            var trial = match.Trial;
            var binding = trial.Binding;
            var question = script.Questions.SingleOrDefault(item => item.Id == binding.QuestionId);
            if (question is null || trial.BaselineValue == trial.TestValue || script.Validate(question, question.Current) != trial.BaselineValue) continue;
            _verificationMatches[question.Id] = match;
        }
        foreach (var row in _all)
        {
            if (!row.Changed && _verificationMatches.TryGetValue(row.Question.Id, out var match))
                ApplyVerification(row, match);
            else if (row.Changed)
                row.SetVerification("Not tested", "This selected value has not been tested.", false);
        }
        Filter();
    }
    private static void ApplyVerification(FirmwareSettingRow row, FirmwareVerificationMatch match)
    {
        var description = DescribeVerification(match, row.Question);
        row.SetVerification(description.Status, description.Reason, description.CanCollapse && !row.Changed);
    }
    public static FirmwareVerificationPresentation DescribeVerification(FirmwareVerificationMatch match, FirmwareQuestion question)
    {
        if (!match.Matches) return new("Not tested", MatchReason(match.CurrentStatus), false);
        var trial = match.Trial;
        var value = question.DisplayValue(trial.TestValue);
        var behavior = trial.Evidence.LastOrDefault(e => e.Phase == FirmwareEvidencePhases.Behavior);
        return trial.Status switch
        {
            FirmwareTrialStatuses.ValueStored => new("Value saved", "Tested " + value + "; the value was read back before restart. The effect is untested.", false),
            FirmwareTrialStatuses.PersistedAfterRestart => new("Restart checked", "Tested " + value + "; the value remained after restart. The effect is untested.", false),
            FirmwareTrialStatuses.ActualBehaviorVerified when trial.ConfirmedUnchanged => new("Did not change", "Tested " + value + "; no behavior change was observed and the original value was restored.", true),
            FirmwareTrialStatuses.ActualBehaviorVerified when trial.EffectVerified => new("Effect verified", "Tested " + value + ". " + (string.IsNullOrWhiteSpace(behavior?.Output) ? "The observed effect was recorded." : behavior.Output), false),
            FirmwareTrialStatuses.ActualBehaviorVerified => new("Not tested", "The behavior evidence was incomplete or inconclusive.", false),
            FirmwareTrialStatuses.UnchangedImmediately => new("Not tested", "Tested " + value + "; the value did not change before restart, so testing is incomplete.", false),
            FirmwareTrialStatuses.WriteRejected => new("Not tested", "The write for tested value " + value + " was rejected.", false),
            FirmwareTrialStatuses.Inconclusive => new("Not tested", "The test for value " + value + " was inconclusive.", false),
            _ => new("Not tested", "This setting has not been tested.", false)
        };
    }
    private static string MatchReason(string status) => status switch
    {
        FirmwareVerificationMatchStatuses.DifferentMachine => "This test belongs to a different PC.",
        FirmwareVerificationMatchStatuses.DifferentBoard => "This test belongs to a different motherboard.",
        FirmwareVerificationMatchStatuses.DifferentBios => "This test belongs to a different BIOS.",
        FirmwareVerificationMatchStatuses.DifferentPackage => "This test belongs to a different SCEWIN package.",
        FirmwareVerificationMatchStatuses.DifferentProfile => "The current BIOS settings profile differs from the tested baseline.",
        _ => "The current BIOS context could not be matched to this test."
    };
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
        catch (OperationCanceledException) { Message = "Setup cancelled. Load settings when you are ready to try again."; }
        catch (Exception ex) { Message = ex.Message; }
        finally { Busy = false; }
    }
}
public sealed record FirmwareWorkspace(string PackageDirectory);
public sealed record FirmwareHistoryRow(string Directory, string Label);
public sealed record FirmwareVerificationPresentation(string Status, string Reason, bool CanCollapse);

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
    [ObservableProperty] private string _verificationStatus = "Not tested";
    [ObservableProperty] private string _verificationReason = "This setting has not been tested.";
    [ObservableProperty] private bool _isTestedUnchanged;
    [ObservableProperty] private string _selection;
    public FirmwareSettingRow(FirmwareQuestion question) { Question = question; _selection = question.Current; }
    public void SetVerification(string status, string reason, bool testedUnchanged)
    {
        VerificationStatus = status;
        VerificationReason = reason;
        IsTestedUnchanged = testedUnchanged;
    }
}
