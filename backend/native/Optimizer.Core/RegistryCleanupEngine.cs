#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class RegistryCleanupEngine(Func<CleanupAuthority> currentAuthority)
{
    public RegistryCleanupPreview Preview(string appId, string providerIdentityHash, RegistryAddress[] selected,
        RegistryAddress receipt, bool ownershipReviewed, bool acceptKeyRecreation)
    {
        currentAuthority().Verify(appId, providerIdentityHash);
        if (!ownershipReviewed) throw new InvalidDataException("Registry ownership must be reviewed before creating a deletion plan.");
        if (selected.Length == 0) throw new InvalidDataException("Select registry resources to review.");
        receipt.Validate();
        if (receipt.Hive != "CurrentUser" || receipt.Kind != "key" || receipt.ValueName is not null)
            throw new InvalidDataException("An operation-owned current-user receipt key is required.");
        var snapshots = selected.Select(address =>
        {
            address.RequireDeletionScope();
            var snapshot = RegistryNative.Capture(address);
            ValidateSnapshot(snapshot, acceptKeyRecreation);
            return snapshot;
        }).ToArray();
        ValidateLayout(snapshots, receipt);
        var receiptParent = receipt with { KeyPath = receipt.KeyPath[..receipt.KeyPath.LastIndexOf('\\')] };
        return new()
        {
            SchemaVersion = 1, OperationId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(),
            AppId = appId, ProviderIdentityHash = providerIdentityHash, Targets = snapshots, Receipt = receipt,
            ReceiptParentNativeName = RegistryNative.KeyName(receiptParent),
            AcceptKeyRecreation = acceptKeyRecreation, OriginalKeyPersistence = "unknown", RestoreKeyPersistence = "nonvolatile",
        };
    }

    public RegistryCleanupJournal Apply(string previewPath, string reviewHash, string journalPath)
    {
        if (string.Equals(Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Registry preview and journal paths must be separate.");
        var preview = OperationFiles.Read<RegistryCleanupPreview>(previewPath, reviewHash);
        ValidatePreview(preview);
        currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
        using var lease = OperationFiles.Lock(journalPath);
        if (File.Exists(journalPath))
        {
            var saved = ReadJournal(journalPath);
            if (saved.Preview.OperationId != preview.OperationId || saved.ReviewHash != reviewHash)
                throw new InvalidDataException("The registry journal belongs to another review.");
            return ReconcileReceipt(saved, journalPath);
        }
        var backupPath = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(journalPath))!, "registry-backup-" + preview.OperationId + ".json");
        if (File.Exists(backupPath)) throw new IOException("Registry backup path already exists.");
        OperationFiles.Write(backupPath, preview.Targets);
        var backupHash = OperationFiles.HashFile(backupPath);
        _ = OperationFiles.Read<RegistrySnapshot[]>(backupPath, backupHash);
        var journal = new RegistryCleanupJournal
        {
            SchemaVersion = 1, Preview = preview, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash,
            BackupPath = backupPath, BackupHash = backupHash, Status = "preparing", UpdatedAtUtc = DateTime.UtcNow,
        };
        Save(journalPath, journal);
        try
        {
            using (var verification = RegistryTransaction.Begin())
            {
                foreach (var target in preview.Targets) RegistryNative.DeleteReviewed(target, verification);
                foreach (var target in preview.Targets) RegistryNative.RestoreReviewed(target, verification);
                foreach (var target in preview.Targets)
                    if (RegistryNative.Capture(target.Address, verification).Digest(false) != target.Digest(false))
                        throw new InvalidDataException("Registry recovery could not reproduce the promised data before deletion.");
            }
            using var transaction = RegistryTransaction.Begin();
            foreach (var target in preview.Targets) RegistryNative.DeleteReviewed(target, transaction);
            RegistryNative.WriteReceipt(preview.Receipt, preview.ReceiptParentNativeName, ReceiptBytes(journal, "committed"), transaction, mustCreate: true);
            currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
            journal.Status = "commitIntent";
            Save(journalPath, journal);
            transaction.Commit();
            return ReconcileReceipt(journal, journalPath);
        }
        catch (Exception error)
        {
            journal.Error = error.Message;
            journal.Status = "needsReconciliation";
            Save(journalPath, journal);
            return journal;
        }
    }

    public RegistryCleanupJournal Restore(string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = ReadJournal(journalPath);
        currentAuthority().Verify(journal.Preview.AppId, journal.Preview.ProviderIdentityHash);
        var receipt = ReadReceipt(journal);
        if (receipt is null)
        {
            if (journal.Preview.Targets.All(target => RegistryNative.Capture(target.Address).Digest(false) == target.Digest(false)))
            {
                journal.Status = "notCommitted";
                Save(journalPath, journal);
                return journal;
            }
            throw new InvalidDataException("No matching commit receipt establishes ownership of the missing registry data.");
        }
        if (receipt.Phase == "restored") return ReconcileReceipt(journal, journalPath);
        if (receipt.Phase != "committed") throw new InvalidDataException("Unknown registry receipt phase.");
        var backup = OperationFiles.Read<RegistrySnapshot[]>(journal.BackupPath, journal.BackupHash);
        if (JsonSerializer.Serialize(backup, OperationFiles.Json) != JsonSerializer.Serialize(journal.Preview.Targets, OperationFiles.Json))
            throw new InvalidDataException("The backup resources no longer match the approved registry targets.");
        try
        {
            using var transaction = RegistryTransaction.Begin();
            foreach (var target in backup) RegistryNative.RestoreReviewed(target, transaction);
            RegistryNative.WriteReceipt(journal.Preview.Receipt, journal.Preview.ReceiptParentNativeName, ReceiptBytes(journal, "restored"), transaction, mustCreate: false);
            currentAuthority().Verify(journal.Preview.AppId, journal.Preview.ProviderIdentityHash);
            journal.Status = "restoreIntent";
            Save(journalPath, journal);
            transaction.Commit();
            return ReconcileReceipt(journal, journalPath);
        }
        catch (Exception error)
        {
            journal.Error = error.Message;
            journal.Status = "needsReconciliation";
            Save(journalPath, journal);
            return journal;
        }
    }

    public RegistryCleanupJournal Reconcile(string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        return ReconcileReceipt(ReadJournal(journalPath), journalPath);
    }

    private static RegistryCleanupJournal ReconcileReceipt(RegistryCleanupJournal journal, string path)
    {
        var receipt = ReadReceipt(journal);
        if (receipt is null)
        {
            var unchanged = journal.Preview.Targets.All(target => RegistryNative.Capture(target.Address).Digest(false) == target.Digest(false));
            journal.Status = unchanged ? "notCommitted" : "needsReconciliation";
            journal.Error = unchanged ? null : "Registry data changed without a matching operation receipt.";
        }
        else if (receipt.Phase == "committed")
        {
            var absent = journal.Preview.Targets.All(target => !RegistryNative.Capture(target.Address).Exists);
            journal.Status = absent ? "applied" : "needsReconciliation";
            journal.Error = absent ? null : "Registry data exists again after the committed deletion. It will not be removed again.";
        }
        else if (receipt.Phase == "restored")
        {
            var unchanged = journal.Preview.Targets.All(target => RegistryNative.Capture(target.Address).Digest(false) == target.Digest(false));
            journal.Status = unchanged ? "restored" : "changedAfterRestore";
            journal.Error = unchanged ? null : "Registry data changed after restoration. It will not be overwritten.";
        }
        else throw new InvalidDataException("Unknown registry receipt phase.");
        Save(path, journal);
        return journal;
    }

    private static RegistryCleanupJournal ReadJournal(string path)
    {
        var journal = OperationFiles.Read<RegistryCleanupJournal>(path);
        if (journal.SchemaVersion != 1) throw new InvalidDataException("Unsupported registry recovery version.");
        ValidatePreview(journal.Preview);
        var reviewed = OperationFiles.Read<RegistryCleanupPreview>(journal.PreviewPath, journal.ReviewHash);
        if (JsonSerializer.Serialize(reviewed, OperationFiles.Json) != JsonSerializer.Serialize(journal.Preview, OperationFiles.Json))
            throw new InvalidDataException("Registry recovery is not bound to its original reviewed preview.");
        _ = OperationFiles.Read<RegistrySnapshot[]>(journal.BackupPath, journal.BackupHash);
        return journal;
    }

    private sealed record Receipt(string OperationId, string AppId, string ReviewHash, string BackupHash, string Phase);
    private static byte[] ReceiptBytes(RegistryCleanupJournal journal, string phase)
        => JsonSerializer.SerializeToUtf8Bytes(new Receipt(journal.Preview.OperationId, journal.Preview.AppId, journal.ReviewHash, journal.BackupHash, phase), OperationFiles.Json);

    private static Receipt? ReadReceipt(RegistryCleanupJournal journal)
    {
        var bytes = RegistryNative.ReadReceipt(journal.Preview.Receipt, journal.Preview.ReceiptParentNativeName);
        if (bytes is null) return null;
        var receipt = JsonSerializer.Deserialize<Receipt>(bytes, OperationFiles.Json) ?? throw new InvalidDataException("Empty registry operation receipt.");
        if (receipt.OperationId != journal.Preview.OperationId || receipt.AppId != journal.Preview.AppId || receipt.ReviewHash != journal.ReviewHash || receipt.BackupHash != journal.BackupHash)
            throw new InvalidDataException("Registry receipt belongs to another operation or backup.");
        return receipt;
    }

    private static void ValidatePreview(RegistryCleanupPreview preview)
    {
        if (preview.SchemaVersion != 1 || !Guid.TryParseExact(preview.OperationId, "N", out _) || string.IsNullOrWhiteSpace(preview.AppId) ||
            preview.ProviderIdentityHash is not { Length: 64 } || preview.Targets is not { Length: > 0 } ||
            preview.OriginalKeyPersistence != "unknown" || preview.RestoreKeyPersistence != "nonvolatile")
            throw new InvalidDataException("The registry cleanup review is incomplete.");
        preview.Owner.Verify();
        preview.Receipt.Validate();
        if (string.IsNullOrWhiteSpace(preview.ReceiptParentNativeName)) throw new InvalidDataException("Registry receipt identity was not captured.");
        foreach (var target in preview.Targets) ValidateSnapshot(target, preview.AcceptKeyRecreation);
        ValidateLayout(preview.Targets, preview.Receipt);
    }

    private static void ValidateSnapshot(RegistrySnapshot snapshot, bool acceptKeyRecreation)
    {
        snapshot.Address.RequireDeletionScope();
        if (!snapshot.Exists || snapshot.Node is null) throw new InvalidDataException("A missing registry target is not a deletion candidate.");
        if (snapshot.Address.Kind == "key" && !acceptKeyRecreation)
            throw new InvalidDataException("Whole-key cleanup requires review of ordinary persistent-key recreation and its metadata limits.");
        void CheckNode(RegistryNode node)
        {
            if (string.IsNullOrWhiteSpace(node.NativeName) || !RegistryAddress.SerializableName(node.NativeName) || !RegistryAddress.SerializableName(node.Name) ||
                !RegistryAddress.SerializableName(node.Class) || node.Values is null || node.Children is null || node.Values.Any(value => !value.Recoverable))
                throw new InvalidDataException("Registry data includes a representation without a supported restore contract.");
            if (snapshot.Address.Kind == "key" && (node.SecurityCoverage != 7 || node.Security is not { Length: > 0 }))
                throw new InvalidDataException("Registry owner, group and DACL backup is incomplete.");
            foreach (var child in node.Children) CheckNode(child);
        }
        CheckNode(snapshot.Node);
        if (snapshot.Address.Kind == "value" && (snapshot.Node.Values.Length != 1 || snapshot.Node.Values[0].Name != snapshot.Address.ValueName))
            throw new InvalidDataException("Registry value backup does not match the selected value identity.");
    }

    private static void ValidateLayout(RegistrySnapshot[] targets, RegistryAddress receipt)
    {
        for (var index = 0; index < targets.Length; index++)
        {
            var target = targets[index];
            if (target.Address.Hive == receipt.Hive && (Within(receipt.KeyPath, target.Address.KeyPath) || Within(target.Address.KeyPath, receipt.KeyPath)))
                throw new InvalidDataException("Registry cleanup and receipt storage must be separate.");
            for (var otherIndex = 0; otherIndex < index; otherIndex++)
            {
                var other = targets[otherIndex];
                var sameKey = string.Equals(target.Node!.NativeName, other.Node!.NativeName, StringComparison.OrdinalIgnoreCase);
                if ((sameKey && (target.Address.Kind == "key" || other.Address.Kind == "key" || string.Equals(target.Address.ValueName, other.Address.ValueName, StringComparison.OrdinalIgnoreCase))) ||
                    (other.Address.Kind == "key" && Within(target.Node.NativeName, other.Node.NativeName)) ||
                    (target.Address.Kind == "key" && Within(other.Node.NativeName, target.Node.NativeName)))
                    throw new InvalidDataException("Registry selections overlap or alias the same physical resource.");
            }
        }
    }

    private static bool Within(string path, string root) => string.Equals(path, root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
    private static void Save(string path, RegistryCleanupJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }
}
