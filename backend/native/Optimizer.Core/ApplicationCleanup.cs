#nullable enable
namespace RooIndustries.Optimizer;

public sealed record CleanupContext(string Source, CleanupAuthority Authority, CleanupApplication Application,
    CleanupApplication[] Peers, bool InventoryComplete)
{
    public string InventoryHash => OperationFiles.Hash(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(
        Peers.OrderBy(app => app.AppId, StringComparer.Ordinal).ToArray(), OperationFiles.Json));

    public void Verify()
    {
        Authority.Verify(Application.AppId, Authority.ProviderIdentityHash);
        if (!InventoryComplete) throw new InvalidDataException("Installed app ownership is incomplete. Refresh inventory before deleting leftovers.");
        if (!Path.IsPathFullyQualified(Source)) throw new InvalidDataException("The removal workflow source is missing.");
    }
}

public sealed record CleanupPart(string PreviewPath, string ReviewHash, string JournalPath);

public sealed record ApplicationCleanupPreview
{
    public required int SchemaVersion { get; init; }
    public required OperationOwner Owner { get; init; }
    public required string OperationId { get; init; }
    public required string Source { get; init; }
    public required string AppId { get; init; }
    public required string DisplayName { get; init; }
    public required string ProviderIdentityHash { get; init; }
    public required string InventoryHash { get; init; }
    public required LeftoverCandidate[] Selection { get; init; }
    public required CleanupPart? Registry { get; init; }
    public required CleanupPart? Files { get; init; }
}

