#nullable enable
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record ApiError(string Api, string CodeKind, long Code, string Access, string Message);

public sealed class ControlReadException(ApiError error) : Exception(error.Message)
{
    public ApiError Error { get; } = error;
}

public static class ProcessFailures
{
    public static bool Denied(Exception error) => error switch
    {
        System.ComponentModel.Win32Exception win32 => win32.NativeErrorCode == 5,
        UnauthorizedAccessException => true,
        InvalidDataException { InnerException: ControlReadException read } => read.Error is { CodeKind: "win32", Code: 5 } or { CodeKind: "ntstatus", Code: 0xC0000022 },
        ProcessTarget.NtFailure native => native.Code == 0xC0000022,
        _ => false,
    };
}
public sealed class ProcessEndedException() : InvalidOperationException("The target process has exited.");

public sealed record ControlRead([property: JsonRequired] bool Known, [property: JsonRequired] JsonElement? Value, ApiError? Error)
{
    public static ControlRead From<T>(T value) => new(true, JsonSerializer.SerializeToElement(value, OperationFiles.Json), null);
    public static ControlRead Failed(ApiError error) => new(false, null, error);

    public JsonElement Require()
    {
        if (!Known || Value is null || Value.Value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined || Error is not null)
            throw new InvalidDataException(Error?.Message ?? "The original control state is unknown.", Error is null ? null : new ControlReadException(Error));
        return Value.Value;
    }
}

public sealed record RunningProcess([property: JsonRequired] int ProcessId, [property: JsonRequired] string CreationTimeFileTimeUtc, [property: JsonRequired] string ExecutablePath)
{
    public void Verify(RunningProcess actual)
    {
        if (ProcessId <= 0 || ProcessId != actual.ProcessId || CreationTimeFileTimeUtc != actual.CreationTimeFileTimeUtc ||
            string.IsNullOrWhiteSpace(ExecutablePath) || !string.Equals(ExecutablePath, actual.ExecutablePath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The running process identity changed. A process ID alone cannot authorize this operation.");
    }
}

public sealed record AffinityState([property: JsonRequired] ushort Group, [property: JsonRequired] string Mask);

public sealed record PowerThrottling([property: JsonRequired] uint ControlMask, [property: JsonRequired] uint StateMask)
{
    [JsonIgnore] public string ExecutionMode => (ControlMask & 1) == 0 ? "systemManaged" : (StateMask & 1) != 0 ? "eco" : "high";
    public PowerThrottling WithExecutionMode(string mode) => mode switch
    {
        "systemManaged" => new(ControlMask & ~1u, StateMask & ~1u),
        "eco" => new(ControlMask | 1u, StateMask | 1u),
        "high" => new(ControlMask | 1u, StateMask & ~1u),
        _ => throw new InvalidDataException("Unknown execution QoS mode."),
    };
}

public sealed record ProcessControlSnapshot(RunningProcess Identity, ControlRead Protection,
    IReadOnlyList<LogicalCpu> Topology, IReadOnlyDictionary<string, ControlRead> Controls, IReadOnlyDictionary<string, string>? Blocked = null);

public sealed record ProcessControlPreview
{
    public required int SchemaVersion { get; init; }
    public required string OperationId { get; init; }
    public required OperationOwner Owner { get; init; }
    public required RunningProcess Identity { get; init; }
    public required Dictionary<string, ControlRead> Original { get; init; }
    public required Dictionary<string, JsonElement> Desired { get; init; }
    public required string TopologyHash { get; init; }
    public Dictionary<string, string>? Blocked { get; init; }
}

public sealed class ProcessControlBlockedException(IEnumerable<string> controls)
    : UnauthorizedAccessException("Windows doesn't let other apps change " + string.Join(", ", controls.Select(ProcessControlBlockedException.Label)) +
        " for this app while it runs. If it's a game with anti-cheat, set it up on the Games tab before you start the game.")
{
    public static string Label(string name) => name switch
    {
        "cpuPriority" => "CPU priority", "affinity" => "CPU cores", "cpuSets" => "preferred CPU cores", "ioPriority" => "I/O priority", "gpuPriority" => "GPU priority",
        "memoryPriority" => "memory priority", "executionQoS" => "power mode", "priorityBoost" => "priority boost", _ => name,
    };
}

public sealed class ControlChange
{
    public required string Name { get; init; }
    public required JsonElement Original { get; init; }
    public required JsonElement Desired { get; init; }
    public required string Status { get; set; }
    public JsonElement? Observed { get; set; }
    public string? Error { get; set; }
    public string? ErrorKind { get; set; }
}

public sealed class ProcessControlJournal
{
    public required int SchemaVersion { get; init; }
    public required ProcessControlPreview Preview { get; init; }
    public required string ReviewHash { get; init; }
    public required string PreviewPath { get; init; }
    public required string Status { get; set; }
    public required List<ControlChange> Changes { get; init; }
    public required DateTime UpdatedAtUtc { get; set; }
}
