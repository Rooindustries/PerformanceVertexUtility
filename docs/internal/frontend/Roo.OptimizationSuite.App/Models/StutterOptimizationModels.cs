using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Models;

public sealed class StutterOptimizationPreview
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("executionMode")] public string? ExecutionMode { get; set; }
    [JsonPropertyName("optimizationId")] public string? OptimizationId { get; set; }
    [JsonPropertyName("contracts")] public List<StutterOptimizationContract>? Contracts { get; set; }
    [JsonPropertyName("summary")] public StutterOptimizationSummary? Summary { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class StutterOptimizationContract
{
    [JsonPropertyName("optimizationId")] public string? OptimizationId { get; set; }
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("backendStatus")] public string? BackendStatus { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("proposedAction")] public StutterProposedAction? ProposedAction { get; set; }
    [JsonPropertyName("rollback")] public StutterRollback? Rollback { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
}

public sealed class StutterProposedAction
{
    [JsonPropertyName("action")] public string? Action { get; set; }
    [JsonPropertyName("applyAllowedNow")] public bool ApplyAllowedNow { get; set; }
    [JsonPropertyName("disposableFixtureSupported")] public bool DisposableFixtureSupported { get; set; }
}

public sealed class StutterRollback
{
    [JsonPropertyName("rollbackSupported")] public bool RollbackSupported { get; set; }
    [JsonPropertyName("restoreRequiredBeforeApply")] public bool RestoreRequiredBeforeApply { get; set; }
    [JsonPropertyName("backupRequiredBeforeDelete")] public bool BackupRequiredBeforeDelete { get; set; }
    [JsonPropertyName("stateBackupRequired")] public bool StateBackupRequired { get; set; }
    [JsonPropertyName("implementedNow")] public bool ImplementedNow { get; set; }
}

public sealed class StutterOptimizationSummary
{
    [JsonPropertyName("contractCount")] public int ContractCount { get; set; }
    [JsonPropertyName("realApplyAllowedCount")] public int RealApplyAllowedCount { get; set; }
    [JsonPropertyName("fixtureApplyReadyCount")] public int FixtureApplyReadyCount { get; set; }
    [JsonPropertyName("willChangeSystem")] public bool WillChangeSystem { get; set; }
    [JsonPropertyName("willLaunchUtilities")] public bool WillLaunchUtilities { get; set; }
    [JsonPropertyName("willWriteState")] public bool WillWriteState { get; set; }
}

public sealed class StutterOptimizationRanking
{
    [JsonPropertyName("catalogId")] public string? CatalogId { get; set; }
    [JsonPropertyName("targetScenario")] public StutterTargetScenario? TargetScenario { get; set; }
    [JsonPropertyName("rankedRemainingOptimizations")] public List<RankedStutterOptimization>? RankedRemainingOptimizations { get; set; }
}

public sealed class StutterTargetScenario
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("game")] public string? Game { get; set; }
    [JsonPropertyName("ramClassGb")] public int RamClassGb { get; set; }
    [JsonPropertyName("primaryGoal")] public string? PrimaryGoal { get; set; }
}

public sealed class RankedStutterOptimization
{
    [JsonPropertyName("rank")] public int Rank { get; set; }
    [JsonPropertyName("optimizationId")] public string? OptimizationId { get; set; }
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("currentBackendCoverage")] public string? CurrentBackendCoverage { get; set; }
    [JsonPropertyName("whyForTarget")] public string? WhyForTarget { get; set; }
    [JsonPropertyName("firstSlice")] public string? FirstSlice { get; set; }
    [JsonPropertyName("risk")] public string? Risk { get; set; }
    [JsonPropertyName("riskReason")] public string? RiskReason { get; set; }
}
