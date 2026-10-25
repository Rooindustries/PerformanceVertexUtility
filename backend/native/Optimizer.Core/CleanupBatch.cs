#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed record CleanupBatchPart(ApplicationCleanupPreview Preview, CleanupPart Operation);

public sealed record CleanupBatchPreview
{
    public required int SchemaVersion { get; init; }
    public required string BatchId { get; init; }
    public required OperationOwner Owner { get; init; }
    public required CleanupBatchPart[] Parts { get; init; }
}

public sealed class CleanupBatchEntry
{
    public required string OperationId { get; init; }
    public required string Status { get; set; }
    public string? Error { get; set; }
}

public sealed class CleanupBatchJournal
{
    public required int SchemaVersion { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required CleanupBatchPreview Preview { get; init; }
    public required bool RestoreStarted { get; set; }
    public required string Status { get; set; }
    public string? CancellationId { get; set; }
    public required List<CleanupBatchEntry> Entries { get; init; }
    public required DateTime UpdatedAtUtc { get; set; }
}

public sealed record CleanupBatchCancellation
{
    public required string BatchId { get; init; }
    public required string CancellationId { get; init; }
    public required OperationOwner Owner { get; init; }
}

public sealed class CleanupBatch(Func<string, string, ApplicationCleanup> application)
{
    public static CleanupBatchPreview Preview(string outputPath, CleanupPart[] operations)
    {
        var preview = new CleanupBatchPreview
        {
            SchemaVersion = 1, BatchId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(),
            Parts = operations.Select(operation => new CleanupBatchPart(OperationFiles.Read<ApplicationCleanupPreview>(operation.PreviewPath, operation.ReviewHash), operation)).ToArray(),
        };
        Validate(preview);
        ValidateStorage(preview, outputPath);
        OperationFiles.Write(outputPath, preview);
        return preview;
    }

