using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Models;

public sealed class NvidiaNipPreview
{
    [JsonPropertyName("actionId")] public string? ActionId { get; set; }
    [JsonPropertyName("profileId")] public string? ProfileId { get; set; }
    [JsonPropertyName("dryRun")] public bool DryRun { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("executionMode")] public string? ExecutionMode { get; set; }
    [JsonPropertyName("profile")] public NvidiaNipProfile? Profile { get; set; }
    [JsonPropertyName("hardwareGate")] public NvidiaHardwareGate? HardwareGate { get; set; }
    [JsonPropertyName("commands")] public NvidiaNipCommands? Commands { get; set; }
    [JsonPropertyName("summary")] public NvidiaNipSummary? Summary { get; set; }
    [JsonPropertyName("warnings")] public List<IssueModel>? Warnings { get; set; }
    [JsonPropertyName("errors")] public List<IssueModel>? Errors { get; set; }
}

public sealed class NvidiaNipProfile
{
    [JsonPropertyName("profileId")] public string? ProfileId { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("profileNameInNip")] public string? ProfileNameInNip { get; set; }
    [JsonPropertyName("sourceFile")] public string? SourceFile { get; set; }
    [JsonPropertyName("settingCount")] public int SettingCount { get; set; }
    [JsonPropertyName("supportedHardware")] public List<string>? SupportedHardware { get; set; }
    [JsonPropertyName("risk")] public string? Risk { get; set; }
}

public sealed class NvidiaHardwareGate
{
    [JsonPropertyName("source")] public string? Source { get; set; }
    [JsonPropertyName("nvidiaGpuPresent")] public bool NvidiaGpuPresent { get; set; }
    [JsonPropertyName("matchedGpuName")] public string? MatchedGpuName { get; set; }
    [JsonPropertyName("matchedGpus")] public List<NvidiaMatchedGpu>? MatchedGpus { get; set; }
}

public sealed class NvidiaMatchedGpu
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("vendor")] public string? Vendor { get; set; }
    [JsonPropertyName("pnpDeviceId")] public string? PnpDeviceId { get; set; }
    [JsonPropertyName("driverVersion")] public string? DriverVersion { get; set; }
}

public sealed class NvidiaNipCommands
{
    [JsonPropertyName("exportCurrentProfile")] public NvidiaNipCommand? ExportCurrentProfile { get; set; }
    [JsonPropertyName("importCandidateProfile")] public NvidiaNipCommand? ImportCandidateProfile { get; set; }
}

public sealed class NvidiaNipCommand
{
    [JsonPropertyName("operation")] public string? Operation { get; set; }
    [JsonPropertyName("toolId")] public string? ToolId { get; set; }
    [JsonPropertyName("executablePath")] public string? ExecutablePath { get; set; }
    [JsonPropertyName("arguments")] public List<string>? Arguments { get; set; }
    [JsonPropertyName("launchAllowedNow")] public bool LaunchAllowedNow { get; set; }
    [JsonPropertyName("processStarted")] public bool ProcessStarted { get; set; }
}

public sealed class NvidiaNipSummary
{
    [JsonPropertyName("willRunNvpi")] public bool WillRunNvpi { get; set; }
    [JsonPropertyName("willImportProfile")] public bool WillImportProfile { get; set; }
    [JsonPropertyName("willExportProfile")] public bool WillExportProfile { get; set; }
    [JsonPropertyName("willWriteState")] public bool WillWriteState { get; set; }
    [JsonPropertyName("autoApplyAllowed")] public bool AutoApplyAllowed { get; set; }
    [JsonPropertyName("exportBeforeImportRequired")] public bool ExportBeforeImportRequired { get; set; }
    [JsonPropertyName("rollbackManifestReady")] public bool RollbackManifestReady { get; set; }
    [JsonPropertyName("blockingGateCount")] public int BlockingGateCount { get; set; }
}
