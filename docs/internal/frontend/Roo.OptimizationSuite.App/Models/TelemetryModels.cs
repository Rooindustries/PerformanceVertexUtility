using System.Collections.Generic;

namespace Roo.OptimizationSuite.Models;

public sealed class TelemetrySnapshot
{
    public string? SnapshotId { get; set; }
    public string? CapturedAtUtc { get; set; }
    public TelemetryContext? Context { get; set; }
    public TelemetryMetrics? Metrics { get; set; }
    public List<ProcessItem>? Processes { get; set; }
    public List<ProviderStatus>? Providers { get; set; }
    public TelemetryQuality? Quality { get; set; }
}

public sealed class TelemetryContext
{
    public string? Scenario { get; set; }
    public string? ProfileId { get; set; }
    public string? CaptureMode { get; set; }
    public int DisplayTargetHz { get; set; }
}

public sealed class TelemetryMetrics
{
    public double AverageFps { get; set; }
    public double Fps1PercentLow { get; set; }
    public double FpsPoint1PercentLow { get; set; }
    public double FrameTimeBudgetMs { get; set; }
    public int FrameTimeSpikesOver16ms { get; set; }
    public int FrameTimeSpikesOver25ms { get; set; }
    public int FrameTimeSpikesOver33ms { get; set; }
    public int ProcessCount { get; set; }
    public int BackgroundProcessCount { get; set; }
    public long WorkingSetBytes { get; set; }
    public long PrivateBytes { get; set; }
    public long AvailableMemoryBytes { get; set; }
    public long GpuDedicatedMemoryUsedBytes { get; set; }
    public long GpuSharedMemoryUsedBytes { get; set; }
    public double CpuTotalPercent { get; set; }
    public double GpuTotalPercent { get; set; }
    public double GpuEncodePercent { get; set; }
}

public sealed class TelemetryQuality
{
    public bool IsSample { get; set; }
    public string? Confidence { get; set; }
    public List<string>? MissingSignals { get; set; }
}

public sealed class ReportSummary
{
    public string? ReportId { get; set; }
    public string? GeneratedAtUtc { get; set; }
    public string? Title { get; set; }
    public ReportScenario? Scenario { get; set; }
    public List<ReportFinding>? Findings { get; set; }
    public ReportMetricSummary? MetricSummary { get; set; }
    public List<RecommendedAction>? RecommendedActions { get; set; }
    public List<ReportArtifact>? Artifacts { get; set; }
}

public sealed class ReportMetricSummary
{
    public double AverageFps { get; set; }
    public double Fps1PercentLow { get; set; }
    public double FpsPoint1PercentLow { get; set; }
    public int FrameTimeSpikesOver16ms { get; set; }
    public long AvailableMemoryBytes { get; set; }
    public long GpuSharedMemoryUsedBytes { get; set; }
}

public sealed class ReportScenario
{
    public string? Game { get; set; }
    public List<string>? BackgroundWorkload { get; set; }
    public int RamClassGb { get; set; }
    public int DisplayTargetHz { get; set; }
    public string? Goal { get; set; }
}

public sealed class ReportFinding
{
    public string? FindingId { get; set; }
    public string? Severity { get; set; }
    public string? Title { get; set; }
    public string? Detail { get; set; }
    public List<string>? Evidence { get; set; }
}

public sealed class ReportArtifact
{
    public string? ArtifactId { get; set; }
    public string? Type { get; set; }
    public string? Path { get; set; }
}
