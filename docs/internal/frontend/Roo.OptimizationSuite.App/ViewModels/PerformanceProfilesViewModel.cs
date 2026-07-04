using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    private const string PageName = "Process Controls";

    [ObservableProperty] private string _foregroundStatus = "No foreground target";
    [ObservableProperty] private string _foregroundStatusLevel = "neutral";
    [ObservableProperty] private string _ruleSummary =
        "Priority, affinity, restraint, and restore readiness are shown from the capability registry. Changes require the routed approval path.";
    [ObservableProperty] private int _capabilityCount;
    [ObservableProperty] private int _availableCapabilityCount;
    [ObservableProperty] private int _approvalCapabilityCount;
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _candidateCount;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _sessionSummary = "No active process-control session is recorded.";
    [ObservableProperty] private string? _processContextMessage;
    [ObservableProperty] private string? _governorCaption;

    [ObservableProperty][NotifyPropertyChangedFor(nameof(HasSelectedCapability))]
    private ProcessCapabilityItem? _selectedCapability;

    [ObservableProperty] private bool _explainBusy;
    [ObservableProperty] private string _selectedCapabilityLabel = "Select a capability";
    [ObservableProperty] private string _selectedCapabilityFamily = string.Empty;
    [ObservableProperty] private string _selectedCapabilityAvailability = string.Empty;
    [ObservableProperty] private string _selectedCapabilityApply = string.Empty;
    [ObservableProperty] private string _selectedCapabilityApproval = string.Empty;
    [ObservableProperty] private string _selectedCapabilityRestore = string.Empty;
    [ObservableProperty] private string _selectedCapabilityReason = string.Empty;
    [ObservableProperty] private string _selectedCapabilityNextStep = "Select a capability to read its explain details.";
    [ObservableProperty] private string _selectedCapabilityStatus = string.Empty;
    [ObservableProperty] private string _selectedCapabilityDotState = "neutral";
    [ObservableProperty] private string? _selectedCapabilityErrors;

    private readonly List<GameAppRow> _all = new();
    private int _explainRequestId;

    public ObservableCollection<ProcessCapabilityItem> Capabilities { get; } = new();
    public ObservableCollection<ProcessCapabilityGateLine> SelectedGateRows { get; } = new();
    public ObservableCollection<GameAppRow> Rows { get; } = new();
    public ObservableCollection<GameAppRow> ForegroundRows { get; } = new();
    public ObservableCollection<GameAppRow> ProtectedRows { get; } = new();
    public ObservableCollection<GameAppRow> CandidateRows { get; } = new();

    public bool HasSelectedCapability => SelectedCapability is not null;

    private static readonly string[] CandidateCategories = { "browserWebView", "launcher", "vendorUtility", "backgroundApp" };

    protected override async Task LoadCoreAsync()
    {
        await LoadCapabilitiesAsync();
        await LoadProcessContextAsync();
        IsEmpty = Capabilities.Count == 0;
    }

    public async Task SelectCapabilityAsync(ProcessCapabilityItem? item)
    {
        if (item is null)
        {
            return;
        }

        var requestId = ++_explainRequestId;
        SelectedCapability = item;
        ApplyRegistryDetail(item.Row);
        ExplainBusy = true;
        SelectedCapabilityErrors = null;

        try
        {
            var response = await App.Capabilities.ExplainAsync(item.Row.CapabilityId);
            if (requestId != _explainRequestId)
            {
                return;
            }

            ApplyExplainDetail(item.Row, response);
        }
        catch (Exception ex)
        {
            if (requestId == _explainRequestId)
            {
                SelectedCapabilityErrors = ex.Message;
                SelectedCapabilityStatus = "Explain failed";
            }
        }
        finally
        {
            if (requestId == _explainRequestId)
            {
                ExplainBusy = false;
            }
        }
    }

    private async Task LoadCapabilitiesAsync()
    {
        var all = await App.Capabilities.GetCapabilitiesAsync();
        var rows = App.Capabilities.ForPage(PageName, all);

        Capabilities.Clear();
        foreach (var row in rows)
        {
            Capabilities.Add(new ProcessCapabilityItem(row));
        }

        CapabilityCount = rows.Count;
        AvailableCapabilityCount = rows.Count(row => row.MachineAvailable);
        ApprovalCapabilityCount = rows.Count(row => row.ApprovalText.Contains("go-ahead", StringComparison.OrdinalIgnoreCase));
    }

    private async Task LoadProcessContextAsync()
    {
        var classification = await App.Live.GetProcessClassificationAsync()
            ?? await TryLoadSample(Data.GetProcessClassificationAsync);
        var preview = await App.Live.GetProcessProfilePreviewAsync()
            ?? await TryLoadSample(Data.GetProcessProfilePreviewAsync);
        var session = await App.Live.GetGameTuneSessionStatusAsync()
            ?? await TryLoadSample(Data.GetGameTuneSessionStatusAsync);
        var restorePreview = await TryLoadSample(Data.GetGameTuneRestorePreviewAsync);
        var governor = await App.Live.GetProcessGovernorSessionStatusAsync()
            ?? await TryLoadSample(Data.GetProcessGovernorSessionStatusAsync);
        var processes = classification?.Processes;

        _all.Clear();
        Rows.Clear();
        ForegroundRows.Clear();
        ProtectedRows.Clear();
        CandidateRows.Clear();

        if (processes is null || processes.Count == 0)
        {
            ForegroundStatus = "Process inventory unavailable";
            ForegroundStatusLevel = "neutral";
            ProcessContextMessage = "Process inventory was not returned. Capability status is still available from the registry.";
            BuildSessionState(session, restorePreview);
            BuildGovernorCaption(governor);
            return;
        }

        ProcessContextMessage = null;
        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        if (game is not null)
        {
            ForegroundStatus = Naming.FriendlyName(game.Name) + " detected";
            ForegroundStatusLevel = "safe";
        }
        else
        {
            ForegroundStatus = "No foreground target";
            ForegroundStatusLevel = "neutral";
        }

        var previewByProcess = (preview?.Preview ?? new List<ProcessPreviewRow>())
            .GroupBy(p => (p.ProcessName ?? string.Empty).ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.First());

        foreach (var p in processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes))
        {
            var previewRow = previewByProcess.TryGetValue((p.Name ?? string.Empty).ToLowerInvariant(), out var row) ? row : null;
            var (plan, state) = PlanFor(p);
            _all.Add(new GameAppRow(
                DisplayName(p),
                Naming.CategoryLabel(p.Category),
                PriorityText(p.PriorityClass, previewRow?.ProposedPriorityClass),
                p.CpuPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%",
                Format.Bytes(p.WorkingSetBytes),
                plan,
                state));
        }

        AppsCount = _all.Count;
        KeepCount = _all.Count(r => r.Plan == "Protected");
        CandidateCount = _all.Count(r => r.Plan == "Candidate");

        BuildSessionState(session, restorePreview);
        BuildGovernorCaption(governor);
        ApplyFilter();
    }

    private void ApplyRegistryDetail(CapabilityRow row)
    {
        SelectedCapabilityLabel = row.Label;
        SelectedCapabilityFamily = ProcessCapabilityText.FamilyText(row);
        SelectedCapabilityAvailability = ProcessCapabilityText.AvailabilityText(row);
        SelectedCapabilityApply = row.ApplyStatusText;
        SelectedCapabilityApproval = row.ApprovalText;
        SelectedCapabilityRestore = row.RestoreText;
        SelectedCapabilityReason = string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
            ? "No registry reason reported."
            : row.ReasonOrNextStep;
        SelectedCapabilityNextStep = string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
            ? "Live explain has not returned a next step yet."
            : row.ReasonOrNextStep;
        SelectedCapabilityStatus = "Reading explain details";
        SelectedCapabilityDotState = row.DotState;
        SelectedGateRows.Clear();
        SelectedGateRows.Add(new ProcessCapabilityGateLine("Reading gates from explain", "neutral"));
    }

    private void ApplyExplainDetail(CapabilityRow row, CapabilityRouterResponse? response)
    {
        SelectedCapabilityStatus = ProcessCapabilityText.StatusText(response);
        SelectedCapabilityNextStep = ProcessCapabilityText.NextStepText(row, response);
        SelectedCapabilityErrors = ProcessCapabilityText.ErrorText(response);

        SelectedGateRows.Clear();
        foreach (var gate in ProcessCapabilityText.GateLines(response))
        {
            SelectedGateRows.Add(gate);
        }
    }

    private static (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Classification == "gameTarget" || p.Category == "foregroundGame") return ("Foreground", "safe");
        if (p.Protected || p.Protection == "protected" || p.Classification is "protected" or "protectedCompanion") return ("Protected", "protected");
        if (p.Classification == "demotionCandidate" || CandidateCategories.Contains(p.Category ?? string.Empty)) return ("Candidate", "low");
        return ("Watch", "neutral");
    }

    private void BuildSessionState(GameTuneSessionStatus? session, GameTuneRestorePreview? restorePreview)
    {
        if (session is { DryRun: false, Restorable: true } && session.SessionStatus == "restorable")
        {
            var process = session.ChangedItems?.FirstOrDefault(i => !string.IsNullOrWhiteSpace(i.ProcessName));
            var processName = process is null ? "a process" : Naming.FriendlyName(process.ProcessName);
            SessionSummary = "A restorable process-control session is recorded for " + processName + ".";
            return;
        }

        SessionSummary = restorePreview is { ActionId.Length: > 0 }
            ? "A restore preview is available; no active process-control session is recorded."
            : "No active process-control session is recorded.";
    }

    private void BuildGovernorCaption(ProcessGovernorSessionStatus? governor)
    {
        var evidence = governor?.RuntimeEvidence;
        GovernorCaption = evidence is { BoundedSession: true, RestoreContractAvailable: true }
            ? "Governor budget telemetry reports a bounded session and a restore contract."
            : "Governor budget is read-only here; the capability row reports its route status.";
    }

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

    private static string PriorityText(string? currentPriority, string? proposedPriority)
    {
        var current = FriendlyPriority(currentPriority);
        if (string.IsNullOrWhiteSpace(proposedPriority))
        {
            return current;
        }

        var proposed = FriendlyPriority(proposedPriority);
        return current == proposed ? current : current + " -> " + proposed;
    }

    private static string DisplayName(ProcessItem process)
        => string.IsNullOrWhiteSpace(process.DisplayName) ? Naming.FriendlyName(process.Name) : process.DisplayName!;

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    private void ApplyFilter()
    {
        var query = SearchText?.Trim();
        IEnumerable<GameAppRow> source = _all;
        if (!string.IsNullOrEmpty(query))
        {
            source = source.Where(r =>
                r.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Role.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Plan.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        Rows.Clear();
        ForegroundRows.Clear();
        ProtectedRows.Clear();
        CandidateRows.Clear();
        foreach (var r in source)
        {
            Rows.Add(r);
            if (r.Plan == "Foreground") ForegroundRows.Add(r);
            else if (r.Plan == "Protected") ProtectedRows.Add(r);
            else if (r.Plan == "Candidate") CandidateRows.Add(r);
        }
    }

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

public sealed record ProcessCapabilityItem(CapabilityRow Row)
{
    public string MetaText => ProcessCapabilityText.MetaText(Row);
}

public sealed record ProcessCapabilityGateLine(string Label, string State);

internal static class ProcessCapabilityText
{
    public static string MetaText(CapabilityRow row)
        => FamilyText(row) + " - " + AvailabilityText(row);

    public static string FamilyText(CapabilityRow row)
        => row.Page + " / " + row.Family;

    public static string AvailabilityText(CapabilityRow row)
        => row.MachineAvailable ? "Available on this PC" : "Not available here";

    public static string StatusText(CapabilityRouterResponse? response)
    {
        if (response is null)
        {
            return "Registry status only";
        }

        var status = Clean(response.Status) ?? "completed";
        var action = Clean(response.Action) ?? "explain";
        return action + " - " + status;
    }

    public static string NextStepText(CapabilityRow row, CapabilityRouterResponse? response)
    {
        var next = Clean(response?.NextRequiredStep);
        if (next is not null)
        {
            return next;
        }

        if (!row.MachineAvailable && !string.IsNullOrWhiteSpace(row.ReasonOrNextStep))
        {
            return row.ReasonOrNextStep;
        }

        if (response is null)
        {
            return string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
                ? "Live explain did not return a router envelope; registry status is shown."
                : row.ReasonOrNextStep;
        }

        return "No additional next step reported by explain.";
    }

    public static string? ErrorText(CapabilityRouterResponse? response)
    {
        var errors = response?.Errors?
            .Where(error => !string.IsNullOrWhiteSpace(error.Code) || !string.IsNullOrWhiteSpace(error.Message))
            .Select(error =>
            {
                var code = Clean(error.Code);
                var message = Clean(error.Message);
                if (code is null)
                {
                    return message;
                }

                return message is null ? code : code + ": " + message;
            })
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToList();

        return errors is { Count: > 0 } ? string.Join("; ", errors) : null;
    }

    public static IReadOnlyList<ProcessCapabilityGateLine> GateLines(CapabilityRouterResponse? response)
    {
        if (response is null)
        {
            return new[] { new ProcessCapabilityGateLine("Live explain gates not available", "neutral") };
        }

        var gates = ExtractGates(response.Evidence).ToList();
        if (gates.Count == 0)
        {
            return new[] { new ProcessCapabilityGateLine("No gates reported by explain", "safe") };
        }

        return gates.Select(gate => new ProcessCapabilityGateLine(HumanizeGate(gate), "protected")).ToList();
    }

    private static IEnumerable<string> ExtractGates(JsonElement evidence)
    {
        if (evidence.ValueKind != JsonValueKind.Object)
        {
            yield break;
        }

        if (!evidence.TryGetProperty("capability", out var capability) ||
            capability.ValueKind != JsonValueKind.Object ||
            !capability.TryGetProperty("gates", out var gates) ||
            gates.ValueKind != JsonValueKind.Array)
        {
            yield break;
        }

        foreach (var gate in gates.EnumerateArray())
        {
            if (gate.ValueKind == JsonValueKind.String)
            {
                var value = Clean(gate.GetString());
                if (value is not null)
                {
                    yield return value;
                }
            }
        }
    }

    private static string HumanizeGate(string gate)
        => gate.Replace('-', ' ');

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrWhiteSpace(clean) ? null : clean;
    }
}
