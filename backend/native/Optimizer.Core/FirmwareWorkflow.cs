#nullable enable
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public sealed record FirmwareIdentity(
    [property: JsonRequired] string MachineId, [property: JsonRequired] string Board,
    [property: JsonRequired] string Bios, [property: JsonRequired] string Boot)
{
    public void Validate()
    {
        if (new[] { MachineId, Board, Bios, Boot }.Any(string.IsNullOrWhiteSpace))
            throw new InvalidDataException("The PC, motherboard, BIOS version or boot identity could not be read.");
    }
    public bool SameFirmware(FirmwareIdentity other) => MachineId == other.MachineId && Board == other.Board && Bios == other.Bios;
}
public sealed record FirmwareCommandResult([property: JsonRequired] int ExitCode,
    [property: JsonRequired] string Output, [property: JsonRequired] string Error)
{
    [JsonIgnore] public bool Succeeded => ExitCode == 0 && Output is not null && Error is not null
        && !Regex.IsMatch(Output + "\n" + Error, @"(?im)^\s*(?:\d+\s*-\s*)?(?:error|failed|failure)\b");
}
public interface IFirmwareProvider
{
    FirmwareIdentity ReadIdentity();
    string PackageFingerprint { get; }
    byte[] Export(string workingDirectory);
    FirmwareCommandResult Import(string scriptPath);
}
public sealed record FirmwareSession(
    [property: JsonRequired] string Id, [property: JsonRequired] FirmwareIdentity Identity,
    [property: JsonRequired] string PackageFingerprint, [property: JsonRequired] string BackupHash,
    [property: JsonRequired] DateTimeOffset CreatedAt);
public sealed record FirmwareChange(
    [property: JsonRequired] string Id, [property: JsonRequired] string Name,
    [property: JsonRequired] string Before, [property: JsonRequired] string After,
    [property: JsonRequired] string BeforeLabel, [property: JsonRequired] string AfterLabel);
public sealed record FirmwareReview(
    [property: JsonRequired] string SessionHash, [property: JsonRequired] string ScriptHash,
    [property: JsonRequired] FirmwareChange[] Changes);
public sealed record FirmwareJournal(
    [property: JsonRequired] string ReviewHash, [property: JsonRequired] string Status,
    [property: JsonRequired] string Message, [property: JsonRequired] FirmwareCommandResult? Result,
    [property: JsonRequired] DateTimeOffset UpdatedAt);

public sealed class FirmwareWorkflow
{
    private readonly IFirmwareProvider _provider;
    private readonly string _root;
    public FirmwareWorkflow(IFirmwareProvider provider, string root) { _provider = provider; _root = Path.GetFullPath(root); }