    public CleanupBatchJournal Apply(string previewPath, string reviewHash, string journalPath, string? resumeCancellationId = null)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var preview = OperationFiles.Read<CleanupBatchPreview>(previewPath, reviewHash);
        Validate(preview);
        ValidateStorage(preview, previewPath, journalPath);
        if (string.Equals(Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Batch review and journal paths must be separate.");
        var journal = File.Exists(journalPath) ? ReadJournal(journalPath) : new CleanupBatchJournal
        {
            SchemaVersion = 1, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash, Preview = preview,
            RestoreStarted = false, Status = "prepared", UpdatedAtUtc = DateTime.UtcNow,
            Entries = preview.Parts.Select(part => new CleanupBatchEntry { OperationId = part.Preview.OperationId, Status = "pending" }).ToList(),
        };
        if (journal.ReviewHash != reviewHash) throw new InvalidDataException("The batch journal belongs to another review.");
        if (journal.RestoreStarted) return journal;
        ClearCancellation(journalPath, preview.BatchId, resumeCancellationId);
        FileCleanupEngine.RequireSpace(preview.Parts.Where(part => part.Preview.Files is not null && journal.Entries.Any(entry => entry.OperationId == part.Preview.OperationId && entry.Status == "pending"))
            .Select(part => (OperationFiles.Read<FileCleanupPreview>(part.Preview.Files!.PreviewPath, part.Preview.Files.ReviewHash), part.Preview.Files.JournalPath)));
        journal.Status = "running";
        Save(journalPath, journal);
        foreach (var entry in journal.Entries)
        {
            var cancellation = Cancellation(journalPath, preview.BatchId);
            if (cancellation is not null) { journal.Status = "stopped"; journal.CancellationId = cancellation.CancellationId; Save(journalPath, journal); return journal; }
            var part = preview.Parts.Single(part => part.Preview.OperationId == entry.OperationId);
            if (entry.Status is not ("pending" or "applying" or "applied" or "needsReconciliation")) throw new InvalidDataException("This batch cannot resume a restored application.");
            entry.Status = "applying";
            entry.Error = null;
            Save(journalPath, journal);
            try
            {
                var result = application(part.Preview.Source, part.Preview.AppId).Apply(part.Operation.PreviewPath, part.Operation.ReviewHash, part.Operation.JournalPath);
                entry.Status = result.Status;
                if (result.Status != "applied") entry.Error = string.Join(Environment.NewLine, result.Errors);
            }
            catch (Exception error) { entry.Status = "needsReconciliation"; entry.Error = error.Message; }
            if (entry.Status != "applied") { journal.Status = "needsReconciliation"; Save(journalPath, journal); return journal; }
            Save(journalPath, journal);
        }
        journal.Status = "applied";
        Save(journalPath, journal);
        return journal;
    }

    public static CleanupBatchCancellation Cancel(string journalPath)
    {
        var journal = ReadJournal(journalPath);
        var cancellation = new CleanupBatchCancellation { BatchId = journal.Preview.BatchId, CancellationId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current() };
        using var lease = OperationFiles.Lock(journalPath + ".cancel");
        OperationFiles.Write(journalPath + ".cancel", cancellation);
        return cancellation;
    }

    public CleanupBatchJournal Restore(string journalPath, string[]? appIds = null)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = ReadJournal(journalPath);
        if (appIds is not null && (appIds.Length == 0 || appIds.Distinct(StringComparer.Ordinal).Count() != appIds.Length ||
            appIds.Any(appId => !journal.Preview.Parts.Any(part => part.Preview.AppId == appId))))
            throw new InvalidDataException("Select distinct application IDs from this cleanup batch.");
        var selected = journal.Preview.Parts.Where(part => appIds is null || appIds.Contains(part.Preview.AppId, StringComparer.Ordinal))
            .Select(part => part.Preview.OperationId).ToHashSet(StringComparer.Ordinal);
        if (appIds is not null && journal.Entries.Any(entry => selected.Contains(entry.OperationId) && entry.Status == "pending"))
            throw new InvalidDataException("A selected application has no attempted cleanup to restore.");
        var selectedEntries = journal.Entries.Where(entry => selected.Contains(entry.OperationId)).ToArray();
        if (selectedEntries.Length > 0 && selectedEntries.All(entry => entry.Status == "restored")) return journal;
        if (!HasRestorableEntries(journal, appIds))
            throw new InvalidDataException("This cleanup batch has no attempted cleanup with recovery data.");
        journal.RestoreStarted = true;
        journal.Status = "restoring";
        Save(journalPath, journal);
        foreach (var entry in journal.Entries.AsEnumerable().Reverse().Where(entry => selected.Contains(entry.OperationId) && entry.Status is not ("pending" or "restored")))
        {
            var part = journal.Preview.Parts.Single(part => part.Preview.OperationId == entry.OperationId);
            try
            {
                if (!File.Exists(part.Operation.JournalPath)) throw new InvalidDataException("The application recovery journal is missing.");
                var restored = application(part.Preview.Source, part.Preview.AppId).Restore(part.Operation.JournalPath);
                entry.Status = restored.Status;
                entry.Error = restored.Errors.Count == 0 ? null : string.Join(Environment.NewLine, restored.Errors);
            }
            catch (Exception error) { entry.Status = "needsReconciliation"; entry.Error = error.Message; }
            Save(journalPath, journal);
        }
        journal.Status = journal.Entries.All(entry => entry.Status is "pending" or "restored") ? "restored"
            : journal.Entries.Any(entry => entry.Status is "needsReconciliation" or "applying" or "restoring") ? "needsReconciliation" : "partiallyRestored";
        Save(journalPath, journal);
        return journal;
    }

    public static bool HasRestorableEntries(CleanupBatchJournal journal, string[]? appIds = null)
    {
        var selected = journal.Preview.Parts
            .Where(part => appIds is null || appIds.Contains(part.Preview.AppId, StringComparer.Ordinal))
            .ToDictionary(part => part.Preview.OperationId, part => part.Operation.JournalPath, StringComparer.Ordinal);
        return journal.Entries.Any(entry => selected.TryGetValue(entry.OperationId, out var recoveryPath)
            && entry.Status is ("applying" or "applied" or "needsReconciliation" or "restoring")
            && File.Exists(recoveryPath));
    }

    private static CleanupBatchCancellation? Cancellation(string path, string batchId)
    {
        if (!File.Exists(path + ".cancel")) return null;
        var cancellation = OperationFiles.Read<CleanupBatchCancellation>(path + ".cancel");
        cancellation.Owner.Verify();
        if (cancellation.BatchId != batchId || !Guid.TryParseExact(cancellation.CancellationId, "N", out _)) throw new InvalidDataException("The cancellation belongs to another cleanup batch.");
        return cancellation;
    }

    private static void ClearCancellation(string path, string batchId, string? acknowledgedId)
    {
        if (acknowledgedId is null) return;
        using var lease = OperationFiles.Lock(path + ".cancel");
        var current = Cancellation(path, batchId);
        if (current?.CancellationId == acknowledgedId) File.Delete(path + ".cancel");
    }

