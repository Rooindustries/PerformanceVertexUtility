using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class ReportsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle = "Your tune results, side by side.";
    [ObservableProperty] private string _emptyNote =
        "No saved tune yet. After your first session we save the before and after here so you can see what changed.";
    [ObservableProperty] private string? _reportTitle;
    [ObservableProperty] private string? _scenarioLine;

    public ObservableCollection<MetricTile> Baseline { get; } = new();
    public ObservableCollection<MetricTile> Numbers { get; } = new();
    public ObservableCollection<FindingRow> Findings { get; } = new();
    public ObservableCollection<NextActionRow> NextActions { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var report = await Data.GetReportSummaryAsync();
        ReportTitle = string.IsNullOrWhiteSpace(report.Title) ? "More FPS. Less Input Lag." : report.Title;
        Subtitle = string.IsNullOrWhiteSpace(report.Scenario?.Goal) ? "Your tune results, side by side." : report.Scenario!.Goal!;
        ScenarioLine = BuildScenarioLine(report.Scenario);

        BuildFindings(report.Findings);
        BuildNumbers(report.MetricSummary);
        BuildNextActions(report.RecommendedActions);
    }

    private void BuildFindings(IReadOnlyList<ReportFinding>? findings)
    {
        Findings.Clear();
        foreach (var finding in findings ?? new List<ReportFinding>())
        {
            Findings.Add(new FindingRow(
                finding.Title ?? "Finding",
                finding.Detail ?? string.Empty,
                FriendlyEvidence(finding.Evidence),
                finding.Severity == "warning" ? "warning" : "info"));
        }
    }

    private void BuildNumbers(ReportMetricSummary? metrics)
    {
        Baseline.Clear();
        Numbers.Clear();
        if (metrics is null)
        {
            return;
        }

        var rows = new[]
        {
            new MetricTile("Avg FPS", Format.Fps(metrics.AverageFps), "sample baseline"),
            new MetricTile("1% low", Format.Fps(metrics.Fps1PercentLow), "sample baseline"),
            new MetricTile("0.1% low", Format.Fps(metrics.FpsPoint1PercentLow), "sample baseline"),
            new MetricTile("Spikes >16ms", metrics.FrameTimeSpikesOver16ms.ToString(CultureInfo.InvariantCulture), "sample capture"),
            new MetricTile("Memory available", Format.Bytes(metrics.AvailableMemoryBytes), "before a tune"),
            new MetricTile("Shared GPU memory", Format.Bytes(metrics.GpuSharedMemoryUsedBytes), "sample baseline"),
        };

        foreach (var row in rows)
        {
            Baseline.Add(row);
            Numbers.Add(row);
        }
    }

    private void BuildNextActions(IReadOnlyList<RecommendedAction>? actions)
    {
        NextActions.Clear();
        foreach (var action in actions ?? new List<RecommendedAction>())
        {
            NextActions.Add(new NextActionRow(
                action.ActionId ?? string.Empty,
                action.Label ?? "Review",
                action.Reason ?? string.Empty,
                action.Risk ?? "low",
                RouteFor(action.ActionId)));
        }
    }

    private static string BuildScenarioLine(ReportScenario? scenario)
    {
        if (scenario is null)
        {
            return string.Empty;
        }

        var workload = scenario.BackgroundWorkload is { Count: > 0 }
            ? string.Join(" + ", scenario.BackgroundWorkload)
            : "background apps";
        return scenario.Game + " with " + workload + " | " + scenario.RamClassGb.ToString(CultureInfo.InvariantCulture)
            + " GB RAM | " + scenario.DisplayTargetHz.ToString(CultureInfo.InvariantCulture) + " Hz";
    }

    private static string FriendlyEvidence(IReadOnlyList<string>? evidence)
    {
        if (evidence is null || evidence.Count == 0)
        {
            return string.Empty;
        }

        return string.Join(", ", evidence.Select(e => e switch
        {
            var x when x.StartsWith("processCount=", System.StringComparison.OrdinalIgnoreCase) => x["processCount=".Length..] + " apps",
            var x when x.StartsWith("backgroundProcessCount=", System.StringComparison.OrdinalIgnoreCase) => x["backgroundProcessCount=".Length..] + " in the background",
            var x when x.StartsWith("browserWebViewProcessCount=", System.StringComparison.OrdinalIgnoreCase) => x["browserWebViewProcessCount=".Length..] + " browser helpers",
            _ => e.Replace(".exe", string.Empty),
        }));
    }

    private static string RouteFor(string? actionId)
    {
        if (string.IsNullOrWhiteSpace(actionId)) return "dashboard";
        if (actionId.StartsWith("performance.", System.StringComparison.OrdinalIgnoreCase)) return "profiles";
        if (actionId.StartsWith("apps.", System.StringComparison.OrdinalIgnoreCase)) return "uninstall";
        if (actionId.StartsWith("drivers.", System.StringComparison.OrdinalIgnoreCase)) return "drivers";
        return "dashboard";
    }
}
