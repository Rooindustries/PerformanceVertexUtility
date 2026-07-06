using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class DashboardViewModel : PageViewModelBase
{
    [ObservableProperty] private string _verdictHeadline = "Reading what this PC supports";
    [ObservableProperty] private string _verdictLevel = "medium";
    [ObservableProperty] private string? _verdictSummary;
    [ObservableProperty] private string? _driverNote;
    [ObservableProperty] private int _memoryUsedPercent;
    [ObservableProperty] private string _memoryPressureLabel = "Reading";
    [ObservableProperty] private string? _memoryPressureLine;
    [ObservableProperty] private StatusLine? _stutterRiskLine;
    [ObservableProperty] private int _totalCapabilityCount;
    [ObservableProperty] private int _availableCapabilityCount;
    [ObservableProperty] private int _unavailableCapabilityCount;
    [ObservableProperty] private int _readyLiveCount;
    [ObservableProperty] private int _reviewOnlyCount;
    [ObservableProperty] private string _nextActionsSummary = "Reading what this PC supports.";
    [ObservableProperty] private string _nextActionsCountText = "0 ready";
    [ObservableProperty] private bool _hasNextActions;

    public ObservableCollection<DashboardCard> ReadinessCards { get; } = new();
    public ObservableCollection<CapabilityPageSummary> CapabilityPages { get; } = new();
    public ObservableCollection<StatusLine> CapabilityStatusLines { get; } = new();
    public ObservableCollection<CapabilityActionRow> NextActions { get; } = new();
    public ObservableCollection<StatusLine> SessionLines { get; } = new();
    public ObservableCollection<UsageLine> TopMemoryUsers { get; } = new();
    public ObservableCollection<UsageLine> BackgroundOffenders { get; } = new();
    public ObservableCollection<StatusLine> DriverLines { get; } = new();

    private static readonly string[] PageOrder =
    {
        "Process Controls",
        "Clean Junk",
        "Drivers & NVIDIA",
        "System Tweaks",
    };

    protected override async Task LoadCoreAsync()
    {
        var capabilities = await App.Capabilities.GetCapabilitiesAsync();
        BuildCapabilityOverview(capabilities);

        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();

        if (inventory?.Summary is null)
        {
            WriteDiag(inventory);
            BuildUnavailableLiveReadiness(hardware);
            return;
        }

        var summary = inventory.Summary;
        var processes = inventory.Processes ?? new List<ProcessItem>();

        var totalRam = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var ramGb = totalRam > 0 ? (int)Math.Round(totalRam / 1073741824d) : 0;
        var freeRam = summary.AvailableMemoryBytes;
        var usedRam = totalRam > freeRam ? totalRam - freeRam : 0;
        double? freeRatio = totalRam > 0 ? (double)freeRam / totalRam : null;

        BuildVerdict(freeRatio, summary, hardware, ramGb);
        BuildSession(processes);
        BuildMemory(summary, usedRam, totalRam, ramGb);
        BuildTopUsers(processes);
        BuildBackground(summary, processes);
        BuildDriver(hardware);
        BuildStutterRisk(summary, freeRatio);
    }

    private void BuildCapabilityOverview(IReadOnlyList<CapabilityRow> capabilities)
    {
        TotalCapabilityCount = capabilities.Count;
        AvailableCapabilityCount = capabilities.Count(row => row.MachineAvailable);
        UnavailableCapabilityCount = capabilities.Count(row => !row.MachineAvailable);
        ReadyLiveCount = CountStatus(capabilities, "live");
        ReviewOnlyCount = CountStatus(capabilities, "preview-only");

        BuildReadinessCards();
        BuildCapabilityPages(capabilities);
        BuildCapabilityStatuses(capabilities);
        BuildNextActions(capabilities);
    }

    private void BuildReadinessCards()
    {
        ReadinessCards.Clear();
        ReadinessCards.Add(new DashboardCard(
            "capability-registry",
            "Optimization catalog",
            TotalCapabilityCount.ToString(CultureInfo.InvariantCulture) + " optimizations",
            "Counts cover every optimizer page on this PC.",
            TotalCapabilityCount > 0 ? "safe" : "neutral"));
        ReadinessCards.Add(new DashboardCard(
            "ready-live",
            "Ready/live",
            ReadyLiveCount.ToString(CultureInfo.InvariantCulture) + " ready",
            "Available on this PC with apply and restore paths marked live.",
            ReadyLiveCount > 0 ? "safe" : "neutral"));
        ReadinessCards.Add(new DashboardCard(
            "review-only",
            "Review only",
            ReviewOnlyCount.ToString(CultureInfo.InvariantCulture) + " review-only",
            "Preview surfaces that do not change this PC yet.",
            ReviewOnlyCount > 0 ? "protected" : "neutral"));
        ReadinessCards.Add(new DashboardCard(
            "unavailable-here",
            "Unavailable here",
            UnavailableCapabilityCount.ToString(CultureInfo.InvariantCulture) + " gated",
            "Blocked by this machine, missing tools, or a permissions requirement.",
            UnavailableCapabilityCount > 0 ? "neutral" : "safe"));
    }

    private void BuildCapabilityPages(IReadOnlyList<CapabilityRow> capabilities)
    {
        CapabilityPages.Clear();
        foreach (var page in PageOrder)
        {
            var rows = capabilities
                .Where(row => string.Equals(row.Page, page, StringComparison.OrdinalIgnoreCase))
                .ToList();
            var available = rows.Count(row => row.MachineAvailable);
            var live = rows.Count(row => IsApplyState(row, "live"));
            var review = rows.Count(row => IsApplyState(row, "preview-only"));
            var unavailable = rows.Count(row => !row.MachineAvailable);
            var detail = available.ToString(CultureInfo.InvariantCulture) + " available, "
                + live.ToString(CultureInfo.InvariantCulture) + " ready/live, "
                + review.ToString(CultureInfo.InvariantCulture) + " review-only, "
                + unavailable.ToString(CultureInfo.InvariantCulture) + " unavailable here";

            CapabilityPages.Add(new CapabilityPageSummary(
                page,
                rows.Count.ToString(CultureInfo.InvariantCulture),
                detail,
                PageState(rows.Count, available, live)));
        }
    }

    private void BuildCapabilityStatuses(IReadOnlyList<CapabilityRow> capabilities)
    {
        CapabilityStatusLines.Clear();
        AddStatus("Available on this PC", AvailableCapabilityCount + " of " + TotalCapabilityCount, AvailableCapabilityCount > 0 ? "safe" : "neutral");
        AddStatus("Ready/live", ReadyLiveCount + " optimizations", ReadyLiveCount > 0 ? "safe" : "neutral");
        AddStatus("Review-only", ReviewOnlyCount + " optimizations", ReviewOnlyCount > 0 ? "protected" : "neutral");

        var fixtureProven = CountStatus(capabilities, "fixture-proven");
        if (fixtureProven > 0)
        {
            AddStatus("Tested on a safe copy", fixtureProven + " optimizations", "low");
        }

        var allowlistShim = CountStatus(capabilities, "allowlist-shim");
        if (allowlistShim > 0)
        {
            AddStatus("Runs app tool", allowlistShim + " optimizations", "low");
        }

        var helperContract = CountStatus(capabilities, "helper-contract");
        if (helperContract > 0)
        {
            AddStatus("Helper packaging pending", helperContract + " pending helper", "protected");
        }

        var notImplemented = CountStatus(capabilities, "not-implemented");
        if (notImplemented > 0)
        {
            AddStatus("Not available yet", notImplemented + " optimizations", "neutral");
        }

        AddStatus("Unavailable here", UnavailableCapabilityCount + " optimizations", UnavailableCapabilityCount > 0 ? "neutral" : "safe");
    }

    private void BuildNextActions(IReadOnlyList<CapabilityRow> capabilities)
    {
        NextActions.Clear();
        foreach (var row in capabilities
            .Where(row => row.MachineAvailable && IsApplyState(row, "live"))
            .OrderBy(row => PageRank(row.Page))
            .ThenBy(row => row.Label, StringComparer.OrdinalIgnoreCase)
            .Take(8))
        {
            NextActions.Add(CapabilityActionRow.From(row));
        }

        HasNextActions = NextActions.Count > 0;
        NextActionsCountText = NextActions.Count.ToString(CultureInfo.InvariantCulture)
            + (NextActions.Count == 1 ? " ready" : " ready");
        NextActionsSummary = HasNextActions
            ? "Live and available on this PC. Open the matching page to review the exact action before anything changes."
            : "No live actions are available on this PC yet; review-only and gated items stay visible by page.";
    }

    private void BuildVerdict(double? freeRatio, ProcessInventorySummary summary, DriverHardwareSummary? hw, int ramGb)
    {
        VerdictHeadline = ReadyLiveCount > 0
            ? ReadyLiveCount.ToString(CultureInfo.InvariantCulture) + " live optimizations are ready on this PC."
            : AvailableCapabilityCount > 0
                ? AvailableCapabilityCount.ToString(CultureInfo.InvariantCulture) + " optimizations are available for review."
                : "Some optimizations are gated on this PC.";

        VerdictLevel = freeRatio switch
        {
            < 0.15 and >= 0 => "high",
            < 0.30 and >= 0 => "medium",
            _ when ReadyLiveCount > 0 => "safe",
            _ when AvailableCapabilityCount > 0 => "protected",
            _ => "neutral",
        };

        var gpu = CleanDevice(hw?.Gpus?.FirstOrDefault()?.Name);
        var parts = new List<string>
        {
            TotalCapabilityCount.ToString(CultureInfo.InvariantCulture) + " optimizations cataloged across the optimizer pages",
            AvailableCapabilityCount.ToString(CultureInfo.InvariantCulture) + " available",
            ReviewOnlyCount.ToString(CultureInfo.InvariantCulture) + " review-only",
            UnavailableCapabilityCount.ToString(CultureInfo.InvariantCulture) + " unavailable here",
        };
        if (!string.IsNullOrWhiteSpace(gpu))
        {
            parts.Add(gpu);
        }

        if (ramGb > 0)
        {
            parts.Add(ramGb.ToString(CultureInfo.InvariantCulture) + " GB RAM");
        }

        parts.Add(summary.ProcessCount.ToString(CultureInfo.InvariantCulture) + " apps open, "
            + summary.BackgroundProcessCount.ToString(CultureInfo.InvariantCulture) + " in the background");
        VerdictSummary = string.Join(" - ", parts);
    }

    private void BuildUnavailableLiveReadiness(DriverHardwareSummary? hardware)
    {
        VerdictHeadline = ReadyLiveCount > 0
            ? ReadyLiveCount.ToString(CultureInfo.InvariantCulture) + " live optimizations are ready on this PC."
            : "Optimization catalog is loaded.";
        VerdictLevel = ReadyLiveCount > 0 ? "safe" : "protected";
        VerdictSummary = TotalCapabilityCount.ToString(CultureInfo.InvariantCulture)
            + " optimizations cataloged. Process and memory inventory did not return data.";

        MemoryUsedPercent = 0;
        MemoryPressureLabel = "Not measured";
        MemoryPressureLine = "Process inventory is unavailable, so memory pressure is not estimated here.";

        SessionLines.Clear();
        SessionLines.Add(new StatusLine("Process inventory", "Not available", "neutral"));

        TopMemoryUsers.Clear();
        TopMemoryUsers.Add(new UsageLine("Process inventory", "Not available", "-"));

        BackgroundOffenders.Clear();
        BackgroundOffenders.Add(new UsageLine("Background apps", "Not measured", "-"));

        StutterRiskLine = new StatusLine("Readiness signal", "Not measured without process inventory.", "neutral");
        BuildDriver(hardware);
    }

    private void BuildSession(IReadOnlyList<ProcessItem> processes)
    {
        SessionLines.Clear();

        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        SessionLines.Add(game is not null
            ? new StatusLine("Game", DisplayName(game) + " running", "safe")
            : new StatusLine("Game", "No game detected", "neutral"));

        var companions = processes
            .Where(p => p.Protection == "protected" && (p.Category is "voiceChat" or "captureStreaming"))
            .Select(DisplayName)
            .Distinct()
            .ToList();
        SessionLines.Add(companions.Count > 0
            ? new StatusLine("Companion apps", string.Join(" + ", companions) + " protected", "safe")
            : new StatusLine("Companion apps", "None running", "neutral"));

        SessionLines.Add(new StatusLine("Next action", "Open a page to review details", "neutral"));
    }

    private void BuildMemory(ProcessInventorySummary s, long usedRam, long totalRam, int ramGb)
    {
        MemoryUsedPercent = totalRam > 0 ? (int)Math.Round((double)usedRam / totalRam * 100) : 0;
        MemoryPressureLabel = MemoryUsedPercent switch
        {
            >= 85 => "Heavy",
            >= 70 => "Moderate",
            _ => "Light",
        };

        var totalText = ramGb > 0 ? ramGb.ToString(CultureInfo.InvariantCulture) + " GB" : Format.Bytes(totalRam);
        MemoryPressureLine = Format.Bytes(s.AvailableMemoryBytes) + " free of " + totalText
            + " - Windows memory " + Format.Bytes(s.CommitUsedBytes);
    }

    private void BuildTopUsers(IReadOnlyList<ProcessItem> processes)
    {
        TopMemoryUsers.Clear();
        var rows = processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(5);

        foreach (var p in rows)
        {
            TopMemoryUsers.Add(new UsageLine(Naming.FriendlyName(p.Name), Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes)));
        }

        if (TopMemoryUsers.Count == 0)
        {
            TopMemoryUsers.Add(new UsageLine("Process inventory", "No user apps reported", "-"));
        }
    }

    private void BuildBackground(ProcessInventorySummary s, IReadOnlyList<ProcessItem> processes)
    {
        BackgroundOffenders.Clear();
        var rows = processes
            .Where(p => p.Protection != "protected" && p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(6);

        foreach (var p in rows)
        {
            BackgroundOffenders.Add(new UsageLine(Naming.FriendlyName(p.Name), Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes)));
        }

        if (BackgroundOffenders.Count == 0)
        {
            BackgroundOffenders.Add(new UsageLine("Background apps", s.BackgroundProcessCount.ToString(CultureInfo.InvariantCulture) + " reported", "-"));
        }
    }

    private void BuildDriver(DriverHardwareSummary? hw)
    {
        DriverLines.Clear();
        var machine = hw?.Machine;
        if (machine is not null)
        {
            var system = string.Join(" ", new[] { machine.Manufacturer, machine.Model }.Where(x => !string.IsNullOrWhiteSpace(x)));
            DriverLines.Add(new StatusLine("System", string.IsNullOrWhiteSpace(system) ? "Unknown" : system, "neutral"));
            if (!string.IsNullOrWhiteSpace(machine.OsCaption))
            {
                DriverLines.Add(new StatusLine("Windows", machine.OsCaption!, "neutral"));
            }
        }

        var cpu = CleanDevice(hw?.Cpu?.Name);
        if (!string.IsNullOrWhiteSpace(cpu))
        {
            DriverLines.Add(new StatusLine("Processor", cpu!, "neutral"));
        }

        var gpu = hw?.Gpus?.FirstOrDefault();
        if (gpu is not null)
        {
            var gpuText = CleanDevice(gpu.Name);
            if (!string.IsNullOrWhiteSpace(gpu.DriverVersion))
            {
                gpuText += " - Driver " + gpu.DriverVersion;
            }
            DriverLines.Add(new StatusLine("Graphics", gpuText ?? "Unknown", "neutral"));
        }

        if (DriverLines.Count == 0)
        {
            DriverLines.Add(new StatusLine("Hardware", "Not read yet", "neutral"));
        }

        DriverNote = "Driver and GPU actions show their own availability, approval, and restore status before any change.";
    }

    private void BuildStutterRisk(ProcessInventorySummary summary, double? freeRatio)
    {
        var level = freeRatio switch
        {
            < 0.15 and >= 0 => "high",
            < 0.30 and >= 0 => "medium",
            _ when summary.BackgroundProcessCount >= 90 => "medium",
            _ => "low",
        };
        var label = level switch
        {
            "high" => "High - memory pressure",
            "medium" => "Medium - background load",
            _ => "Low - inventory looks steady",
        };

        StutterRiskLine = new StatusLine(
            "Readiness signal",
            label + ". Based on " + summary.BackgroundProcessCount.ToString(CultureInfo.InvariantCulture)
            + " background apps and " + Format.Bytes(summary.AvailableMemoryBytes) + " available memory.",
            level);
    }

    private void AddStatus(string label, string value, string state)
        => CapabilityStatusLines.Add(new StatusLine(label, value, state));

    private static int CountStatus(IReadOnlyList<CapabilityRow> capabilities, string status)
        => capabilities.Count(row => row.MachineAvailable && IsApplyState(row, status));

    private static bool IsApplyState(CapabilityRow row, string status)
        => string.Equals(row.ApplyState, status, StringComparison.OrdinalIgnoreCase);

    private static string PageState(int total, int available, int live)
    {
        if (total == 0)
        {
            return "neutral";
        }

        if (live > 0)
        {
            return "safe";
        }

        return available > 0 ? "protected" : "neutral";
    }

    private static int PageRank(string page)
    {
        for (var i = 0; i < PageOrder.Length; i++)
        {
            if (string.Equals(PageOrder[i], page, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return PageOrder.Length;
    }

    private static void WriteDiag(ProcessInventory? inventory)
    {
        try
        {
            var dir = System.IO.Path.Combine(
                System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                "RooOptimizationSuite");
            System.IO.Directory.CreateDirectory(dir);
            var text =
                "repoRoot=" + (App.Live.RepoRoot ?? "null") + System.Environment.NewLine +
                "scriptsDir=" + (App.Live.ScriptsDirectory ?? "null") + System.Environment.NewLine +
                "scriptsAvailable=" + App.Live.ScriptsAvailable + System.Environment.NewLine +
                "inventoryNull=" + (inventory is null) + System.Environment.NewLine +
                "baseDir=" + System.AppContext.BaseDirectory + System.Environment.NewLine +
                "lastError=" + (App.Live.LastError ?? "none");
            System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "live-diag.log"), text);
        }
        catch
        {
        }
    }

    private static string? CleanDevice(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("(C)", string.Empty)
            .Replace("  ", " ").Trim();
    }

    private static string DisplayName(ProcessItem process)
        => string.IsNullOrWhiteSpace(process.DisplayName) ? Naming.FriendlyName(process.Name) : process.DisplayName!;

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

public sealed record CapabilityPageSummary(string Page, string Count, string Detail, string State);

public sealed record CapabilityActionRow(
    string CapabilityId,
    string Label,
    string Page,
    string AvailabilityText,
    string ApplyStatusText,
    string ApprovalText,
    string RestoreText,
    string ReasonOrNextStep,
    string DotState)
{
    public string StatusLine => Page + " - " + AvailabilityText + " - " + ApplyStatusText + " - " + ApprovalText + " - " + RestoreText;

    public static CapabilityActionRow From(CapabilityRow row)
        => new(
            row.CapabilityId,
            row.Label,
            row.Page,
            row.MachineAvailable ? "Available on this PC" : "Not available here",
            row.ApplyStatusText,
            row.ApprovalText,
            row.RestoreText,
            row.ReasonOrNextStep,
            row.DotState);
}
