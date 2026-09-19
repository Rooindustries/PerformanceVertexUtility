#nullable enable
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record LogicalCpu(uint Id, ushort Group, byte Index, byte Core, byte Cache, byte Numa,
    byte Efficiency, bool Parked, bool Allocated, bool AllocatedToTarget)
{
    public bool Available => !Allocated || AllocatedToTarget;
    public string Label => $"Group {Group}, CPU {Index}";
}

public sealed record CpuCoordinate([property: JsonRequired] ushort Group, [property: JsonRequired] byte Index);

public sealed record CpuSelection
{
    public required string Kind { get; init; }
    public string? TopologyHash { get; init; }
    public CpuCoordinate[]? Processors { get; init; }
    public ushort? Group { get; init; }
    public byte? Index { get; init; }
    public bool OneThreadPerCore { get; init; }

    public static string Fingerprint(IReadOnlyList<LogicalCpu> topology)
    {
        ValidateTopology(topology);
        var text = string.Join(";", topology.OrderBy(cpu => cpu.Group).ThenBy(cpu => cpu.Index)
            .Select(cpu => FormattableString.Invariant($"{cpu.Group}:{cpu.Index}:{cpu.Core}:{cpu.Cache}:{cpu.Numa}:{cpu.Efficiency}")));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    public uint[] Resolve(IReadOnlyList<LogicalCpu> topology)
    {
        ValidateTopology(topology);
        if (Kind == "windowsDefault")
        {
            if (Processors is { Length: > 0 } || Group is not null || Index is not null || OneThreadPerCore)
                throw new InvalidDataException("Windows default cannot be combined with a CPU selector.");
            return [];
        }
        if (string.IsNullOrWhiteSpace(TopologyHash) || !string.Equals(TopologyHash, Fingerprint(topology), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("CPU topology changed or was not reviewed. Review this saved selection on the current PC.");
        if (Kind != "logical" && Processors is { Length: > 0 })
            throw new InvalidDataException("Explicit processors cannot be combined with another CPU selector.");
        if (Kind is not ("core" or "cache" or "numa") && (Group is not null || Index is not null))
            throw new InvalidDataException("Group and index are valid only for a core, cache or NUMA selector.");

        IEnumerable<LogicalCpu> selected;
        switch (Kind)
        {
            case "all": selected = topology; break;
            case "logical":
                if (Processors is not { Length: > 0 } || Processors.Distinct().Count() != Processors.Length)
                    throw new InvalidDataException("Select distinct logical processors.");
                var coordinates = Processors.ToHashSet();
                selected = topology.Where(cpu => coordinates.Contains(new CpuCoordinate(cpu.Group, cpu.Index)));
                if (selected.Count() != coordinates.Count)
                    throw new InvalidDataException("A saved logical processor is missing.");
                break;
            case "performance":
            case "efficiency":
                if (topology.Select(cpu => cpu.Efficiency).Distinct().Count() < 2)
                    throw new InvalidDataException("Windows does not report distinct efficiency classes on this CPU.");
                var efficiency = Kind == "performance" ? topology.Max(cpu => cpu.Efficiency) : topology.Min(cpu => cpu.Efficiency);
                selected = topology.Where(cpu => cpu.Efficiency == efficiency);
                break;
            case "core":
            case "cache":
            case "numa":
                if (Group is null || Index is null) throw new InvalidDataException("Select a processor group and topology index.");
                selected = topology.Where(cpu => cpu.Group == Group &&
                    (Kind == "core" ? cpu.Core : Kind == "cache" ? cpu.Cache : cpu.Numa) == Index);
                break;
            default: throw new InvalidDataException("Unknown CPU selection: " + Kind);
        }
        var resolved = selected.OrderBy(cpu => cpu.Group).ThenBy(cpu => cpu.Index).ToArray();
        if (resolved.Length == 0) throw new InvalidDataException("This CPU selection resolves to no processors.");
        if (resolved.Any(cpu => !cpu.Available)) throw new InvalidDataException("A selected CPU Set is reserved for another process.");
        if (OneThreadPerCore) resolved = resolved.GroupBy(cpu => (cpu.Group, cpu.Core)).Select(core => core.First()).ToArray();
        return resolved.Select(cpu => cpu.Id).Order().ToArray();
    }

    private static void ValidateTopology(IReadOnlyList<LogicalCpu> topology)
    {
        if (topology.Count == 0 || topology.Select(cpu => cpu.Id).Distinct().Count() != topology.Count ||
            topology.Select(cpu => (cpu.Group, cpu.Index)).Distinct().Count() != topology.Count || topology.Any(cpu => cpu.Index >= 64))
            throw new InvalidDataException("CPU topology is empty or contains invalid or duplicate processors.");
    }
}
