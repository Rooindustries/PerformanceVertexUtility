#nullable enable
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public static class FirmwareWriteOutcomes
{
    public const string Unchanged = "unchanged";
    public const string Rejected = "rejected";
    public const string Protected = "protected";
    public const string SideEffects = "side-effects";
    public const string Risky = "risky";
    public static readonly string[] All = [Unchanged, Rejected, Protected, SideEffects, Risky];
}
public sealed record FirmwareWriteTestResult([property: JsonRequired] string Name, [property: JsonRequired] string Outcome, string[]? Affects = null, int AffectedCount = 0);
public sealed record FirmwareWriteTestBoard(
    [property: JsonRequired] string Board, [property: JsonRequired] string Bios, [property: JsonRequired] string Crc,
    [property: JsonRequired] int Tested, [property: JsonRequired] Dictionary<string, FirmwareWriteTestResult> Experimental);
public sealed record FirmwareWriteTestMatch(bool SameBoard, string Source, IReadOnlyDictionary<string, FirmwareWriteTestResult> ById, IReadOnlyDictionary<string, FirmwareWriteTestResult> ByName,
    IReadOnlyDictionary<string, FirmwareWriteTestResult>? ByNamePattern = null);
public sealed record FirmwareWriteTests([property: JsonRequired] int SchemaVersion, [property: JsonRequired] FirmwareWriteTestBoard[] Boards)
{
    public static FirmwareWriteTests Read(string path)
    {
        var tests = OperationFiles.Read<FirmwareWriteTests>(path);
        if (tests.SchemaVersion != 2) throw new InvalidDataException("The BIOS write test results use an unsupported version.");
        foreach (var board in tests.Boards)
            if (string.IsNullOrWhiteSpace(board.Board) || string.IsNullOrWhiteSpace(board.Bios) || board.Crc.Length != 8
                || board.Experimental.Values.Any(result => string.IsNullOrWhiteSpace(result.Name) || !FirmwareWriteOutcomes.All.Contains(result.Outcome)))
                throw new InvalidDataException("The BIOS write test results are invalid.");
        return tests;
    }
    public FirmwareWriteTestMatch For(FirmwareIdentity identity)
    {
        var same = Boards.FirstOrDefault(board => board.Board == identity.Board && board.Bios == identity.Bios);
        if (same is not null)
            return new(true, same.Board, same.Experimental, new Dictionary<string, FirmwareWriteTestResult>(),
                same.Experimental.Values.Where(result => FirmwareScript.NamePattern(result.Name) != result.Name.Trim())
                    .GroupBy(result => FirmwareScript.NamePattern(result.Name), StringComparer.Ordinal).Where(group => group.Count() == 1)
                    .ToDictionary(group => group.Key, group => group.Single(), StringComparer.Ordinal));
        var byName = new Dictionary<string, FirmwareWriteTestResult>(StringComparer.OrdinalIgnoreCase);
        foreach (var result in Boards.SelectMany(board => board.Experimental.Values).Where(result => result.Outcome != FirmwareWriteOutcomes.Protected))
            byName.TryAdd(result.Name.Trim(), result);
        return new(false, string.Join(" and ", Boards.Select(board => board.Board)), new Dictionary<string, FirmwareWriteTestResult>(), byName);
    }
}
