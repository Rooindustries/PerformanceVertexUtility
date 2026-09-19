using System.Collections.Generic;

namespace RooIndustries.OptimizationSuite.Models;

public sealed class ProductBackendStatus
{
    public string? ProductName { get; set; }
    public string? GeneratedAtUtc { get; set; }
    public string? Status { get; set; }
    public string? BackendPackageVersion { get; set; }
    public SafetyStatus? Safety { get; set; }
    public List<WorkflowReadiness>? WorkflowReadiness { get; set; }
    public List<string>? DataContracts { get; set; }
    public List<string>? Limitations { get; set; }
}

public sealed class SafetyStatus
{
    public string? DefaultMode { get; set; }
    public bool RequiresExplicitConfirmation { get; set; }
    public bool BackupRequiredBeforeApply { get; set; }
    public bool RollbackVisible { get; set; }
    public bool RemoteScriptExecutionAllowed { get; set; }
    public bool DriverAutomationAllowed { get; set; }
    public bool LeftoverDeletionAllowedByDefault { get; set; }
}

public sealed class WorkflowReadiness
{
    public string? WorkflowId { get; set; }
    public string? Name { get; set; }
    public string? ContractStatus { get; set; }
    public string? ImplementationStatus { get; set; }
    public string? NextBackendStep { get; set; }
}

public sealed class DashboardStatus
{
    public string? ProductName { get; set; }
    public string? CapturedAtUtc { get; set; }
    public string? DashboardStatus_ { get; set; }
    public DashboardHeadline? Headline { get; set; }
    public SystemSummary? SystemSummary { get; set; }
    public List<DashboardCard>? Cards { get; set; }
    public List<RecommendedAction>? RecommendedNextActions { get; set; }
    public List<ProviderStatus>? ProviderStatus { get; set; }
}

public sealed class DashboardHeadline
{
    public string? Title { get; set; }
    public string? Summary { get; set; }
}

public sealed class SystemSummary
{
    public int RamClassGb { get; set; }
    public string? TargetScenario { get; set; }
    public int ProcessCount { get; set; }
    public int BackgroundProcessCount { get; set; }
    public long AvailableMemoryBytes { get; set; }
    public long CommitUsedBytes { get; set; }
    public long GpuDedicatedMemoryUsedBytes { get; set; }
    public long GpuSharedMemoryUsedBytes { get; set; }
    public string? RiskSignal { get; set; }
}

public sealed class DashboardCard
{
    public string? CardId { get; set; }
    public string? Title { get; set; }
    public string? State { get; set; }
    public string? PrimaryMetric { get; set; }
    public string? Detail { get; set; }
}
