using System;
using System.Collections.Generic;
using System.Linq;

namespace RooIndustries.OptimizationSuite.Models;

public sealed class OptimizerResult<T>
{
    public string Status { get; set; } = "";
    public bool Changed { get; set; }
    public bool RestoreAvailable { get; set; }
    public T? Data { get; set; }
    public List<IssueModel> Errors { get; set; } = new();
}

public sealed class CpuProcessIdentity
{
    public int ProcessId { get; set; }
    public string ExecutablePath { get; set; } = "";
    public string CreationTimeFileTimeUtc { get; set; } = "";
    public string DisplayName => System.IO.Path.GetFileName(ExecutablePath);
}

public sealed class CpuSetInfo
{
    public uint Id { get; set; }
    public int Group { get; set; }
    public int LogicalProcessorIndex { get; set; }
    public int CoreIndex { get; set; }
    public int LastLevelCacheIndex { get; set; }
    public int EfficiencyClass { get; set; }
    public bool Parked { get; set; }
    public bool Allocated { get; set; }
    public bool AllocatedToTargetProcess { get; set; }
    public bool Available => !Allocated || AllocatedToTargetProcess;
    public string Label => $"CPU {LogicalProcessorIndex}";
    public string Detail => $"Group {Group} · Core {CoreIndex}" + (Parked ? " · parked" : "") + (!Available ? " · reserved" : "");
}

public sealed class CpuSetCompatibility
{
    public bool Protected { get; set; }
    public List<string> Limits { get; set; } = new();
}

public sealed class CpuSetSnapshot
{
    public CpuProcessIdentity Identity { get; set; } = new();
    public uint[] CpuSetIds { get; set; } = Array.Empty<uint>();
    public List<CpuSetInfo> Topology { get; set; } = new();
    public CpuSetCompatibility Compatibility { get; set; } = new();
}

public sealed class CpuSetPlan
{
    public CpuProcessIdentity Identity { get; set; } = new();
    public uint[] OriginalCpuSetIds { get; set; } = Array.Empty<uint>();
    public uint[] DesiredCpuSetIds { get; set; } = Array.Empty<uint>();
    public List<CpuSetInfo> Topology { get; set; } = new();
    public string Describe(uint[] ids) => ids.Length == 0 ? "Windows default" : string.Join(", ", Topology.Where(cpu => ids.Contains(cpu.Id)).Select(cpu => $"G{cpu.Group}:CPU {cpu.LogicalProcessorIndex}"));
}

public sealed class CpuSetJournal
{
    public string Status { get; set; } = "";
    public CpuSetPlan Preview { get; set; } = new();
}

public sealed record CpuSetReview(CpuSetPlan Plan, string PreviewPath, string Hash, string JournalPath);

public sealed class BulkRemovalPlan
{
    public string QueueId { get; set; } = "";
    public List<BulkRemovalEntry> Entries { get; set; } = new();
}

public sealed class BulkRemovalEntry
{
    public System.Text.Json.JsonElement? Identity { get; set; }
    public string EntryId { get; set; } = "";
    public string AppId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public string SourceType { get; set; } = "";
    public string Executable { get; set; } = "";
    public string ArgumentMode { get; set; } = "";
    public string RawArguments { get; set; } = "";
    public string[] Arguments { get; set; } = Array.Empty<string>();
    public string CommandLine { get; set; } = "";
    public bool ReviewRequired { get; set; }
    public bool Protected { get; set; }
    public string ReviewLabel => Identity is { } identity && identity.TryGetProperty("kind", out var kind) && kind.GetString() == "appx" && identity.TryGetProperty("userSid", out var sid)
        ? DisplayName + " · " + (sid.GetString() == RooIndustries.Optimizer.OperationOwner.Current().UserSid ? "this Windows user" : sid.GetString()) : DisplayName;
    public string Command => CommandLine;
}

public sealed class BulkRemovalEntryState
{
    public string AppId { get; set; } = "";
    public string State { get; set; } = "pending";
    public bool RegistrationAbsent { get; set; }
    public bool LaunchUnconfirmed { get; set; }
    public string? Error { get; set; }
}

public sealed class BulkRemovalJournal
{
    public string Status { get; set; } = "";
    public BulkRemovalPlan Plan { get; set; } = new();
    public List<BulkRemovalEntryState> Entries { get; set; } = new();
}

public sealed record BulkRemovalReview(BulkRemovalPlan Plan, string PreviewPath, string Hash, string JournalPath);
public sealed record BulkRemovalSession(BulkRemovalReview Review, BulkRemovalJournal State);

public sealed class RemovalCleanupPlan
{
    public string AppId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public bool RequiresReview { get; set; }
    public string RollbackPath { get; set; } = "";
    public List<LeftoverItem> Items { get; set; } = new();
}

public sealed class FileCleanupResult
{
    public FileCleanupSummary Summary { get; set; } = new();
}

public sealed class FileCleanupSummary
{
    public int DeletedCount { get; set; }
    public bool RestoreReady { get; set; }
}

public sealed record RemovalCleanupReview(RemovalCleanupPlan Plan, string Path, string Hash, string QueueJournalPath);
