#nullable enable
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text;

namespace Roo.Optimizer;

public sealed record RegistryAddress([property: JsonRequired] string Hive, [property: JsonRequired] string View,
    [property: JsonRequired] string KeyPath, [property: JsonRequired] string Kind, [property: JsonRequired] string? ValueName)
{
    private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
    internal static bool SerializableName(string? text)
    {
        if (text is null || text.Contains('\0')) return false;
        try { StrictUtf8.GetByteCount(text); return true; }
        catch (EncoderFallbackException) { return false; }
    }

    public void Validate()
    {
        if (Hive is not ("CurrentUser" or "LocalMachine") || View is not ("Registry32" or "Registry64") ||
            Kind is not ("key" or "value") || (Kind == "value" && ValueName is null) || (Kind == "key" && ValueName is not null))
            throw new InvalidDataException("Registry hive, view, target kind or value identity is incomplete.");
        if (string.IsNullOrWhiteSpace(KeyPath) || !KeyPath.StartsWith("Software\\", StringComparison.OrdinalIgnoreCase) ||
            KeyPath.Split('\\').Any(part => part is "" or "." or "..") || KeyPath.Contains('/') || !SerializableName(KeyPath) || ValueName is not null && !SerializableName(ValueName))
            throw new InvalidDataException("Registry cleanup requires an explicit Software subkey without relative path components.");
    }

    public void RequireDeletionScope()
    {
        Validate();
        if (Kind != "key") return;
        string[] protectedRoots = ["Software", "Software\\Microsoft", "Software\\Classes", "Software\\Microsoft\\Windows",
            "Software\\Microsoft\\Windows\\CurrentVersion", "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",
            "Software\\Classes\\CLSID", "Software\\Classes\\Interface", "Software\\Classes\\TypeLib", "Software\\RooOptimizationSuite"];
        if (protectedRoots.Contains(KeyPath, StringComparer.OrdinalIgnoreCase))
            throw new InvalidDataException("A shared registry container cannot be deleted as an app leftover.");
    }
}

public sealed record RegistryValueData([property: JsonRequired] string Name, [property: JsonRequired] uint Type, [property: JsonRequired] byte[] Bytes)
{
    [JsonIgnore] public bool Recoverable => Bytes is not null && RegistryAddress.SerializableName(Name) && Type switch
    {
        0 or 3 => true,
        4 or 5 => Bytes.Length == 4,
        11 => Bytes.Length == 8,
        1 or 2 => Bytes.Length >= 2 && Bytes.Length % 2 == 0 && Bytes[^1] == 0 && Bytes[^2] == 0,
        7 => Bytes.Length >= 4 && Bytes.Length % 2 == 0 && Bytes[^1] == 0 && Bytes[^2] == 0 && Bytes[^3] == 0 && Bytes[^4] == 0,
        _ => false,
    };
}

public sealed record RegistryNode([property: JsonRequired] string NativeName, [property: JsonRequired] string Name,
    [property: JsonRequired] string Class, [property: JsonRequired] string LastWriteTime,
    [property: JsonRequired] uint SecurityCoverage, [property: JsonRequired] byte[]? Security,
    [property: JsonRequired] RegistryValueData[] Values, [property: JsonRequired] RegistryNode[] Children);

public sealed record RegistrySnapshot([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] bool Exists, [property: JsonRequired] RegistryNode? Node)
{
    public string Digest(bool freshness)
    {
        if (Address.Kind == "value")
            return OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { Exists, NativeName = Node?.NativeName, Values = Node?.Values }, OperationFiles.Json));
        object? NodeData(RegistryNode? node) => node is null ? null : new
        {
            node.NativeName, node.Name, node.Class,
            LastWriteTime = freshness ? node.LastWriteTime : null,
            node.SecurityCoverage, node.Security,
            Values = node.Values.OrderBy(value => value.Name, StringComparer.OrdinalIgnoreCase),
            Children = node.Children.OrderBy(child => child.Name, StringComparer.OrdinalIgnoreCase).Select(NodeData),
        };
        return OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { Exists, Node = NodeData(Node) }, OperationFiles.Json));
    }
}

public sealed record RegistryCleanupPreview
{
    public required int SchemaVersion { get; init; }
    public required string OperationId { get; init; }
    public required OperationOwner Owner { get; init; }
    public required string AppId { get; init; }
    public required string ProviderIdentityHash { get; init; }
    public required RegistrySnapshot[] Targets { get; init; }
    public required bool AcceptKeyRecreation { get; init; }
    public required string OriginalKeyPersistence { get; init; }
    public required string RestoreKeyPersistence { get; init; }
    public required RegistryAddress Receipt { get; init; }
    public required string ReceiptParentNativeName { get; init; }
}

public sealed class RegistryCleanupJournal
{
    public required int SchemaVersion { get; init; }
    public required RegistryCleanupPreview Preview { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required string BackupPath { get; init; }
    public required string BackupHash { get; init; }
    public required string Status { get; set; }
    public string? Error { get; set; }
    public required DateTime UpdatedAtUtc { get; set; }
}
