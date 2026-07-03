using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class MonitoringViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle = "How the game actually feels — frame pacing, lows, and the tools that smooth out stutter.";
    [ObservableProperty] private bool _isSampleCapture;
    [ObservableProperty] private string? _sampleCaptureLine;
    [ObservableProperty] private string? _stutterFooterLine;

    public ObservableCollection<MetricTile> LiveTiles { get; } = new();
    public ObservableCollection<MetricTile> PendingTiles { get; } = new();
    public ObservableCollection<StatusLine> Sensors { get; } = new();
    public ObservableCollection<StutterToolRow> StutterTools { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync() ?? await TryLoadSample(Data.GetProcessInventoryAsync);
        var hardware = await App.Live.GetDriverHardwareAsync() ?? await TryLoadSample(Data.GetDriverHardwareAsync);
        var telemetry = await TryLoadSample(Data.GetTelemetryAsync);
        var stutterPreview = await App.Live.GetStutterOptimizationPreviewAsync() ?? await TryLoadSample(Data.GetStutterOptimizationPreviewAsync);
        var ranking = await TryLoadSample(Data.GetStutterOptimizationRankingAsync);
        var summary = inventory?.Summary;
        if (summary is null)
        {
            ErrorMessage = "We couldn't read this PC yet. Close and reopen to try again.";
            return;
        }

        var total = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var used = total > summary.AvailableMemoryBytes ? total - summary.AvailableMemoryBytes : 0;
        var usedPct = total > 0 ? ((int)System.Math.Round((double)used / total * 100)) + "% of memory" : "in use";
        var gpu = hardware?.Gpus?.Count > 0 ? hardware.Gpus[0].Name : "graphics";

        LiveTiles.Clear();
        LiveTiles.Add(new MetricTile("Apps Running", summary.ProcessCount.ToString(CultureInfo.InvariantCulture),
            summary.BackgroundProcessCount + " background"));
        LiveTiles.Add(new MetricTile("RAM Free", Format.Bytes(summary.AvailableMemoryBytes), "available now"));
        LiveTiles.Add(new MetricTile("RAM In Use", Format.Bytes(used), usedPct));
        LiveTiles.Add(new MetricTile("Windows Memory", Format.Bytes(summary.CommitUsedBytes), "commit charge"));

        PendingTiles.Clear();
        if (telemetry?.Metrics is { } metrics)
        {
            PendingTiles.Add(new MetricTile("Avg FPS", Format.Fps(metrics.AverageFps), "frames per second"));
            PendingTiles.Add(new MetricTile("1% low", Format.Fps(metrics.Fps1PercentLow), "worst-case dips"));
            PendingTiles.Add(new MetricTile("0.1% low", Format.Fps(metrics.FpsPoint1PercentLow), "deep dips"));
            PendingTiles.Add(new MetricTile("Frame-time budget", metrics.FrameTimeBudgetMs.ToString("0.00", CultureInfo.InvariantCulture) + " ms", "per frame at target"));
            PendingTiles.Add(new MetricTile("Spikes >16ms", metrics.FrameTimeSpikesOver16ms.ToString(CultureInfo.InvariantCulture), "sample capture"));
        }
        else
        {
            PendingTiles.Add(new MetricTile("Avg FPS", "Not measured yet", "frames per second"));
            PendingTiles.Add(new MetricTile("1% low", "Not measured yet", "worst-case dips"));
            PendingTiles.Add(new MetricTile("Frame-time budget", "Not measured yet", "milliseconds"));
            PendingTiles.Add(new MetricTile("GPU Load", "Not measured yet", CleanDevice(gpu)));
        }

        IsSampleCapture = telemetry?.Quality?.IsSample == true;
        SampleCaptureLine = IsSampleCapture ? "Sample capture — connect PresentMon for live numbers." : null;

        Sensors.Clear();
        foreach (var provider in telemetry?.Providers ?? Enumerable.Empty<ProviderStatus>())
        {
            Sensors.Add(new StatusLine(provider.DisplayName, ProviderState(provider.State), ProviderRisk(provider.State)));
        }

        if (Sensors.Count == 0)
        {
            Sensors.Add(new StatusLine("Windows counters", "Connected", "safe"));
            Sensors.Add(new StatusLine("PresentMon", "Not connected", "neutral"));
            Sensors.Add(new StatusLine("HWiNFO64 sensors", "Not connected", "neutral"));
        }

        BuildStutterTools(stutterPreview, ranking);
    }

    private void BuildStutterTools(StutterOptimizationPreview? preview, StutterOptimizationRanking? ranking)
    {
        StutterTools.Clear();
        var ranked = (ranking?.RankedRemainingOptimizations ?? new())
            .ToDictionary(r => r.OptimizationId ?? string.Empty, r => r);

        foreach (var contract in preview?.Contracts ?? new())
        {
            var rankedItem = ranked.TryGetValue(RankingId(contract.OptimizationId), out var item) ? item : null;
            var (stateLine, state) = ToolState(contract);
            StutterTools.Add(new StutterToolRow(
                contract.OptimizationId ?? string.Empty,
                rankedItem?.Rank ?? 99,
                ToolTitle(contract.OptimizationId, rankedItem?.Title),
                ToolWhy(contract.OptimizationId, rankedItem?.WhyForTarget),
                stateLine,
                state,
                "Preview",
                ToolCaption(contract)));
        }

        var ordered = StutterTools.OrderBy(t => t.Rank).ToList();
        StutterTools.Clear();
        foreach (var tool in ordered)
        {
            StutterTools.Add(tool);
        }

        StutterFooterLine = preview?.Summary?.WillChangeSystem == false
            ? "Nothing changes your system yet — every tool previews first"
            : null;
    }

    private static string RankingId(string? optimizationId) => optimizationId switch
    {
        "standby-memory" => "memory-pressure-standby-list-control",
        "timer-resolution" => "timer-resolution-session-lifecycle",
        "power-plan" => "power-plan-and-power-state-restore",
        "shader-cache-cleanup" => "shader-cache-and-profile-stutter-workflow",
        "service-pause-preview" => "service-pause-session-with-allowlist",
        _ => optimizationId ?? string.Empty,
    };

    private static (string stateLine, string state) ToolState(StutterOptimizationContract contract)
        => contract.OptimizationId switch
        {
            "standby-memory" => ("Helper packaging pending", "protected"),
            "shader-cache-cleanup" => ("Tested on a safe copy", "low"),
            "timer-resolution" or "power-plan" or "service-pause-preview" => ("Ready — needs your go-ahead", "protected"),
            _ => ((contract.BackendStatus ?? "Ready to review").Replace('-', ' '), "protected"),
        };

    private static string ToolTitle(string? optimizationId, string? rankedTitle) => optimizationId switch
    {
        "standby-memory" => "Free standby memory",
        "timer-resolution" => "Timer resolution",
        "power-plan" => "Power plan",
        "shader-cache-cleanup" => "Shader cache cleanup",
        "service-pause-preview" => "Pause spare services",
        _ => string.IsNullOrWhiteSpace(rankedTitle) ? "Stutter tool" : rankedTitle!,
    };

    private static string ToolWhy(string? optimizationId, string? rankedWhy) => optimizationId switch
    {
        "standby-memory" => "Helps when RAM and commit pressure leave less room for the match.",
        "timer-resolution" => "Can improve input responsiveness during a confirmed game session.",
        "power-plan" => "Keeps CPU power behavior steady during a match, then restores your current plan.",
        "shader-cache-cleanup" => "Reviews shader cache cleanup with backup before anything touches real files.",
        "service-pause-preview" => "Finds spare services that can wait until the match is over.",
        _ => FirstSentence(rankedWhy),
    };

    private static string ToolCaption(StutterOptimizationContract contract)
    {
        var rollback = contract.Rollback;
        if (contract.OptimizationId == "power-plan" && rollback?.RestoreRequiredBeforeApply == true) return "Restores your current plan after.";
        if (contract.OptimizationId == "shader-cache-cleanup" && rollback?.BackupRequiredBeforeDelete == true) return "Backs up before deleting.";
        if (contract.OptimizationId == "service-pause-preview" && rollback?.StateBackupRequired == true) return "Backs up service state first.";
        if (rollback?.RollbackSupported == true) return "Reversible session.";
        return "Review first.";
    }

    private static string ProviderState(string? state) => (state ?? string.Empty).ToLowerInvariant() switch
    {
        "available" => "Connected",
        "sample" => "Sample capture",
        "optional-not-detected" or "missing" => "Not connected",
        _ => string.IsNullOrWhiteSpace(state) ? "Unknown" : state!.Replace('-', ' '),
    };

    private static string ProviderRisk(string? state) => (state ?? string.Empty).ToLowerInvariant() switch
    {
        "available" => "safe",
        "sample" => "neutral",
        _ => "neutral",
    };

    private static string FirstSentence(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "Review first.";
        var index = text.IndexOf('.');
        return index > 0 ? text[..(index + 1)] : text;
    }

    private static string CleanDevice(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "graphics";
        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("  ", " ").Trim();
    }

    private static async Task<T?> TryLoadSample<T>(System.Func<Task<T>> load) where T : class
    {
        try
        {
            return await load().ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }
}
