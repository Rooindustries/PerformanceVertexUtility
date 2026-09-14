using System.Collections.Generic;

namespace Roo.OptimizationSuite.Models;

public sealed class DriverHardwareSummary
{
    public string? CapturedAtUtc { get; set; }
    public MachineInfo? Machine { get; set; }
    public CpuInfo? Cpu { get; set; }
    public MemoryInfo? Memory { get; set; }
    public List<GpuInfo>? Gpus { get; set; }
    public List<NetworkAdapterInfo>? NetworkAdapters { get; set; }
}

public sealed class MachineInfo
{
    public string? Manufacturer { get; set; }
    public string? Model { get; set; }
    public string? SystemType { get; set; }
    public string? OsCaption { get; set; }
    public string? OsBuild { get; set; }
}

public sealed class CpuInfo
{
    public string? Name { get; set; }
    public string? Manufacturer { get; set; }
    public int Cores { get; set; }
    public int LogicalProcessors { get; set; }
}

public sealed class MemoryInfo
{
    public long TotalPhysicalBytes { get; set; }
    public int RamClassGb { get; set; }
}

public sealed class GpuInfo
{
    public string? Name { get; set; }
    public string? Vendor { get; set; }
    public string? PnpDeviceId { get; set; }
    public long AdapterRamBytes { get; set; }
    public string? DriverVersion { get; set; }
    public string? DriverDate { get; set; }
}

public sealed class NetworkAdapterInfo
{
    public string? Name { get; set; }
    public string? Vendor { get; set; }
    public string? DriverVersion { get; set; }
    public bool Protected { get; set; }
    public string? Reason { get; set; }
}

public sealed class DriverRecommendationCatalog
{
    public string? CatalogVersion { get; set; }
    public List<DriverRecommendation>? Recommendations { get; set; }
    public DriverManualInstallGate? ManualInstallGate { get; set; }
}

public sealed class DriverRecommendation
{
    public string? DriverId { get; set; }
    public string? Vendor { get; set; }
    public string? Version { get; set; }
    public List<string>? HardwareMatches { get; set; }
    public List<string>? GameTags { get; set; }
    public string? Stability { get; set; }
    public string? Notes { get; set; }
    public bool ManualInstallRequired { get; set; }
    public string? Risk { get; set; }

    public string GameTagsText => GameTags is { Count: > 0 } tags ? string.Join(" / ", tags) : "-";
}

public sealed class DriverManualInstallGate
{
    public bool RequiresHardwareMatch { get; set; }
    public bool RequiresUserDownloadOrLocalPackage { get; set; }
    public bool RequiresRestorePoint { get; set; }
    public bool DduAutomationAllowed { get; set; }
    public bool NvcleanstallAutomationAllowed { get; set; }
    public List<string>? Warnings { get; set; }
}

public sealed class NvidiaProfileCatalog
{
    public string? CapturedAtUtc { get; set; }
    public List<NvidiaProfileEntry>? Entries { get; set; }
    public NvidiaProfilePolicy? Policy { get; set; }
}

public sealed class NvidiaProfileEntry
{
    public string? ProfileId { get; set; }
    public string? Name { get; set; }
    public string? Vendor { get; set; }
    public string? SourceFile { get; set; }
    public string? SourceTool { get; set; }
    public string? Status { get; set; }
    public List<string>? SupportedHardware { get; set; }
    public List<string>? GameTags { get; set; }
    public bool ManualApplyRequired { get; set; }
    public string? BenchmarkStatus { get; set; }
    public string? Risk { get; set; }
    public string? Notes { get; set; }

    public string GameTagsText => GameTags is { Count: > 0 } tags ? string.Join(" / ", tags) : "-";
    public string StatusText => Status switch
    {
        "seed-profile" => "Ready to review",
        "draft" => "Draft",
        "approved" => "Approved",
        "blocked" => "Locked",
        _ => string.IsNullOrWhiteSpace(Status) ? "Ready to review" : Status
    };
}

public sealed class NvidiaProfilePolicy
{
    public bool AutoApplyAllowed { get; set; }
    public bool ManualApplyRequiresNvidiaGpu { get; set; }
    public bool ManualApplyRequiresExportFirst { get; set; }
    public bool BenchmarkBeforeRecommend { get; set; }
    public int TopProfilesToExposeAfterTesting { get; set; }
}
