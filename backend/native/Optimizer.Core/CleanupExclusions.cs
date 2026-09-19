#nullable enable
namespace RooIndustries.Optimizer;

public sealed record CleanupExclusions
{
    public required string[] Paths { get; init; }
    public required RegistryAddress[] Registry { get; init; }
    public static CleanupExclusions Empty => new() { Paths = [], Registry = [] };

    public void Validate()
    {
        if (Paths is null || Registry is null || Paths.Length + Registry.Length > 2048)
            throw new InvalidDataException("Cleanup exclusions need explicit path and registry lists, with at most 2048 entries.");
        foreach (var path in Paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("An exclusion needs an absolute local path.");
            _ = FileLease.NormalizePath(path);
        }
        foreach (var address in Registry)
        {
            if (address is null) throw new InvalidDataException("An excluded registry identity is missing.");
            address.Validate();
        }
        if (Paths.Select(FileLease.NormalizePath).Distinct(StringComparer.OrdinalIgnoreCase).Count() != Paths.Length ||
            Registry.Select(address => (address.Hive, address.View, address.KeyPath.ToUpperInvariant(), address.Kind, address.ValueName?.ToUpperInvariant()))
                .Distinct().Count() != Registry.Length)
            throw new InvalidDataException("Cleanup exclusions contain duplicate entries.");
    }
}

public sealed class CleanupExclusionMatcher
{
    private readonly (string Original, string Canonical)[] _paths;
    private readonly (RegistryAddress Address, string Canonical)[] _registry;

    public CleanupExclusionMatcher(CleanupExclusions exclusions)
    {
        exclusions.Validate();
        _paths = exclusions.Paths.Select(path => (path, FileLease.ResolveExclusionPath(path))).ToArray();
        _registry = exclusions.Registry.Select(address => (address, ResolveRegistry(address))).ToArray();
    }

    public string? Match(string path, bool directory)
    {
        if (_paths.Length == 0) return null;
        var canonical = FileLease.ResolveExclusionPath(path);
        foreach (var rule in _paths)
            if (Within(canonical, rule.Canonical) || directory && Within(rule.Canonical, canonical)) return "Excluded path: " + rule.Original;
        return null;
    }

    public string? Match(RegistryAddress target)
    {
        if (_registry.Length == 0) return null;
        target.Validate();
        var canonical = ResolveRegistry(target);
        foreach (var rule in _registry)
        {
            var overlap = rule.Address.Kind == "key" && Within(canonical, rule.Canonical) ||
                target.Kind == "key" && Within(rule.Canonical, canonical) ||
                target.Kind == "value" && rule.Address.Kind == "value" && Same(canonical, rule.Canonical) && Same(target.ValueName!, rule.Address.ValueName!);
            if (overlap) return "Excluded registry " + rule.Address.Kind + ": " + rule.Address.Hive + "\\" + rule.Address.KeyPath +
                (rule.Address.Kind == "value" ? " :: " + rule.Address.ValueName : "");
        }
        return null;
    }

    public string? Match(LeftoverCandidate target) => target.Registry is { } address ? Match(address) : Match(target.Target, target.Kind == "folder");

    public void RequireAllowed(IEnumerable<LeftoverCandidate> selection)
    {
        foreach (var item in selection)
            if (Match(item) is { } reason) throw new InvalidDataException(reason + ". Create a new cleanup review after updating exclusions.");
    }

    private static string ResolveRegistry(RegistryAddress address)
    {
        var current = address with { Kind = "key", ValueName = null };
        while (true)
        {
            using var key = RegistryNative.OpenRead(current);
            if (key is not null) return RegistryNative.NativeName(key) + address.KeyPath[current.KeyPath.Length..];
            var separator = current.KeyPath.LastIndexOf('\\');
            if (separator < 0) throw new InvalidDataException("The excluded registry scope is unavailable.");
            current = current with { KeyPath = current.KeyPath[..separator] };
        }
    }

    private static bool Same(string first, string second) => string.Equals(first, second, StringComparison.OrdinalIgnoreCase);
    private static bool Within(string path, string root) => Same(path, root) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
}

public sealed record CleanupExclusionDocument
{
    public required int SchemaVersion { get; init; }
    public required OperationOwner Owner { get; init; }
    public required CleanupExclusions Exclusions { get; init; }
}

public sealed record CleanupExclusionState(CleanupExclusions Exclusions, string? Revision);

public sealed class CleanupExclusionStore(string path)
{
    public static string DefaultPath => Path.Combine(BrandCompatibility.LocalDataRoot, "cleanup-exclusions.json");

    public CleanupExclusionState Read()
    {
        string revision;
        CleanupExclusionDocument document;
        try
        {
            revision = OperationFiles.HashFile(path);
            document = OperationFiles.Read<CleanupExclusionDocument>(path, revision);
        }
        catch (FileNotFoundException) { return new(CleanupExclusions.Empty, null); }
        catch (DirectoryNotFoundException) { return new(CleanupExclusions.Empty, null); }
        if (document.SchemaVersion != 1 || document.Owner is null || document.Exclusions is null) throw new InvalidDataException("The cleanup exclusion document is incomplete.");
        document.Owner.Verify();
        document.Exclusions.Validate();
        return new(document.Exclusions, revision);
    }

    public CleanupExclusionState Save(CleanupExclusions exclusions, string? expectedRevision)
    {
        exclusions.Validate();
        using var lease = OperationFiles.Lock(path);
        var current = Read();
        if (!string.Equals(current.Revision, expectedRevision, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Cleanup exclusions changed. Read the current list before saving.");
        _ = new CleanupExclusionMatcher(exclusions);
        OperationFiles.Write(path, new CleanupExclusionDocument { SchemaVersion = 1, Owner = OperationOwner.Current(), Exclusions = exclusions });
        return Read();
    }
}
