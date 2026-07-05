using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    private const string PageName = "Process Controls";

    private const string CapCpuPriority = "process-controls.cpu-priority";
    private const string CapProBalance = "process-controls.probalance-restraint";
    private const string CapGpu = "process-controls.gpu-priority";
    private const string CapIo = "process-controls.io-priority";
    private const string CapAffinity = "process-controls.cpu-affinity";
    private const string CapRules = "process-controls.per-game-rules";
    private const string CapRestore = "process-controls.session-restore";

    private static readonly string[] CandidateCategories =
        { "browserWebView", "launcher", "vendorUtility", "backgroundApp" };

    [ObservableProperty] private string _headerStatus = "No active tuning — ready";
    [ObservableProperty] private string _headerStatusState = "neutral";
    [ObservableProperty] private string _foregroundTarget = "No game detected in the foreground yet.";
    [ObservableProperty] private string _lede =
        "Boost the game you're playing, ease background load, and keep capture and voice protected. Every change is previewed and one-click reversible.";

    [ObservableProperty] private bool _hasActiveSession;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(RestoreEnabled))] private bool _canRestore;
    [ObservableProperty] private string _sessionTitle = "No active session";
    [ObservableProperty] private string _sessionState = "neutral";
    [ObservableProperty] private string _sessionCaption =
        "Preview to see exactly what changes before anything is applied.";

    [ObservableProperty][NotifyPropertyChangedFor(nameof(RestoreEnabled))] private bool _actionBusy;
    [ObservableProperty] private string? _actionStatus;
    [ObservableProperty] private string _proBalanceCaption =
        "Background restraint eases heavy apps only while the game needs the CPU.";
    [ObservableProperty] private string _appRulesSummary = "No saved app rules yet.";
    [ObservableProperty] private int _processCount;
    [ObservableProperty] private int _protectedCount;
    [ObservableProperty] private int _restrainedCount;

    [ObservableProperty] private bool _isConfirmOpen;
    [ObservableProperty] private string _confirmKind = "apply";
    [ObservableProperty] private string _confirmTitle = string.Empty;
    [ObservableProperty] private string _confirmSubtitle = string.Empty;
    [ObservableProperty] private string _confirmProtected = string.Empty;
    [ObservableProperty] private string _confirmRestore = string.Empty;
    [ObservableProperty] private string _confirmTarget = string.Empty;
    [ObservableProperty] private string _confirmPrimaryLabel = "Apply changes";
    [ObservableProperty] private bool _confirmBusy;

    public bool RestoreEnabled => CanRestore && !ActionBusy;

    public ObservableCollection<TuningControl> TuningControls { get; } = new();
    public ObservableCollection<SessionDetail> SessionDetails { get; } = new();
    public ObservableCollection<ChangeRow> AppliedChanges { get; } = new();
    public ObservableCollection<CompanionRow> ProtectedCompanions { get; } = new();
    public ObservableCollection<AuditRow> History { get; } = new();
    public ObservableCollection<ChangeRow> ConfirmChanges { get; } = new();

    private IReadOnlyList<CapabilityRow> _capabilities = Array.Empty<CapabilityRow>();
    private string _targetGameName = "the foreground game";

    protected override async Task LoadCoreAsync()
    {
        var all = await App.Capabilities.GetCapabilitiesAsync();
        _capabilities = App.Capabilities.ForPage(PageName, all);

        var classification = await App.Live.GetProcessClassificationAsync()
            ?? await TryLoadSample(Data.GetProcessClassificationAsync);
        var preview = await App.Live.GetProcessProfilePreviewAsync()
            ?? await TryLoadSample(Data.GetProcessProfilePreviewAsync);
        var session = await App.Live.GetGameTuneSessionStatusAsync()
            ?? await TryLoadSample(Data.GetGameTuneSessionStatusAsync);
        var governor = await App.Live.GetProcessGovernorSessionStatusAsync()
            ?? await TryLoadSample(Data.GetProcessGovernorSessionStatusAsync);

        BuildForeground(classification, preview);
        BuildTuningControls(preview, governor);
        BuildProtectedCompanions(classification);
        BuildAppliedChanges(preview, classification);
        BuildSession(session, governor);
        BuildHistory(session, governor);
        BuildAppRules();

        IsEmpty = false;
    }

    private CapabilityRow? Capability(string id)
        => _capabilities.FirstOrDefault(c => string.Equals(c.CapabilityId, id, StringComparison.OrdinalIgnoreCase));

    private void BuildForeground(ProcessClassification? classification, ProcessProfileEnvelope? preview)
    {
        var game = classification?.Processes?.FirstOrDefault(p => p.Category == "foregroundGame" || p.Classification == "gameTarget");
        var name = game is not null ? Naming.FriendlyName(game.Name) : null;
        name ??= preview?.Preview?.FirstOrDefault(p => p.Classification == "gameTarget")?.DisplayName;

        if (!string.IsNullOrWhiteSpace(name))
        {
            _targetGameName = name!;
            ForegroundTarget = name + " is in the foreground.";
        }
        else
        {
            _targetGameName = "the foreground game";
            ForegroundTarget = "No game detected in the foreground yet.";
        }
    }

    private void BuildTuningControls(ProcessProfileEnvelope? preview, ProcessGovernorSessionStatus? governor)
    {
        TuningControls.Clear();

        var gameRow = preview?.Preview?.FirstOrDefault(p => p.Classification == "gameTarget" && p.ProposedAction == "setPriority");
        var priorityValue = gameRow is null
            ? "Ready"
            : FriendlyPriority(gameRow.ProposedPriorityClass);
        TuningControls.Add(MakeControl(
            CapCpuPriority,
            "Boost game priority",
            "More CPU headroom for the foreground game.",
            priorityValue,
            gameRow is null ? "Preview to see" : "Proposed"));

        var restraintActive = governor is { Active: true } || (governor?.Summary?.ActiveRestraintCount ?? 0) > 0;
        TuningControls.Add(MakeControl(
            CapProBalance,
            "Restrict background load",
            "ProBalance eases heavy background apps while the game runs.",
            restraintActive ? "On" : "Ready",
            restraintActive ? "Restraint on" : "Idle",
            restraintActive ? "safe" : null));

        TuningControls.Add(MakeControl(
            CapGpu,
            "GPU scheduling",
            "Prefer the game for GPU work.",
            null,
            "Game preference"));

        TuningControls.Add(MakeControl(
            CapIo,
            "I/O priority",
            "Hold back background disk activity.",
            null,
            "Background hold"));

        TuningControls.Add(MakeControl(
            CapAffinity,
            "CPU affinity",
            "Reserve cores for the game.",
            "All cores",
            "Core layout"));
    }

    private TuningControl MakeControl(string capabilityId, string title, string description,
        string? valueOverride, string caption, string? stateOverride = null)
    {
        var cap = Capability(capabilityId);
        var available = cap?.MachineAvailable ?? true;

        string value;
        string state;
        string availability;

        if (cap is not null && !available)
        {
            value = "Not on this PC";
            state = "neutral";
            availability = string.IsNullOrWhiteSpace(cap.ReasonOrNextStep) ? "Unavailable here" : cap.ReasonOrNextStep;
        }
        else
        {
            value = valueOverride ?? "Ready";
            state = stateOverride ?? (valueOverride is null ? "low" : "low");
            availability = caption;
        }

        return new TuningControl(title, description, value, state, availability, available && cap is not null);
    }

    private void BuildProtectedCompanions(ProcessClassification? classification)
    {
        ProtectedCompanions.Clear();
        var protectedProcesses = (classification?.Processes ?? new List<ProcessItem>())
            .Where(p => p.Protected || p.Protection == "protected"
                || p.Classification is "protected" or "protectedCompanion")
            .Where(p => !Naming.IsNonActionable(p.Name))
            .GroupBy(p => Naming.FriendlyName(p.Name))
            .Select(g => g.First())
            .Take(6)
            .ToList();

        foreach (var p in protectedProcesses)
        {
            ProtectedCompanions.Add(new CompanionRow(DisplayName(p), CompanionRole(p)));
        }

        if (ProtectedCompanions.Count == 0)
        {
            ProtectedCompanions.Add(new CompanionRow("OBS Studio", "Capture"));
            ProtectedCompanions.Add(new CompanionRow("Discord", "Voice"));
        }
    }

    private void BuildAppliedChanges(ProcessProfileEnvelope? preview, ProcessClassification? classification)
    {
        AppliedChanges.Clear();
        var rows = preview?.Preview ?? new List<ProcessPreviewRow>();

        foreach (var row in rows.Where(r => !r.Blocked).Take(8))
        {
            var (chip, state) = ChipFor(row);
            var before = FriendlyPriority(row.CurrentPriorityClass);
            var after = row.Protected
                ? "Untouched"
                : row.ProposedAction == "noChange" || row.CurrentPriorityClass == row.ProposedPriorityClass
                    ? before
                    : FriendlyPriority(row.ProposedPriorityClass);

            AppliedChanges.Add(new ChangeRow(
                string.IsNullOrWhiteSpace(row.DisplayName) ? Naming.FriendlyName(row.ProcessName) : row.DisplayName!,
                RoleFor(row),
                row.Protected ? "—" : before,
                after,
                chip,
                state));
        }

        ProcessCount = classification?.Processes?.Count ?? rows.Count;
        ProtectedCount = rows.Count(r => r.Protected);
        RestrainedCount = rows.Count(r => r.Classification == "demotionCandidate" && !r.Protected);
    }

    private void BuildSession(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor)
    {
        SessionDetails.Clear();

        var restorable = session is { Restorable: true } && session.SessionStatus is "restorable" or "active";
        var active = session is { Active: true } || governor is { Active: true };
        HasActiveSession = active || restorable;
        CanRestore = restorable || (governor is { Restorable: true });

        if (!HasActiveSession)
        {
            SessionTitle = "No active session";
            SessionState = "neutral";
            SessionCaption = "Preview to see exactly what changes before anything is applied.";
            HeaderStatus = "No active tuning — ready";
            HeaderStatusState = "neutral";
            return;
        }

        SessionTitle = "Game priority boost";
        SessionState = active ? "safe" : "low";
        var changed = session?.Summary?.ChangedItemCount ?? session?.ChangedItems?.Count ?? 0;
        var restraints = governor?.Summary?.ActiveRestraintCount ?? governor?.ActiveRestraints?.Count ?? 0;

        SessionDetails.Add(new SessionDetail("Target", _targetGameName, "primary"));
        SessionDetails.Add(new SessionDetail("Applied", DescribeApplied(session, governor), "secondary"));
        if (restraints > 0)
        {
            SessionDetails.Add(new SessionDetail("ProBalance", "On · " + restraints + Plural(restraints, " app", " apps") + " eased", "warning"));
        }
        SessionDetails.Add(new SessionDetail("Protected", DescribeProtectedShort(), "info"));
        SessionDetails.Add(new SessionDetail("Restore", CanRestore ? "One click · fully reversible" : "Nothing to restore yet", CanRestore ? "success" : "neutral"));

        SessionCaption = "Auto-restores when " + _targetGameName + " closes.";
        HeaderStatus = active
            ? "Session active — game priority boost on " + _targetGameName
            : "Restorable session — game priority boost on " + _targetGameName;
        HeaderStatusState = active ? "safe" : "low";
        _ = changed;
    }

    private void BuildHistory(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor)
    {
        History.Clear();
        var appliedTime = FormatTime(session?.ChangedItems is { Count: > 0 } ? null : null);

        foreach (var item in session?.ChangedItems ?? new List<SessionChangedItem>())
        {
            History.Add(new AuditRow(
                appliedTime,
                "Applied",
                "low",
                DisplayNameOf(item),
                "CPU  " + FriendlyPriority(item.OriginalPriorityClass) + " → " + FriendlyPriority(item.AppliedPriorityClass),
                "Reversible",
                "low"));
        }

        foreach (var item in session?.RestoredItems ?? new List<SessionChangedItem>())
        {
            History.Add(new AuditRow(
                appliedTime,
                "Restored",
                "safe",
                DisplayNameOf(item),
                "CPU  " + FriendlyPriority(item.AppliedPriorityClass) + " → " + FriendlyPriority(item.RestoredPriorityClass),
                "Done",
                "safe"));
        }

        var restraints = governor?.ActiveRestraints ?? new List<ActiveRestraint>();
        if (restraints.Count > 0)
        {
            History.Add(new AuditRow(
                appliedTime,
                "Restrained",
                "medium",
                "Background · " + restraints.Count + Plural(restraints.Count, " app", " apps"),
                "ProBalance eased",
                "Reversible",
                "low"));
        }

        if (History.Count == 0)
        {
            History.Add(new AuditRow("—", "Ready", "neutral", "No tuning applied yet",
                "History appears after you apply your first change", "—", "neutral"));
        }
    }

    private void BuildAppRules()
    {
        var cap = Capability(CapRules);
        AppRulesSummary = cap is { MachineAvailable: true }
            ? "Saved rules apply automatically when a matching game is in the foreground: boost the game, ease launchers and helpers, and keep capture and voice protected."
            : "Save what you tune here as a rule so it applies automatically next time this game is in front.";
    }

    // ---- commands ----

    [RelayCommand]
    private async Task RefreshAsync() => await ReloadAsync();

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (ActionBusy)
        {
            return;
        }

        ActionBusy = true;
        ActionStatus = "Reading what would change…";
        try
        {
            var response = await App.Capabilities.PreviewAsync(CapCpuPriority);
            ActionStatus = response is null
                ? "Preview uses the last local snapshot. Connect the local engine for a live preview."
                : "Preview ready — review the changes below, then apply when you're set.";
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ActionStatus = "Couldn't preview: " + ex.Message;
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private void OpenApplyConfirm()
    {
        ConfirmKind = "apply";
        ConfirmTitle = "Apply game priority boost?";
        ConfirmSubtitle = "Nothing is applied until you confirm — every change is one-click reversible.";
        ConfirmPrimaryLabel = "Apply changes";
        ConfirmChanges.Clear();
        foreach (var change in AppliedChanges.Where(c => c.After != "Untouched").Take(6))
        {
            ConfirmChanges.Add(change);
        }

        if (ConfirmChanges.Count == 0)
        {
            ConfirmChanges.Add(new ChangeRow(_targetGameName, "Foreground game", "Normal", "High", "Boost", "low"));
        }

        ConfirmProtected = DescribeProtected() + " stay untouched — protected capture and voice are never boosted, restrained, or demoted.";
        ConfirmRestore = "One click · auto-restores when the game closes.";
        ConfirmTarget = _targetGameName + " (foreground)";
        IsConfirmOpen = true;
    }

    [RelayCommand]
    private void OpenRestoreConfirm()
    {
        ConfirmKind = "restore";
        ConfirmTitle = "Restore changes?";
        ConfirmSubtitle = "Every process returns to the exact value it had before tuning.";
        ConfirmPrimaryLabel = "Restore changes";
        ConfirmChanges.Clear();
        foreach (var item in History.Where(h => h.Action == "Applied").Take(6))
        {
            ConfirmChanges.Add(new ChangeRow(item.Target, "Restore to original", item.Change, "Original", "Restore", "safe"));
        }

        if (ConfirmChanges.Count == 0)
        {
            ConfirmChanges.Add(new ChangeRow(_targetGameName, "Restore to original", "High", "Normal", "Restore", "safe"));
        }

        ConfirmProtected = DescribeProtected() + " were never changed, so nothing there is affected.";
        ConfirmRestore = "Returns every changed process to its recorded original value.";
        ConfirmTarget = _targetGameName + " session";
        IsConfirmOpen = true;
    }

    [RelayCommand]
    private void CancelConfirm() => IsConfirmOpen = false;

    [RelayCommand]
    private async Task ConfirmPrimaryAsync()
    {
        if (ConfirmBusy)
        {
            return;
        }

        var isRestore = ConfirmKind == "restore";
        ConfirmBusy = true;
        ActionBusy = true;
        try
        {
            var response = isRestore
                ? await App.Capabilities.RestoreAsync(CapRestore)
                : await App.Capabilities.ApplyAsync(CapCpuPriority);

            ActionStatus = DescribeActionResult(response, isRestore);
            IsConfirmOpen = false;
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ActionStatus = (isRestore ? "Couldn't restore: " : "Couldn't apply: ") + ex.Message;
        }
        finally
        {
            ConfirmBusy = false;
            ActionBusy = false;
        }
    }

    private static string DescribeActionResult(CapabilityRouterResponse? response, bool isRestore)
    {
        if (response is null)
        {
            return isRestore
                ? "Restore is ready. Connect the local engine to run it on this PC."
                : "Reviewed only — connect the local engine to apply changes on this PC.";
        }

        if (response.Errors is { Count: > 0 })
        {
            var first = response.Errors.FirstOrDefault(e => !string.IsNullOrWhiteSpace(e.Message));
            return (isRestore ? "Restore didn't complete: " : "Apply didn't complete: ")
                + (first?.Message ?? "see engine status");
        }

        if (response.RequiresApproval && !response.ApprovalSatisfied)
        {
            return "Needs your go-ahead in the local engine before it can change anything.";
        }

        if (response.Changed)
        {
            return isRestore ? "Restored — every process is back to its original value." : "Applied — the game priority boost is live and one-click reversible.";
        }

        return isRestore
            ? "Nothing needed restoring; values were already original."
            : "Reviewed — no changes were needed on this PC right now.";
    }

    // ---- helpers ----

    private string DescribeApplied(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor)
    {
        var parts = new List<string>();
        var boosted = session?.ChangedItems?.FirstOrDefault(i => !string.IsNullOrWhiteSpace(i.AppliedPriorityClass));
        parts.Add(boosted is null ? "CPU boost" : "CPU " + FriendlyPriority(boosted.AppliedPriorityClass));
        var supported = governor?.RuntimeEvidence?.SupportedControls;
        if (supported is not null)
        {
            if (supported.Any(s => s.Contains("io", StringComparison.OrdinalIgnoreCase))) parts.Add("I/O");
            if (supported.Any(s => s.Contains("gpu", StringComparison.OrdinalIgnoreCase))) parts.Add("GPU");
        }
        return string.Join(" · ", parts);
    }

    private string DescribeProtected()
    {
        var names = ProtectedCompanions.Select(c => c.Name).Take(3).ToList();
        return names.Count == 0 ? "Capture and voice apps" : string.Join(", ", names);
    }

    private string DescribeProtectedShort()
    {
        var names = ProtectedCompanions.Select(c => c.Name).ToList();
        if (names.Count == 0) return "Capture and voice apps";
        if (names.Count <= 2) return string.Join(", ", names);
        return names[0] + ", " + names[1] + " +" + (names.Count - 2);
    }

    private static (string chip, string state) ChipFor(ProcessPreviewRow row)
    {
        if (row.Protected)
        {
            return ("Protected", "protected");
        }

        if (row.Classification == "gameTarget")
        {
            return ("Boosted", "low");
        }

        if (row.Classification == "demotionCandidate")
        {
            return ("Restrained", "medium");
        }

        return ("Unchanged", "neutral");
    }

    private static string RoleFor(ProcessPreviewRow row) => row.Classification switch
    {
        "gameTarget" => "Foreground game",
        "protectedCompanion" => "Protected companion",
        "demotionCandidate" => "Background load",
        _ => string.IsNullOrWhiteSpace(row.Reason) ? "Process" : row.Reason!,
    };

    private static string CompanionRole(ProcessItem p)
    {
        var name = (p.Name ?? string.Empty).ToLowerInvariant();
        if (name.Contains("obs")) return "Capture";
        if (name.Contains("discord")) return "Voice";
        return Naming.CategoryLabel(p.Category);
    }

    private static string DisplayName(ProcessItem process)
        => string.IsNullOrWhiteSpace(process.DisplayName) ? Naming.FriendlyName(process.Name) : process.DisplayName!;

    private static string DisplayNameOf(SessionChangedItem item)
        => string.IsNullOrWhiteSpace(item.DisplayName) ? Naming.FriendlyName(item.ProcessName) : item.DisplayName!;

    private static string FormatTime(string? _) => "Recent";

    private static string Plural(int count, string one, string many) => count == 1 ? one : many;

    private static string FriendlyPriority(string? priorityClass) => priorityClass switch
    {
        "AboveNormal" => "Above",
        "BelowNormal" => "Below",
        "RealTime" => "Realtime",
        "High" => "High",
        "Idle" => "Idle",
        null or "" => "Normal",
        _ => priorityClass!,
    };

    private static async Task<T?> TryLoadSample<T>(Func<Task<T>> load) where T : class
    {
        try
        {
            return await load();
        }
        catch
        {
            return null;
        }
    }
}

public sealed record TuningControl(
    string Title,
    string Description,
    string ValueText,
    string ValueState,
    string AvailabilityText,
    bool IsAvailable);

public sealed record SessionDetail(string Key, string Value, string ValueState);

public sealed record ChangeRow(
    string Name,
    string Role,
    string Before,
    string After,
    string ChipText,
    string ChipState);

public sealed record CompanionRow(string Name, string Role);

public sealed record AuditRow(
    string Time,
    string Action,
    string ActionState,
    string Target,
    string Change,
    string RestoreText,
    string RestoreState);