public sealed class ApplicationCleanupJournal
{
    public required int SchemaVersion { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required ApplicationCleanupPreview Preview { get; init; }
    public required string Status { get; set; }
    public required bool RestoreStarted { get; set; }
    public string? RegistryStatus { get; set; }
    public string? FileStatus { get; set; }
    public required List<string> Errors { get; set; }
    public required DateTime UpdatedAtUtc { get; set; }
}

public sealed class ApplicationCleanup(Func<CleanupContext> currentContext,
    string[]? discoveryFileRoots = null, RegistryAddress[]? discoveryRegistryRoots = null,
    Func<CleanupExclusions>? currentExclusions = null)
{
    public LeftoverDiscoveryResult Scan(CancellationToken cancellationToken)
    {
        var context = currentContext();
        context.Verify();
        return Scan(context, cancellationToken);
    }

    public ApplicationCleanupPreview Preview(string outputPath, string[] itemIds, bool ownershipReviewed, bool acceptKeyRecreation)
    {
        if (!ownershipReviewed) throw new InvalidDataException("Review app ownership and any personal data before preparing cleanup.");
        if (itemIds.Length == 0 || itemIds.Distinct(StringComparer.Ordinal).Count() != itemIds.Length) throw new InvalidDataException("Select distinct leftover items.");
        var context = currentContext();
        context.Verify();
        var scan = Scan(context, CancellationToken.None);
        var selection = itemIds.Select(id => scan.Candidates.SingleOrDefault(item => item.ItemId == id)
            ?? throw new InvalidDataException("A selected leftover is no longer present in discovery.")).ToArray();
        foreach (var item in selection)
            if (item.Exists != true || item.Protected || item.SharedOwners.Count != 0 || !item.OwnershipComplete || item.Error is not null)
                throw new InvalidDataException("This leftover is protected, shared or has incomplete ownership evidence: " + item.Target);
        var directory = Path.GetDirectoryName(Path.GetFullPath(outputPath))!;
        var operationId = Guid.NewGuid().ToString("N");
        CleanupAuthority Authority()
        {
            Exclusions().RequireAllowed(selection);
            return VerifyContext(context.Source, context.Application.AppId, context.Authority.ProviderIdentityHash, context.InventoryHash).Authority;
        }
        var registryTargets = selection.Where(item => item.Registry is not null).Select(item => item.Registry!).ToArray();
        var fileTargets = selection.Where(item => item.Registry is null).Select(item => item.Target).ToArray();
        CleanupPart? registry = null, files = null;
        if (registryTargets.Length != 0)
        {
            var receipt = new RegistryAddress("CurrentUser", "Registry64", "Software\\RooIndustriesOptimizationSuite.Receipt." + operationId, "key", null);
            var preview = new RegistryCleanupEngine(Authority).Preview(context.Application.AppId, context.Authority.ProviderIdentityHash, registryTargets,
                receipt, ownershipReviewed, acceptKeyRecreation);
            registry = SavePart("registry", preview);
        }
        if (fileTargets.Length != 0)
            files = SavePart("files", new FileCleanupEngine(Authority).Preview(context.Application.AppId, context.Authority.ProviderIdentityHash, fileTargets, ownershipReviewed));
        var result = new ApplicationCleanupPreview
        {
            SchemaVersion = 1, Owner = OperationOwner.Current(), OperationId = operationId, Source = context.Source,
            AppId = context.Application.AppId, DisplayName = context.Application.DisplayName, ProviderIdentityHash = context.Authority.ProviderIdentityHash,
            InventoryHash = context.InventoryHash, Selection = selection, Registry = registry, Files = files,
        };
        OperationFiles.Write(outputPath, result);
        return result;

        CleanupPart SavePart<T>(string name, T preview)
        {
            var path = Path.Combine(directory, operationId + "-" + name + "-preview.json");
            OperationFiles.Write(path, preview);
            return new(path, OperationFiles.HashFile(path), Path.Combine(directory, operationId + "-" + name + "-journal.json"));
        }
    }

    public ApplicationCleanupJournal Apply(string previewPath, string reviewHash, string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var preview = OperationFiles.Read<ApplicationCleanupPreview>(previewPath, reviewHash);
        Validate(preview);
        if (string.Equals(Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Cleanup preview and recovery journal must be separate.");
        var journal = File.Exists(journalPath) ? ReadJournal(journalPath) : new ApplicationCleanupJournal
        {
            SchemaVersion = 1, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash, Preview = preview,
            Status = "prepared", RestoreStarted = false, Errors = [], UpdatedAtUtc = DateTime.UtcNow,
        };
        if (journal.ReviewHash != reviewHash) throw new InvalidDataException("The recovery journal belongs to another cleanup review.");
        if (journal.RestoreStarted) return journal;
        journal.Errors = [];
        Save(journalPath, journal);
        CleanupAuthority Authority()
        {
            Exclusions().RequireAllowed(preview.Selection);
            return VerifyContext(preview.Source, preview.AppId, preview.ProviderIdentityHash, preview.InventoryHash).Authority;
        }
        try
        {
            Authority();
            if (preview.Registry is { } registry)
            {
                journal.RegistryStatus = "applying";
                Save(journalPath, journal);
                var result = new RegistryCleanupEngine(Authority).Apply(registry.PreviewPath, registry.ReviewHash, registry.JournalPath);
                journal.RegistryStatus = result.Status;
                if (result.Status != "applied") throw new InvalidOperationException(result.Error ?? "Registry cleanup requires recovery: " + result.Status);
                Save(journalPath, journal);
            }
            if (preview.Files is { } files)
            {
                journal.FileStatus = "applying";
                Save(journalPath, journal);
                var result = new FileCleanupEngine(Authority).Apply(files.PreviewPath, files.ReviewHash, files.JournalPath);
                journal.FileStatus = result.Status;
                if (result.Status != "applied") throw new InvalidOperationException(string.Join("; ", result.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Error)));
            }
            journal.Status = "applied";
        }
        catch (Exception error) { journal.Errors.Add(error.Message); journal.Status = "needsReconciliation"; }
        Save(journalPath, journal);
        return journal;
    }

    public ApplicationCleanupJournal Restore(string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = ReadJournal(journalPath);
        var preview = journal.Preview;
        journal.Status = "restoring";
        journal.RestoreStarted = true;
        journal.Errors = [];
        Save(journalPath, journal);
        CleanupAuthority Authority() => VerifyContext(preview.Source, preview.AppId, preview.ProviderIdentityHash, null).Authority;
        if (preview.Files is { } files && File.Exists(files.JournalPath))
        {
            try
            {
                var result = new FileCleanupEngine(Authority).Restore(files.JournalPath);
                journal.FileStatus = result.Status;
                if (result.Status != "restored")
                {
                    journal.Errors.Add("File restoration requires reconciliation: " + result.Status);
                    journal.Errors.AddRange(result.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Error!));
                }
            }
            catch (Exception error) { journal.Errors.Add(error.Message); }
            Save(journalPath, journal);
        }
        else if (journal.FileStatus is not null) journal.Errors.Add("The file recovery journal is missing.");
        if (preview.Registry is { } registry && File.Exists(registry.JournalPath))
        {
            try
            {
                var result = new RegistryCleanupEngine(Authority).Restore(registry.JournalPath);
                journal.RegistryStatus = result.Status;
                if (result.Status is not ("restored" or "notCommitted")) journal.Errors.Add(result.Error ?? "Registry restoration needs reconciliation.");
            }
            catch (Exception error) { journal.Errors.Add(error.Message); }
        }
        else if (journal.RegistryStatus is not null) journal.Errors.Add("The registry recovery journal is missing.");
        journal.Status = journal.Errors.Count == 0 ? "restored" : "needsReconciliation";
        Save(journalPath, journal);
        return journal;
    }

    private LeftoverDiscoveryResult Scan(CleanupContext context, CancellationToken cancellationToken)
    {
        var exclusions = Exclusions();
        var result = new LeftoverDiscovery(context.Application, context.Peers).Scan(cancellationToken, discoveryFileRoots, discoveryRegistryRoots);
        foreach (var candidate in result.Candidates.Where(item => !item.Protected && item.Exists == true && item.OwnershipComplete && item.Error is null))
            if (exclusions.Match(candidate) is { } reason)
            {
                candidate.Protected = true;
                candidate.Evidence.Add(reason);
            }
        return result;
    }

    private CleanupExclusionMatcher Exclusions() => new(currentExclusions?.Invoke() ?? CleanupExclusions.Empty);

    private CleanupContext VerifyContext(string source, string appId, string identityHash, string? inventoryHash)
    {
        var current = currentContext();
        current.Verify();
        current.Authority.Verify(appId, identityHash);
        if (!string.Equals(source, current.Source, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The cleanup belongs to another removal workflow.");
        if (inventoryHash is not null && current.InventoryHash != inventoryHash) throw new InvalidDataException("Installed app ownership changed after review. Scan leftovers again.");
        return current;
    }

    private static void Validate(ApplicationCleanupPreview preview)
    {
        preview.Owner.Verify();
        if (preview.SchemaVersion != 1 || !Guid.TryParseExact(preview.OperationId, "N", out _) || preview.Selection.Length == 0 ||
            preview.Registry is null && preview.Files is null || preview.InventoryHash.Length != 64)
            throw new InvalidDataException("The application cleanup review is incomplete.");
    }

    private static ApplicationCleanupJournal ReadJournal(string path)
    {
        var journal = OperationFiles.Read<ApplicationCleanupJournal>(path);
        Validate(journal.Preview);
        if (journal.SchemaVersion != 1 || journal.Status is not ("prepared" or "applied" or "needsReconciliation" or "restoring" or "restored"))
            throw new InvalidDataException("Unknown application cleanup state.");
        var original = OperationFiles.Read<ApplicationCleanupPreview>(journal.PreviewPath, journal.ReviewHash);
        if (System.Text.Json.JsonSerializer.Serialize(original, OperationFiles.Json) != System.Text.Json.JsonSerializer.Serialize(journal.Preview, OperationFiles.Json))
            throw new InvalidDataException("The cleanup journal changed its reviewed operation binding.");
        return journal;
    }

    private static void Save(string path, ApplicationCleanupJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }
}
