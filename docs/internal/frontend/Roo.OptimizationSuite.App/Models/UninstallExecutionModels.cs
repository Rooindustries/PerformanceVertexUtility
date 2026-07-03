using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Models;

public sealed class UninstallCleanupExecutionPlan
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("planId")] public string? PlanId { get; set; }
    [JsonPropertyName("appId")] public string? AppId { get; set; }
    [JsonPropertyName("displayName")] public string? DisplayName { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("executionMode")] public string? ExecutionMode { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("gates")] public List<ExecutionGate>? Gates { get; set; }
    [JsonPropertyName("summary")] public UninstallExecutionSummary? Summary { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class ExecutionGate
{
    [JsonPropertyName("gateId")] public string? GateId { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("required")] public bool Required { get; set; }
    [JsonPropertyName("satisfied")] public bool Satisfied { get; set; }
    [JsonPropertyName("blocking")] public bool Blocking { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
}

public sealed class UninstallExecutionSummary
{
    [JsonPropertyName("commandPreviewCount")] public int CommandPreviewCount { get; set; }
    [JsonPropertyName("executionAllowedCommandCount")] public int ExecutionAllowedCommandCount { get; set; }
    [JsonPropertyName("cleanupItemCount")] public int CleanupItemCount { get; set; }
    [JsonPropertyName("protectedSelectedCount")] public int ProtectedSelectedCount { get; set; }
    [JsonPropertyName("blockingGateCount")] public int BlockingGateCount { get; set; }
    [JsonPropertyName("willRunUninstallers")] public bool WillRunUninstallers { get; set; }
    [JsonPropertyName("willDeleteLeftovers")] public bool WillDeleteLeftovers { get; set; }
    [JsonPropertyName("willEditRegistry")] public bool WillEditRegistry { get; set; }
    [JsonPropertyName("willEditServices")] public bool WillEditServices { get; set; }
    [JsonPropertyName("willEditScheduledTasks")] public bool WillEditScheduledTasks { get; set; }
    [JsonPropertyName("dryRunWritesState")] public bool DryRunWritesState { get; set; }
    [JsonPropertyName("executionReady")] public bool ExecutionReady { get; set; }
    [JsonPropertyName("disposableFixtureExecutionReady")] public bool DisposableFixtureExecutionReady { get; set; }
    [JsonPropertyName("allowlistedOfficialRunnerReady")] public bool AllowlistedOfficialRunnerReady { get; set; }
}
