using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Models;

public sealed class GameTuneSessionStatus
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("sessionStatus")] public string? SessionStatus { get; set; }
    [JsonPropertyName("rawSessionStatus")] public string? RawSessionStatus { get; set; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("profileId")] public string? ProfileId { get; set; }
    [JsonPropertyName("targetGameProcessName")] public string? TargetGameProcessName { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("restorable")] public bool Restorable { get; set; }
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("completed")] public bool Completed { get; set; }
    [JsonPropertyName("failed")] public bool Failed { get; set; }
    [JsonPropertyName("summary")] public SessionStatusSummary? Summary { get; set; }
    [JsonPropertyName("changedItems")] public List<SessionChangedItem>? ChangedItems { get; set; }
    [JsonPropertyName("skippedItems")] public List<SessionChangedItem>? SkippedItems { get; set; }
    [JsonPropertyName("restoredItems")] public List<SessionChangedItem>? RestoredItems { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class GameTuneRestorePreview
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("sessionStatus")] public string? SessionStatus { get; set; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("restorable")] public bool Restorable { get; set; }
    [JsonPropertyName("preview")] public List<ProcessPreviewRow>? Preview { get; set; }
    [JsonPropertyName("backup")] public SessionBackup? Backup { get; set; }
    [JsonPropertyName("result")] public SessionResult? Result { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class ProcessGovernorSessionStatus
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("sessionStatus")] public string? SessionStatus { get; set; }
    [JsonPropertyName("rawSessionStatus")] public string? RawSessionStatus { get; set; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("profileId")] public string? ProfileId { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("restorable")] public bool Restorable { get; set; }
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("completed")] public bool Completed { get; set; }
    [JsonPropertyName("failed")] public bool Failed { get; set; }
    [JsonPropertyName("summary")] public SessionStatusSummary? Summary { get; set; }
    [JsonPropertyName("changedItems")] public List<SessionChangedItem>? ChangedItems { get; set; }
    [JsonPropertyName("skippedItems")] public List<SessionChangedItem>? SkippedItems { get; set; }
    [JsonPropertyName("restoredItems")] public List<SessionChangedItem>? RestoredItems { get; set; }
    [JsonPropertyName("activeRestraints")] public List<ActiveRestraint>? ActiveRestraints { get; set; }
    [JsonPropertyName("runtimeEvidence")] public RuntimeEvidence? RuntimeEvidence { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class SessionStatusSummary
{
    [JsonPropertyName("changedItemCount")] public int ChangedItemCount { get; set; }
    [JsonPropertyName("skippedItemCount")] public int SkippedItemCount { get; set; }
    [JsonPropertyName("restoredItemCount")] public int RestoredItemCount { get; set; }
    [JsonPropertyName("activeRestraintCount")] public int ActiveRestraintCount { get; set; }
    [JsonPropertyName("pollCount")] public int PollCount { get; set; }
}

public sealed class SessionChangedItem
{
    [JsonPropertyName("processId")] public int ProcessId { get; set; }
    [JsonPropertyName("processName")] public string? ProcessName { get; set; }
    [JsonPropertyName("displayName")] public string? DisplayName { get; set; }
    [JsonPropertyName("originalPriorityClass")] public string? OriginalPriorityClass { get; set; }
    [JsonPropertyName("appliedPriorityClass")] public string? AppliedPriorityClass { get; set; }
    [JsonPropertyName("restoredPriorityClass")] public string? RestoredPriorityClass { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
}

public sealed class ActiveRestraint
{
    [JsonPropertyName("processId")] public int ProcessId { get; set; }
    [JsonPropertyName("processName")] public string? ProcessName { get; set; }
    [JsonPropertyName("ruleId")] public string? RuleId { get; set; }
}

public sealed class RuntimeEvidence
{
    [JsonPropertyName("runtimeKind")] public string? RuntimeKind { get; set; }
    [JsonPropertyName("productionRuntimeCapable")] public bool ProductionRuntimeCapable { get; set; }
    [JsonPropertyName("confirmedApplyAvailable")] public bool ConfirmedApplyAvailable { get; set; }
    [JsonPropertyName("dryRunWritesState")] public bool DryRunWritesState { get; set; }
    [JsonPropertyName("confirmedSessionWritesState")] public bool ConfirmedSessionWritesState { get; set; }
    [JsonPropertyName("stateBacked")] public bool StateBacked { get; set; }
    [JsonPropertyName("restoreContractAvailable")] public bool RestoreContractAvailable { get; set; }
    [JsonPropertyName("boundedSession")] public bool BoundedSession { get; set; }
    [JsonPropertyName("frontendProcessRequired")] public bool FrontendProcessRequired { get; set; }
    [JsonPropertyName("supportedControls")] public List<string>? SupportedControls { get; set; }
}

public sealed class SessionBackup
{
    [JsonPropertyName("backupId")] public string? BackupId { get; set; }
    [JsonPropertyName("scope")] public string? Scope { get; set; }
    [JsonPropertyName("rollbackActionId")] public string? RollbackActionId { get; set; }
    [JsonPropertyName("rollbackSupported")] public bool RollbackSupported { get; set; }
}

public sealed class SessionResult
{
    [JsonPropertyName("resultId")] public string? ResultId { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("summary")] public string? Summary { get; set; }
}
