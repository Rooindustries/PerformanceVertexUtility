#nullable enable
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public static class FirmwareWriteOutcomes
{
    public const string Unchanged = "unchanged";
    public const string Rejected = "rejected";
    public const string Protected = "protected";
}
public sealed record FirmwareWriteTestBoard(
    [property: JsonRequired] string Board, [property: JsonRequired] string Bios, [property: JsonRequired] string Crc,
    [property: JsonRequired] int Tested, [property: JsonRequired] Dictionary<string, string> NotApplied);
public sealed record FirmwareWriteTests([property: JsonRequired] int SchemaVersion, [property: JsonRequired] FirmwareWriteTestBoard[] Boards)
{
    public static FirmwareWriteTests Read(string path)
    {
        var tests = OperationFiles.Read<FirmwareWriteTests>(path);
        if (tests.SchemaVersion != 1) throw new InvalidDataException("The BIOS write test results use an unsupported version.");
        foreach (var board in tests.Boards)
            if (string.IsNullOrWhiteSpace(board.Board) || string.IsNullOrWhiteSpace(board.Bios) || board.Crc.Length != 8 || board.Tested < board.NotApplied.Count
                || board.NotApplied.Values.Any(outcome => outcome is not (FirmwareWriteOutcomes.Unchanged or FirmwareWriteOutcomes.Rejected or FirmwareWriteOutcomes.Protected)))
                throw new InvalidDataException("The BIOS write test results are invalid.");
        return tests;
    }
    public FirmwareWriteTestBoard? Find(FirmwareIdentity identity, string crc) => Boards.FirstOrDefault(board =>
        board.Board == identity.Board && board.Bios == identity.Bios && string.Equals(board.Crc, crc, StringComparison.OrdinalIgnoreCase));
}