    private static void Validate(CleanupBatchPreview preview)
    {
        preview.Owner.Verify();
        if (preview.SchemaVersion != 1 || !Guid.TryParseExact(preview.BatchId, "N", out _) || preview.Parts.Length == 0 ||
            preview.Parts.Select(part => part.Preview.AppId).Distinct().Count() != preview.Parts.Length ||
            preview.Parts.Select(part => part.Preview.OperationId).Distinct().Count() != preview.Parts.Length ||
            preview.Parts.Select(part => Path.GetFullPath(part.Operation.JournalPath)).Distinct(StringComparer.OrdinalIgnoreCase).Count() != preview.Parts.Length)
            throw new InvalidDataException("The cleanup batch must contain distinct reviewed applications.");
        var fileRoots = new List<string>();
        var registry = new List<(string NativeName, RegistryAddress Address)>();
        foreach (var part in preview.Parts)
        {
            part.Preview.Owner.Verify();
            var original = OperationFiles.Read<ApplicationCleanupPreview>(part.Operation.PreviewPath, part.Operation.ReviewHash);
            if (JsonSerializer.Serialize(original, OperationFiles.Json) != JsonSerializer.Serialize(part.Preview, OperationFiles.Json)) throw new InvalidDataException("A batch part changed its application review binding.");
            if (part.Preview.Files is { } files)
            {
                var plan = OperationFiles.Read<FileCleanupPreview>(files.PreviewPath, files.ReviewHash);
                foreach (var root in plan.Roots)
                {
                    if (fileRoots.Any(previous => Within(root, previous) || Within(previous, root))) throw new InvalidDataException("File selections overlap between applications. Assign each target to one reviewed application.");
                    fileRoots.Add(root);
                }
            }
            if (part.Preview.Registry is { } keys)
            {
                var plan = OperationFiles.Read<RegistryCleanupPreview>(keys.PreviewPath, keys.ReviewHash);
                foreach (var target in plan.Targets)
                {
                    var name = target.Node?.NativeName ?? throw new InvalidDataException("Registry target identity is missing.");
                    if (registry.Any(previous => previous.Address.Kind == "key" && Within(name, previous.NativeName) || target.Address.Kind == "key" && Within(previous.NativeName, name) ||
                        string.Equals(name, previous.NativeName, StringComparison.OrdinalIgnoreCase) && string.Equals(target.Address.ValueName, previous.Address.ValueName, StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidDataException("Registry selections overlap between applications. Review each resource once.");
                    registry.Add((name, target.Address));
                }
            }
        }
    }

    public static CleanupBatchJournal ReadJournal(string path)
    {
        var journal = OperationFiles.Read<CleanupBatchJournal>(path);
        Validate(journal.Preview);
        var original = OperationFiles.Read<CleanupBatchPreview>(journal.PreviewPath, journal.ReviewHash);
        if (journal.SchemaVersion != 1 || JsonSerializer.Serialize(original, OperationFiles.Json) != JsonSerializer.Serialize(journal.Preview, OperationFiles.Json) ||
            !journal.Entries.Select(entry => entry.OperationId).SequenceEqual(original.Parts.Select(part => part.Preview.OperationId)))
            throw new InvalidDataException("Batch recovery state does not match its reviewed applications.");
        if (journal.Status is not ("prepared" or "running" or "applied" or "stopped" or "needsReconciliation" or "restoring" or "restored" or "partiallyRestored") ||
            journal.Entries.Any(entry => entry.Status is not ("pending" or "applying" or "applied" or "needsReconciliation" or "restoring" or "restored")))
            throw new InvalidDataException("Unknown batch recovery state.");
        if (!journal.RestoreStarted && journal.Status is ("restoring" or "restored" or "partiallyRestored")
            || journal.RestoreStarted && journal.Status is ("prepared" or "running" or "applied" or "stopped"))
            throw new InvalidDataException("Batch recovery phase contradicts its restore state.");
        if (journal.Status == "restored" && !journal.Entries.Any(entry => entry.Status == "restored"))
            throw new InvalidDataException("Restored batch state is missing an actual restored entry.");
        if (journal.Status == "partiallyRestored" && (!journal.RestoreStarted || !journal.Entries.Any(entry => entry.Status == "restored")))
            throw new InvalidDataException("Partial recovery state is missing its restoration evidence.");
        return journal;
    }

    private static void ValidateStorage(CleanupBatchPreview preview, params string[] paths)
    {
        foreach (var part in preview.Parts.Where(part => part.Preview.Files is not null))
        {
            var files = part.Preview.Files!;
            var targets = OperationFiles.Read<FileCleanupPreview>(files.PreviewPath, files.ReviewHash).Roots;
            if (paths.Any(path => targets.Any(root => Within(Path.GetFullPath(path), root)))) throw new InvalidDataException("Batch recovery files must stay outside cleanup targets.");
        }
    }

    private static bool Within(string path, string root) => string.Equals(path, root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    private static void Save(string path, CleanupBatchJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }
}
