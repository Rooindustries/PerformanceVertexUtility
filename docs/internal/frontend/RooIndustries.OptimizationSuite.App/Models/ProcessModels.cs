using System.Collections.Generic;

namespace RooIndustries.OptimizationSuite.Models;

public sealed class ProcessInventory
{
    public string? CapturedAtUtc { get; set; }
    public ProcessInventorySummary? Summary { get; set; }
    public List<ProcessItem>? Processes { get; set; }
}

public sealed class ProcessInventorySummary
{
    public int ProcessCount { get; set; }
    public int BackgroundProcessCount { get; set; }
    public int ProtectedProcessCount { get; set; }
    public int BrowserWebViewProcessCount { get; set; }
    public int GameProcessCount { get; set; }
    public int CaptureStreamingProcessCount { get; set; }
    public int LauncherProcessCount { get; set; }
    public int VendorUtilityProcessCount { get; set; }
    public long WorkingSetBytes { get; set; }
    public long PrivateBytes { get; set; }
    public long AvailableMemoryBytes { get; set; }
    public long CommitUsedBytes { get; set; }
}

public sealed class ProcessItem
{
    public int Pid { get; set; }
    public string? Name { get; set; }
    public string? DisplayName { get; set; }
    public string? Publisher { get; set; }
    public string? Category { get; set; }
    public string? Protection { get; set; }
    public string? Classification { get; set; }
    public List<string>? RoleTags { get; set; }
    public List<string>? ReasonCodes { get; set; }
    public string? PriorityClass { get; set; }
    public double CpuPercent { get; set; }
    public long WorkingSetBytes { get; set; }
    public long PrivateBytes { get; set; }
    public long GpuDedicatedBytes { get; set; }
    public bool IsForegroundCandidate { get; set; }
    public bool CanChangePriority { get; set; }
    public bool Protected { get; set; }
    public bool Blocked { get; set; }
    public string? Risk { get; set; }

    public string ClassificationLabel => Classification switch
    {
        "gameTarget" => "GAME",
        "protectedCompanion" => "KEEP STEADY",
        "demotionCandidate" => "PUSH BACK",
        "safeCandidate" => "REVIEW",
        "protected" => "KEEP STEADY",
        _ => "REVIEW",
    };

    public string PlayerActionLabel
    {
        get
        {
            if (Protected) return "Keep steady";
            if (Blocked) return "Review first";
            if (Classification == "gameTarget") return "Give room";
            if (Classification == "demotionCandidate") return "Push back";
            return "Review";
        }
    }
}

public sealed class ProcessClassification
{
    public string? ProfileId { get; set; }
    public string? TargetGameProcessName { get; set; }
    public ProcessClassificationSummary? Summary { get; set; }
    public List<ProcessItem>? Processes { get; set; }
}

public sealed class ProcessClassificationSummary
{
    public int ProcessCount { get; set; }
    public Dictionary<string, int>? ClassCounts { get; set; }
    public int ProtectedCount { get; set; }
    public int DemotionCandidateCount { get; set; }
    public int GameTargetCount { get; set; }
    public long WorkingSetBytes { get; set; }
    public long PrivateBytes { get; set; }
}

public sealed class ProcessProfileEnvelope
{
    public string? ActionId { get; set; }
    public string? CorrelationId { get; set; }
    public bool DryRun { get; set; }
    public string? Risk { get; set; }
    public bool RequiresElevation { get; set; }
    public string? Status { get; set; }
    public List<ProcessPreviewRow>? Preview { get; set; }
    public List<IssueModel>? Warnings { get; set; }
    public List<IssueModel>? Errors { get; set; }
    public List<LogEntry>? Logs { get; set; }
}

public sealed class ProcessPreviewRow
{
    public string? PreviewId { get; set; }
    public string? DisplayName { get; set; }
    public string? ProcessName { get; set; }
    public int ProcessId { get; set; }
    public string? CurrentPriorityClass { get; set; }
    public string? ProposedPriorityClass { get; set; }
    public string? ProposedAction { get; set; }
    public string? RuleId { get; set; }
    public string? Reason { get; set; }
    public string? Classification { get; set; }
    public bool Blocked { get; set; }
    public string? BlockedReason { get; set; }
    public string? Risk { get; set; }
    public string? Confidence { get; set; }
    public bool Protected { get; set; }
    public bool RequiresConfirmation { get; set; }
    public bool RollbackSupported { get; set; }

    public string PriorityTransition =>
        ProposedAction == "noChange" || CurrentPriorityClass == ProposedPriorityClass
            ? "No change"
            : $"{CurrentPriorityClass} -> {ProposedPriorityClass}";

    public string StateLabel
    {
        get
        {
            if (Protected) return "Kept steady";
            if (Blocked) return "Review first";
            if (Classification == "gameTarget") return "Game";
            if (Classification == "demotionCandidate") return "Push back";
            return "Watch";
        }
    }
}
