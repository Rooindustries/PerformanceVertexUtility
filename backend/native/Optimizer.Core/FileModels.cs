#nullable enable
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record FileIdentity([property: JsonRequired] ulong Volume, [property: JsonRequired] string Id);
public sealed record FileStreamDigest(string Name, long Length, string Sha256);

public sealed record FileSnapshot
{
    public required string Path { get; init; }
    public required string CanonicalPath { get; init; }
    public required FileIdentity Identity { get; init; }
    public required bool Directory { get; init; }
    public required uint Attributes { get; init; }
    public required uint Links { get; init; }
    public required long Length { get; init; }
    public required long CreationTime { get; init; }
    public required long LastWriteTime { get; init; }
    public required long LastAccessTime { get; init; }
    public required byte[] Security { get; init; }
    public required uint SecurityCoverage { get; init; }
    public required FileStreamDigest[] Streams { get; init; }

    public bool SameObjectAndContent(FileSnapshot current) => Identity == current.Identity && SameRestorableData(current);
    public bool SameRestorableData(FileSnapshot current) => Differences(current).Length == 0;
    public string[] Differences(FileSnapshot current)
    {
        var changed = new List<string>();
        if (Directory != current.Directory) changed.Add("type");
        if (Attributes != current.Attributes) changed.Add("attributes");
        if (Length != current.Length) changed.Add("length");
        if (CreationTime != current.CreationTime) changed.Add("creation time");
        if (LastWriteTime != current.LastWriteTime) changed.Add("last-write time");
        if (SecurityCoverage != current.SecurityCoverage || !Security.SequenceEqual(current.Security)) changed.Add("permissions");
        if (!Streams.OrderBy(stream => stream.Name, StringComparer.OrdinalIgnoreCase).SequenceEqual(current.Streams.OrderBy(stream => stream.Name, StringComparer.OrdinalIgnoreCase))) changed.Add("streams");
        return changed.ToArray();
    }
}

public sealed record FileCleanupPreview
{
    public required int SchemaVersion { get; init; }
    public required string OperationId { get; init; }
    public required OperationOwner Owner { get; init; }
    public required string AppId { get; init; }
    public required string ProviderIdentityHash { get; init; }
    public required string[] Roots { get; init; }
    public required FileSnapshot[] Files { get; init; }
}

public sealed class FileBackupEntry
{
    public required FileSnapshot Original { get; init; }
    public required string BackupPath { get; init; }
    public bool Moved { get; set; }
    public string? BackupHash { get; set; }
    public required string Status { get; set; }
    public string? Error { get; set; }
    public string? RestoreStagingPath { get; set; }
    public FileIdentity? RestoredIdentity { get; set; }
    public bool DirectoryMetadataRestored { get; set; }
    public string? LeftAsChanged { get; set; }
}

public sealed class FileCleanupJournal
{
    public required int SchemaVersion { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required FileCleanupPreview Preview { get; init; }
    public required List<FileBackupEntry> Entries { get; init; }
    public required string Status { get; set; }
    public required DateTime UpdatedAtUtc { get; set; }
}
