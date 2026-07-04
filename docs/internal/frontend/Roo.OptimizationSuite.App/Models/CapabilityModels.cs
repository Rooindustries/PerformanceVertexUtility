using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Models;

public sealed class CapabilityRegistryResponse
{
    [JsonPropertyName("capabilities")]
    public List<RegistryCapability>? Capabilities { get; set; }

    [JsonPropertyName("summary")]
    public CapabilityRegistrySummary? Summary { get; set; }
}

public sealed class CapabilityRegistrySummary
{
    [JsonPropertyName("totalCapabilities")]
    public int TotalCapabilities { get; set; }

    [JsonPropertyName("byFamily")]
    public Dictionary<string, int>? ByFamily { get; set; }

    [JsonPropertyName("byApplyStatus")]
    public Dictionary<string, int>? ByApplyStatus { get; set; }

    [JsonPropertyName("availableCount")]
    public int AvailableCount { get; set; }

    [JsonPropertyName("unavailableCount")]
    public int UnavailableCount { get; set; }
}

public sealed class RegistryCapability
{
    [JsonPropertyName("capabilityId")]
    public string? CapabilityId { get; set; }

    [JsonPropertyName("family")]
    public string? Family { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("frontendLabel")]
    public string? FrontendLabel { get; set; }

    [JsonPropertyName("frontendTab")]
    public string? FrontendTab { get; set; }

    [JsonPropertyName("riskLevel")]
    public string? RiskLevel { get; set; }

    [JsonPropertyName("approvalRequired")]
    public bool ApprovalRequired { get; set; }

    [JsonPropertyName("apply")]
    public RegistryActionStatus? Apply { get; set; }

    [JsonPropertyName("restore")]
    public RegistryActionStatus? Restore { get; set; }

    [JsonPropertyName("resolvedAvailability")]
    public RegistryAvailability? ResolvedAvailability { get; set; }

    [JsonPropertyName("unavailableReason")]
    public string? UnavailableReason { get; set; }
}

public sealed class RegistryActionStatus
{
    [JsonPropertyName("status")]
    public string? Status { get; set; }

    [JsonPropertyName("notes")]
    public string? Notes { get; set; }
}

public sealed class RegistryAvailability
{
    [JsonPropertyName("available")]
    public bool Available { get; set; }

    [JsonPropertyName("unavailableReason")]
    public string? UnavailableReason { get; set; }
}

public sealed class CapabilityRouterResponse
{
    [JsonPropertyName("actionId")]
    public string? ActionId { get; set; }

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; }

    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; set; }

    [JsonPropertyName("startedAtUtc")]
    public string? StartedAtUtc { get; set; }

    [JsonPropertyName("completedAtUtc")]
    public string? CompletedAtUtc { get; set; }

    [JsonPropertyName("capabilityId")]
    public string? CapabilityId { get; set; }

    [JsonPropertyName("family")]
    public string? Family { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("frontendLabel")]
    public string? FrontendLabel { get; set; }

    [JsonPropertyName("frontendTab")]
    public string? FrontendTab { get; set; }

    [JsonPropertyName("action")]
    public string? Action { get; set; }

    [JsonPropertyName("dryRun")]
    public bool DryRun { get; set; }

    [JsonPropertyName("status")]
    public string? Status { get; set; }

    [JsonPropertyName("requiresApproval")]
    public bool RequiresApproval { get; set; }

    [JsonPropertyName("approvalSatisfied")]
    public bool ApprovalSatisfied { get; set; }

    [JsonPropertyName("machineAvailable")]
    public bool MachineAvailable { get; set; }

    [JsonPropertyName("unavailableReason")]
    public string? UnavailableReason { get; set; }

    [JsonPropertyName("applyStatus")]
    public string? ApplyStatus { get; set; }

    [JsonPropertyName("restoreStatus")]
    public string? RestoreStatus { get; set; }

    [JsonPropertyName("routedScript")]
    public string? RoutedScript { get; set; }

    [JsonPropertyName("wouldChange")]
    public bool WouldChange { get; set; }

    [JsonPropertyName("changed")]
    public bool Changed { get; set; }

    [JsonPropertyName("restoreAvailable")]
    public bool RestoreAvailable { get; set; }

    [JsonPropertyName("evidence")]
    public JsonElement Evidence { get; set; }

    [JsonPropertyName("errors")]
    public List<CapabilityRouterError>? Errors { get; set; }

    [JsonPropertyName("nextRequiredStep")]
    public string? NextRequiredStep { get; set; }
}

public sealed class CapabilityRouterError
{
    [JsonPropertyName("code")]
    public string? Code { get; set; }

    [JsonPropertyName("message")]
    public string? Message { get; set; }

    [JsonPropertyName("blocking")]
    public bool Blocking { get; set; }
}

public sealed record CapabilityRow(
    string CapabilityId,
    string Label,
    string Family,
    string Page,
    string RiskLevel,
    bool MachineAvailable,
    string ApplyStatusText,
    string ApplyState,
    string ApprovalText,
    string RestoreText,
    string ReasonOrNextStep,
    string DotState)
{
    public string StatusLine => $"{ApplyStatusText} · {ApprovalText} · {RestoreText}";
}