    public string Load()
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var identity = _provider.ReadIdentity(); identity.Validate();
        var package = _provider.PackageFingerprint;
        if (string.IsNullOrWhiteSpace(package)) throw new InvalidDataException("The SCEWIN package has not been verified.");
        var id = Guid.NewGuid().ToString("N");
        var directory = Path.Combine(_root, id);
        Directory.CreateDirectory(directory);
        try
        {
            var bytes = _provider.Export(directory);
            _ = new FirmwareScript(bytes);
            if (_provider.ReadIdentity() != identity || _provider.PackageFingerprint != package)
                throw new InvalidDataException("The PC or firmware package changed during export. Load again.");
            WriteNew(Path.Combine(directory, "original.txt"), bytes);
            OperationFiles.Write(Path.Combine(directory, "session.json"), new FirmwareSession(id, identity, package, OperationFiles.Hash(bytes), DateTimeOffset.UtcNow));
            return directory;
        }
        catch { Directory.Delete(directory, recursive: true); throw; }
    }

    public FirmwareScript Read(string directory) => ReadSession(directory).Script;

    public string Review(string directory, IReadOnlyDictionary<string, string> selections)
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var (session, script) = ReadSession(directory);
        if (File.Exists(Path.Combine(directory, "journal.json"))) throw new InvalidDataException("This export already has an import attempt. Load current settings before making another change.");
        VerifyIdentity(session, requireSameBoot: true);
        var bytes = script.Changes(selections);
        var changes = selections.Select(change =>
        {
            var question = script.Questions.Single(q => q.Id == change.Key);
            var value = script.Validate(question, change.Value);
            return new FirmwareChange(question.Id, question.Name, script.Validate(question, question.Current), value, question.DisplayValue(question.Current), question.DisplayValue(value));
        }).ToArray();
        File.WriteAllBytes(Path.Combine(directory, "changes.txt"), bytes);
        OperationFiles.Write(Path.Combine(directory, "review.json"), new FirmwareReview(OperationFiles.HashFile(Path.Combine(directory, "session.json")), OperationFiles.Hash(bytes), changes));
        return OperationFiles.HashFile(Path.Combine(directory, "review.json"));
    }

    public FirmwareJournal Apply(string directory, string reviewedHash)
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var (session, original, review) = ReadReview(directory, reviewedHash);
        var path = Path.Combine(directory, "journal.json");
        if (File.Exists(path))
        {
            var previous = OperationFiles.Read<FirmwareJournal>(path);
            if (previous.ReviewHash != reviewedHash) throw new InvalidDataException("Another review already used this export.");
            return previous;
        }
        VerifyIdentity(session, requireSameBoot: true);
        var current = new FirmwareScript(_provider.Export(directory));
        if (!original.SameLayout(current)) throw new InvalidDataException("The BIOS layout changed after loading. Nothing was written. Load the settings again and review your changes.");
        if (!original.SameValues(current)) throw new InvalidDataException("BIOS settings changed after they were loaded. Load them again and review your changes.");
        if (current.Crc != original.Crc) throw new InvalidDataException("The BIOS checksum changed after loading because a setting name shows a live reading. Nothing was written. Load the settings again and review your changes.");
        VerifyIdentity(session, requireSameBoot: true);
        var changeBytes = File.ReadAllBytes(Path.Combine(directory, "changes.txt"));
        if (OperationFiles.Hash(changeBytes) != review.ScriptHash) throw new InvalidDataException("The reviewed BIOS changes were modified. Review again.");
        // Keep the imported file open without write/delete sharing for the entire helper invocation.
        using var scriptLease = new FileStream(Path.Combine(directory, "changes.txt"), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (OperationFiles.Hash(ReadAll(scriptLease)) != review.ScriptHash) throw new InvalidDataException("The import file changed before launch.");
        Save("importing", "Import started. If the app was interrupted, verify current settings before doing anything else.", null);
        FirmwareCommandResult? result = null;
        try
        {
            result = _provider.Import(Path.Combine(directory, "changes.txt"));
            File.WriteAllText(Path.Combine(directory, "import-output.txt"), result.Output + Environment.NewLine + result.Error);
            if (!result.Succeeded) return Save("needsAttention", "SCEWIN returned " + result.ExitCode + ". Some settings may have changed. Open the import log and verify current settings; do not repeat the import.", result);
            var afterBytes = _provider.Export(directory);
            File.WriteAllBytes(Path.Combine(directory, "after-import.txt"), afterBytes);
            VerifyIdentity(session, requireSameBoot: true);
            if (!original.SameValues(new FirmwareScript(afterBytes), Selections(review)))
                return Save("needsAttention", "The exported settings do not match the review. Keep the original export and inspect the import log.", result);
            return Save("restartRequired", "The BIOS reports the reviewed values. Restart when ready, then verify them here.", result);
        }
        catch (Exception ex) { return Save("needsAttention", "Import could not be verified: " + ex.Message, result); }
        FirmwareJournal Save(string status, string message, FirmwareCommandResult? command)
        {
            var journal = new FirmwareJournal(reviewedHash, status, message, command, DateTimeOffset.UtcNow);
            OperationFiles.Write(path, journal);
            return journal;
        }
    }

    public FirmwareJournal Verify(string directory)
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var journalPath = Path.Combine(directory, "journal.json");
        var journal = OperationFiles.Read<FirmwareJournal>(journalPath);
        var (session, original, review) = ReadReview(directory, journal.ReviewHash);
        VerifyIdentity(session, requireSameBoot: false);
        var bytes = _provider.Export(directory);
        File.WriteAllBytes(Path.Combine(directory, "verification.txt"), bytes);
        var verification = new FirmwareScript(bytes);
        var sameLayout = original.SameLayout(verification);
        var match = sameLayout && original.SameValues(verification, Selections(review));
        var identity = _provider.ReadIdentity();
        if (!session.Identity.SameFirmware(identity)) throw new InvalidDataException("The motherboard or BIOS changed during verification.");
        var cleanImport = journal.Result is { Succeeded: true } && (journal.Status is "restartRequired" or "applied");
        var status = !match || !cleanImport ? "needsAttention" : identity.Boot == session.Identity.Boot ? "restartRequired" : "applied";
        var updated = journal with
        {
            Status = status,
            Message = !sameLayout ? "The BIOS layout no longer matches the saved export, so the reviewed values cannot be confirmed. Open the saved export and import log."
                : !match ? "Current BIOS values differ from the reviewed changes. Open the saved export and import log."
                : !cleanImport ? "The reviewed values are present, but the import did not finish cleanly. Inspect the import log before making another change."
                : status == "applied" ? "The reviewed settings are still present after restart." : "The reviewed settings are present. Restart is still pending.",
            UpdatedAt = DateTimeOffset.UtcNow
        };
        OperationFiles.Write(journalPath, updated);
        return updated;
    }

    public string ReviewUndo(string directory)
    {
        var journal = OperationFiles.Read<FirmwareJournal>(Path.Combine(directory, "journal.json"));
        var (session, original, review) = ReadReview(directory, journal.ReviewHash);
        VerifyIdentity(session, requireSameBoot: false);
        var next = Load();
        try
        {
            var script = Read(next);
            var selections = new Dictionary<string, string>();
            foreach (var change in review.Changes)
            {
                var current = original.Counterpart(original.Questions.Single(q => q.Id == change.Id), script) ?? throw new InvalidDataException("A changed setting is no longer present in this BIOS.");
                var value = script.Validate(current, current.Current);
                if (value == change.Before) continue;
                if (value != change.After) throw new InvalidDataException(change.Name + " was changed again. Review it manually instead of overwriting it.");
                selections.Add(current.Id, change.Before);
            }
            Review(next, selections);
            return next;
        }
        catch { Directory.Delete(next, recursive: true); throw; }
    }

    private (FirmwareSession Session, FirmwareScript Script) ReadSession(string directory)
    {
        directory = Path.GetFullPath(directory);
        if (Path.GetDirectoryName(directory) != _root || !Guid.TryParseExact(Path.GetFileName(directory), "N", out _))
            throw new InvalidDataException("This export is outside the BIOS recovery folder.");
        var session = OperationFiles.Read<FirmwareSession>(Path.Combine(directory, "session.json"));
        session.Identity.Validate();
        if (session.Id != Path.GetFileName(directory)) throw new InvalidDataException("The BIOS export identity does not match its folder.");
        var bytes = File.ReadAllBytes(Path.Combine(directory, "original.txt"));
        if (OperationFiles.Hash(bytes) != session.BackupHash) throw new InvalidDataException("The original BIOS export was modified. Load a fresh copy.");
        return (session, new FirmwareScript(bytes));
    }

    private (FirmwareSession Session, FirmwareScript Script, FirmwareReview Review) ReadReview(string directory, string hash)
    {
        if (string.IsNullOrWhiteSpace(hash)) throw new InvalidDataException("Review the BIOS changes before applying them.");
        var (session, script) = ReadSession(directory);
        var review = OperationFiles.Read<FirmwareReview>(Path.Combine(directory, "review.json"), hash);
        if (review.SessionHash != OperationFiles.HashFile(Path.Combine(directory, "session.json"))) throw new InvalidDataException("The review belongs to a different BIOS export.");
        if (review.Changes is null || review.Changes.Length == 0 || review.Changes.Select(c => c.Id).Distinct().Count() != review.Changes.Length)
            throw new InvalidDataException("The review contains missing or duplicate settings.");
        var selections = Selections(review);
        var regenerated = script.Changes(selections);
        foreach (var change in review.Changes)
        {
            var q = script.Questions.Single(q => q.Id == change.Id);
            if (change.Name != q.Name || change.Before != script.Validate(q, q.Current)
                || change.BeforeLabel != q.DisplayValue(q.Current) || change.AfterLabel != q.DisplayValue(change.After))
                throw new InvalidDataException("A displayed change disagrees with the BIOS export.");
        }
        if (OperationFiles.Hash(regenerated) != review.ScriptHash || OperationFiles.HashFile(Path.Combine(directory, "changes.txt")) != review.ScriptHash)
            throw new InvalidDataException("The import file differs from the reviewed settings.");
        return (session, script, review);
    }
    private void VerifyIdentity(FirmwareSession session, bool requireSameBoot)
    {
        var current = _provider.ReadIdentity(); current.Validate();
        if (!session.Identity.SameFirmware(current) || (requireSameBoot && session.Identity.Boot != current.Boot))
            throw new InvalidDataException("This review belongs to a different PC, BIOS version or boot. Load current settings.");
        if (_provider.PackageFingerprint != session.PackageFingerprint) throw new InvalidDataException("The SCEWIN package changed. Set it up again and reload settings.");
    }
    private static Dictionary<string, string> Selections(FirmwareReview review) => review.Changes.ToDictionary(c => c.Id, c => c.After);
    private static void WriteNew(string path, byte[] bytes) { using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read); file.Write(bytes); file.Flush(true); }
    private static byte[] ReadAll(Stream stream) { using var bytes = new MemoryStream(); stream.CopyTo(bytes); return bytes.ToArray(); }
}
