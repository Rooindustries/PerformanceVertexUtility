#nullable enable
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public static class FirmwareTrialStatuses
{
    public const string Untested = "untested";
    public const string WriteRejected = "writeRejected";
    public const string UnchangedImmediately = "unchangedImmediately";
    public const string ValueStored = "valueStored";
    public const string PersistedAfterRestart = "persistedAfterRestart";
    public const string ActualBehaviorVerified = "actualBehaviorVerified";
    public const string Inconclusive = "inconclusive";

    private static readonly string[] Values =
    [
        Untested, WriteRejected, UnchangedImmediately, ValueStored,
        PersistedAfterRestart, ActualBehaviorVerified, Inconclusive
    ];

    internal static bool IsKnown(string value) => Values.Contains(value, StringComparer.Ordinal);
}

public static class FirmwareEvidencePhases
{
    public const string Baseline = "baseline";
    public const string Review = "review";
    public const string Write = "write";
    public const string Immediate = "immediate";
    public const string Restart = "restart";
    public const string Behavior = "behavior";
    public const string Restoration = "restoration";

    private static readonly string[] Values = [Baseline, Review, Write, Immediate, Restart, Behavior, Restoration];

    internal static bool IsKnown(string value) => Values.Contains(value, StringComparer.Ordinal);
}

public static class FirmwareVerificationMatchStatuses
{
    public const string Matched = "matched";
    public const string DifferentMachine = "differentMachine";
    public const string DifferentBoard = "differentBoard";
    public const string DifferentBios = "differentBios";
    public const string DifferentPackage = "differentPackage";
    public const string DifferentProfile = "differentProfile";
    public const string UnknownCurrent = "unknownCurrent";
    public const string Unavailable = "unavailable";
}

public static class FirmwareBehaviorOutcomes
{
    public const string Changed = "changed";
    public const string Unchanged = "unchanged";
    public const string Inconclusive = "inconclusive";
    public const string NotApplicable = "notApplicable";
}

public sealed record FirmwareVerificationMatch(
    [property: JsonRequired] FirmwareVerificationTrial Trial,
    [property: JsonRequired] string CurrentStatus,
    string CurrentQuestionId = "")
{
    [JsonIgnore] public bool Matches => CurrentStatus == FirmwareVerificationMatchStatuses.Matched;
}

public sealed record FirmwareVerificationQuestion(
    [property: JsonRequired] string Id,
    [property: JsonRequired] string Context,
    [property: JsonRequired] string Kind,
    [property: JsonRequired] int Width,
    [property: JsonRequired] string OptionsFingerprint,
    [property: JsonRequired] string StorageBinding,
    [property: JsonRequired] string StorageGuid,
    [property: JsonRequired] string StorageName)
{
    public static FirmwareVerificationQuestion From(FirmwareQuestion question)
    {
        var token = Regex.Match(question.Text, @"(?m)^[ \t]*Token[ \t]*=[ \t]*([^\r\n/]*)").Groups[1].Value.Trim();
        var offset = Regex.Match(question.Text, @"(?m)^[ \t]*Offset[ \t]*=[ \t]*([^\r\n/]*)").Groups[1].Value.Trim();
        var storageGuid = question.StorageGuid;
        var storageName = question.StorageName;
        var options = string.Join("\n", question.Options.Select(option => option.Value + "=" + option.Label));
        return new(question.Id, question.Context, question.Kind, question.Width,
            OperationFiles.Hash(Encoding.UTF8.GetBytes(options)),
            string.Join("|", new[] { storageGuid, storageName, token.ToUpperInvariant(), offset.ToUpperInvariant(), question.Width.ToString(System.Globalization.CultureInfo.InvariantCulture) }),
            storageGuid, storageName);
    }

    internal bool SameTarget(FirmwareVerificationQuestion other) => this == other with { Id = Id };

    internal void Validate()
    {
        if (new[] { Id, Kind, OptionsFingerprint, StorageBinding, StorageGuid, StorageName }.Any(string.IsNullOrWhiteSpace) || Width is < 1 or > 8
            || !Regex.IsMatch(OptionsFingerprint, "^[0-9A-Fa-f]{64}$"))
            throw new InvalidDataException("The firmware question identity is incomplete or invalid.");
        if (!Regex.IsMatch(StorageGuid, "^[0-9A-Fa-f-]{36}$") || StorageBinding.Split('|') is not [var guid, var name, var token, var offset, var width]
            || guid != StorageGuid || name != StorageName || !Regex.IsMatch(token, "^[0-9A-Fa-f]+$")
            || !Regex.IsMatch(offset, "^[0-9A-Fa-f]+$") || width != Width.ToString(System.Globalization.CultureInfo.InvariantCulture))
            throw new InvalidDataException("The firmware question storage identity is incomplete or invalid.");
    }
}

public static class FirmwareSemanticProfile
{
    public static string Hash(FirmwareScript script)
    {
        var fields = new List<string> { script.Crc };
        foreach (var question in script.Questions)
        {
            fields.Add(string.Join("\u001f", new[]
            {
                question.Id, question.Context, question.Kind, question.Width.ToString(System.Globalization.CultureInfo.InvariantCulture),
                string.Join("\u001e", question.Options.Select(option => option.Value + "=" + option.Label)),
                script.Validate(question, question.Current), FirmwareVerificationQuestion.From(question).StorageGuid,
                FirmwareVerificationQuestion.From(question).StorageName,
                FirmwareVerificationQuestion.From(question).StorageBinding
            }.Select(Encode)));
        }
        return OperationFiles.Hash(Encoding.UTF8.GetBytes(string.Join("\u001d", fields)));
    }

    private static string Encode(string value) => Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
}

[method: JsonConstructor]
public sealed record FirmwareVerificationBinding(
    [property: JsonRequired] string MachineId,
    [property: JsonRequired] string Board,
    [property: JsonRequired] string BiosRevision,
    [property: JsonRequired] string BootIdentity,
    [property: JsonRequired] string HiiChecksum,
    [property: JsonRequired] string PackageFingerprint,
    [property: JsonRequired] string SessionHash,
    [property: JsonRequired] string OriginalExportHash,
    [property: JsonRequired] string OriginalExportPath,
    [property: JsonRequired] string BaselineProfileHash,
    [property: JsonRequired] FirmwareVerificationQuestion Question)
{
    public static FirmwareVerificationBinding FromOriginalExport(FirmwareSession session, string originalExportPath, string questionId)
        => FromOriginalExport(session, originalExportPath, questionId,
            OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(session, OperationFiles.Json)));

    public static FirmwareVerificationBinding FromOriginalExport(FirmwareSession session, string originalExportPath,
        string questionId, string sessionHash)
    {
        session.Identity.Validate();
        if (string.IsNullOrWhiteSpace(session.PackageFingerprint) || string.IsNullOrWhiteSpace(questionId))
            throw new InvalidDataException("The firmware session is missing its package or question identity.");
        if (!string.Equals(OperationFiles.HashFile(originalExportPath), session.BackupHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The original firmware export does not match the saved session hash.");
        var script = new FirmwareScript(File.ReadAllBytes(originalExportPath));
        var question = script.Questions.SingleOrDefault(item => item.Id == questionId)
            ?? throw new InvalidDataException("The original firmware export does not contain the reviewed question.");
        if (!Regex.IsMatch(sessionHash, "^[0-9A-Fa-f]{64}$"))
            throw new InvalidDataException("The firmware session hash is missing or invalid.");
        return new(session.Identity.MachineId, session.Identity.Board, session.Identity.Bios, session.Identity.Boot,
            script.Crc, session.PackageFingerprint, sessionHash, session.BackupHash, Path.GetFullPath(originalExportPath), FirmwareSemanticProfile.Hash(script),
            FirmwareVerificationQuestion.From(question));
    }

    [JsonIgnore] public string QuestionId => Question.Id;

    internal void Validate()
    {
        if (new[] { MachineId, Board, BiosRevision, BootIdentity, HiiChecksum, PackageFingerprint, SessionHash, OriginalExportHash, OriginalExportPath }
            .Any(string.IsNullOrWhiteSpace))
            throw new InvalidDataException("The firmware trial is missing a machine, board, BIOS, boot, HII, package or question identity.");
        if (!Regex.IsMatch(SessionHash, "^[0-9A-Fa-f]{64}$")
            || !Regex.IsMatch(OriginalExportHash, "^[0-9A-Fa-f]{64}$")
            || !System.Text.RegularExpressions.Regex.IsMatch(BaselineProfileHash, "^[0-9A-Fa-f]{64}$"))
            throw new InvalidDataException("The original BIOS export hash is missing or invalid.");
        if (!File.Exists(OriginalExportPath) || !string.Equals(OperationFiles.HashFile(OriginalExportPath), OriginalExportHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The original BIOS export is missing or its hash changed.");
        Question.Validate();
    }
}

[method: JsonConstructor]
public sealed record FirmwareVerificationEvidence(
    [property: JsonRequired] string Phase,
    [property: JsonRequired] string Method,
    [property: JsonRequired] string BehaviorOutcome,
    [property: JsonRequired] string ObservedValue,
    [property: JsonRequired] string BootIdentity,
    [property: JsonRequired] string FilePath,
    [property: JsonRequired] string FileHash,
    [property: JsonRequired] string AuxiliaryFilePath,
    [property: JsonRequired] string AuxiliaryFileHash,
    [property: JsonRequired] string Output,
    [property: JsonRequired] DateTimeOffset CapturedAt)
{
    public FirmwareVerificationEvidence(string phase, string method, string observedValue, string bootIdentity,
        string filePath, string fileHash, string output, DateTimeOffset capturedAt)
        : this(phase, method, FirmwareEvidencePhases.Behavior == phase ? FirmwareBehaviorOutcomes.Inconclusive : FirmwareBehaviorOutcomes.NotApplicable,
            observedValue, bootIdentity, filePath, fileHash, "", "", output, capturedAt) { }

    internal void Validate()
    {
        if (!FirmwareEvidencePhases.IsKnown(Phase) || string.IsNullOrWhiteSpace(Method)
            || !new[] { FirmwareBehaviorOutcomes.Changed, FirmwareBehaviorOutcomes.Unchanged, FirmwareBehaviorOutcomes.Inconclusive, FirmwareBehaviorOutcomes.NotApplicable }
                .Contains(BehaviorOutcome, StringComparer.Ordinal)
            || (Phase == FirmwareEvidencePhases.Behavior ? BehaviorOutcome is FirmwareBehaviorOutcomes.NotApplicable : BehaviorOutcome is not FirmwareBehaviorOutcomes.NotApplicable)
            || string.IsNullOrWhiteSpace(ObservedValue)
            || string.IsNullOrWhiteSpace(BootIdentity) || CapturedAt.Offset != TimeSpan.Zero)
            throw new InvalidDataException("Firmware evidence is incomplete or has an invalid phase, value, boot identity, output or timestamp.");
        if (string.IsNullOrWhiteSpace(FilePath) != string.IsNullOrWhiteSpace(FileHash))
            throw new InvalidDataException("Firmware evidence must provide both an evidence file and its SHA-256 hash.");
        if (!string.IsNullOrWhiteSpace(FileHash) && !System.Text.RegularExpressions.Regex.IsMatch(FileHash, "^[0-9A-Fa-f]{64}$"))
            throw new InvalidDataException("Firmware evidence file hashes must be SHA-256 values.");
        if (string.IsNullOrWhiteSpace(AuxiliaryFilePath) != string.IsNullOrWhiteSpace(AuxiliaryFileHash))
            throw new InvalidDataException("Firmware evidence must provide both auxiliary evidence file and hash.");
        if (!string.IsNullOrWhiteSpace(AuxiliaryFileHash) && !Regex.IsMatch(AuxiliaryFileHash, "^[0-9A-Fa-f]{64}$"))
            throw new InvalidDataException("Auxiliary firmware evidence file hashes must be SHA-256 values.");
        if (!string.IsNullOrWhiteSpace(FilePath))
        {
            var path = Path.GetFullPath(FilePath);
            if (!File.Exists(path) || !string.Equals(OperationFiles.HashFile(path), FileHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The firmware evidence file is missing or its hash changed.");
        }
        if (!string.IsNullOrWhiteSpace(AuxiliaryFilePath))
        {
            var path = Path.GetFullPath(AuxiliaryFilePath);
            if (!File.Exists(path) || !string.Equals(OperationFiles.HashFile(path), AuxiliaryFileHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The auxiliary firmware evidence file is missing or its hash changed.");
        }
    }
}

public sealed record FirmwareVerificationTrial(
    [property: JsonRequired] string Id,
    [property: JsonRequired] FirmwareVerificationBinding Binding,
    [property: JsonRequired] string BaselineValue,
    [property: JsonRequired] string TestValue,
    [property: JsonRequired] string Status,
    [property: JsonRequired] bool RestorationComplete,
    [property: JsonRequired] FirmwareVerificationEvidence[] Evidence,
    [property: JsonRequired] DateTimeOffset StartedAt,
    [property: JsonRequired] DateTimeOffset UpdatedAt)
{
    [JsonIgnore]
    public bool ConfirmedUnchanged => RestorationComplete
        && Status == FirmwareTrialStatuses.ActualBehaviorVerified
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restart && e.ObservedValue == TestValue)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.BehaviorOutcome == FirmwareBehaviorOutcomes.Unchanged)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.Method is not "firmwareExport" and not "readback")
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.BootIdentity != Binding.BootIdentity)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restoration && e.ObservedValue == BaselineValue)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Review)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Review && e.ObservedValue == TestValue)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Write)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Write && e.ObservedValue == TestValue)
        && Evidence.Where(e => e.Phase == FirmwareEvidencePhases.Restart).All(e => e.BootIdentity != Binding.BootIdentity)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restoration && (e.Method is "noInverse" or "inverse"));

    [JsonIgnore]
    public bool Complete => RestorationComplete;

    [JsonIgnore]
    public string EffectOutcome
        => Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.BehaviorOutcome == FirmwareBehaviorOutcomes.Changed)
            && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.BehaviorOutcome == FirmwareBehaviorOutcomes.Unchanged)
            ? FirmwareBehaviorOutcomes.Inconclusive
            : Evidence.LastOrDefault(e => e.Phase == FirmwareEvidencePhases.Behavior)?.BehaviorOutcome ?? FirmwareBehaviorOutcomes.Inconclusive;

    [JsonIgnore]
    public bool EffectVerified => RestorationComplete
        && Status == FirmwareTrialStatuses.ActualBehaviorVerified
        && EffectOutcome == FirmwareBehaviorOutcomes.Changed
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restart && e.ObservedValue == TestValue && e.BootIdentity != Binding.BootIdentity)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior && e.BehaviorOutcome == FirmwareBehaviorOutcomes.Changed
            && e.Method is not "firmwareExport" and not "readback" && e.BootIdentity != Binding.BootIdentity)
        && Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restoration && e.ObservedValue == BaselineValue);
}

public sealed class FirmwareVerificationStore
{
    private readonly string _root;

    public FirmwareVerificationStore(string root)
    {
        _root = Path.GetFullPath(root);
        Directory.CreateDirectory(_root);
    }

    public FirmwareVerificationTrial BeginTrial(FirmwareVerificationBinding binding, string baselineValue, string testValue,
        DateTimeOffset? startedAt = null)
    {
        binding.Validate();
        if (string.IsNullOrWhiteSpace(baselineValue) || string.IsNullOrWhiteSpace(testValue) || baselineValue == testValue)
            throw new InvalidDataException("A firmware trial needs distinct baseline and test values.");
        var now = startedAt ?? DateTimeOffset.UtcNow;
        if (now.Offset != TimeSpan.Zero || now > DateTimeOffset.UtcNow.AddMinutes(1))
            throw new InvalidDataException("The firmware trial start time must be a current UTC timestamp.");
        var trial = new FirmwareVerificationTrial(Guid.NewGuid().ToString("N"), binding, baselineValue, testValue,
            FirmwareTrialStatuses.Untested, false, [], now, now);
        OperationFiles.Write(PathFor(trial.Id), trial);
        return trial;
    }

    public FirmwareVerificationTrial Read(string id)
    {
        var trial = OperationFiles.Read<FirmwareVerificationTrial>(PathFor(ValidateId(id)));
        return ValidateTrial(trial);
    }

    public FirmwareVerificationTrial Record(string id, FirmwareVerificationBinding binding, string status,
        params FirmwareVerificationEvidence[] evidence)
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var trial = Read(id);
        VerifyBinding(trial, binding);
        if (!FirmwareTrialStatuses.IsKnown(status) || status == FirmwareTrialStatuses.Untested)
            throw new InvalidDataException("A firmware trial needs a concrete evidence status.");
        if (trial.RestorationComplete) throw new InvalidDataException("A restored firmware trial cannot receive more evidence.");
        if (evidence is null || evidence.Length == 0) throw new InvalidDataException("Firmware evidence cannot be empty.");
        foreach (var item in evidence) ValidateEvidence(trial, status, item);
        if (!CanTransition(trial.Status, status)) throw new InvalidDataException("Firmware evidence status moved backwards or conflicts with the existing trial.");
        var combined = trial.Evidence.Concat(evidence).ToArray();
        ValidateChronology(combined);
        ValidateStatus(trial, status, combined);
        var updated = trial with { Status = status, Evidence = combined, UpdatedAt = DateTimeOffset.UtcNow };
        OperationFiles.Write(PathFor(trial.Id), updated);
        return updated;
    }

    public FirmwareVerificationTrial CompleteRestoration(string id, FirmwareVerificationBinding binding,
        FirmwareVerificationEvidence evidence)
    {
        using var operation = OperationFiles.Lock(Path.Combine(_root, "operation"));
        var trial = Read(id);
        VerifyBinding(trial, binding);
        if (trial.Status == FirmwareTrialStatuses.Untested) throw new InvalidDataException("A firmware trial must have a write or test result before restoration.");
        if (trial.RestorationComplete) return trial;
        if (evidence.Phase != FirmwareEvidencePhases.Restoration || evidence.ObservedValue != trial.BaselineValue)
            throw new InvalidDataException("Restoration evidence must show the original BIOS value.");
        ValidateEvidence(trial, trial.Status, evidence);
        var combined = trial.Evidence.Append(evidence).ToArray();
        ValidateChronology(combined);
        var updated = trial with { RestorationComplete = true, Evidence = combined, UpdatedAt = DateTimeOffset.UtcNow };
        OperationFiles.Write(PathFor(trial.Id), updated);
        return updated;
    }

    public IReadOnlyList<FirmwareVerificationTrial> ReadConfirmedUnchanged()
        => Directory.EnumerateFiles(_root, "*.json", SearchOption.TopDirectoryOnly)
            .Where(path => Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out _))
            .Select(path => Read(Path.GetFileNameWithoutExtension(path)))
            .Where(trial => trial.ConfirmedUnchanged)
            .ToArray();

    public IReadOnlyList<FirmwareVerificationMatch> ReadMatchingTrials(FirmwareIdentity currentIdentity,
        string packageFingerprint, string currentExportPath)
    {
        var trials = new List<FirmwareVerificationTrial>();
        foreach (var path in Directory.EnumerateFiles(_root, "*.json", SearchOption.TopDirectoryOnly).Where(path => Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out _)))
        {
            try { trials.Add(Read(Path.GetFileNameWithoutExtension(path))); }
            catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
        }
        var current = ReadCurrent(currentIdentity, packageFingerprint, currentExportPath);
        return trials.Select(trial =>
        {
            try
            {
                var (status, questionId) = MatchStatus(trial, current);
                return new FirmwareVerificationMatch(trial, status, questionId);
            }
            catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException)
            {
                return new FirmwareVerificationMatch(trial, FirmwareVerificationMatchStatuses.Unavailable, "");
            }
        }).ToArray();
    }

    public Task<IReadOnlyList<FirmwareVerificationMatch>> ReadMatchingTrialsAsync(FirmwareIdentity currentIdentity,
        string packageFingerprint, string currentExportPath, CancellationToken cancellationToken = default)
        => Task.Run(() => ReadMatchingTrials(currentIdentity, packageFingerprint, currentExportPath), cancellationToken);

    public IReadOnlyList<FirmwareVerificationTrial> ReadConfirmedUnchanged(FirmwareIdentity currentIdentity,
        string packageFingerprint, string currentExportPath)
        => ReadMatchingTrials(currentIdentity, packageFingerprint, currentExportPath)
            .Where(match => match.Matches && match.Trial.ConfirmedUnchanged)
            .Select(match => match.Trial)
            .ToArray();

    public bool MatchesBaseline(string id, FirmwareIdentity currentIdentity, string packageFingerprint, string currentExportPath)
    {
        try
        {
            var trial = Read(id);
            return MatchStatus(trial, ReadCurrent(currentIdentity, packageFingerprint, currentExportPath)).Status
                == FirmwareVerificationMatchStatuses.Matched;
        }
        catch (InvalidDataException) { return false; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static (FirmwareIdentity Identity, string Package, FirmwareScript? Script, string Status) ReadCurrent(
        FirmwareIdentity currentIdentity, string packageFingerprint, string currentExportPath)
    {
        try
        {
            currentIdentity.Validate();
            if (string.IsNullOrWhiteSpace(packageFingerprint)) return (currentIdentity, packageFingerprint, null, FirmwareVerificationMatchStatuses.UnknownCurrent);
            return (currentIdentity, packageFingerprint, new FirmwareScript(File.ReadAllBytes(currentExportPath)), FirmwareVerificationMatchStatuses.Matched);
        }
        catch (InvalidDataException) { return (currentIdentity, packageFingerprint, null, FirmwareVerificationMatchStatuses.UnknownCurrent); }
        catch (IOException) { return (currentIdentity, packageFingerprint, null, FirmwareVerificationMatchStatuses.UnknownCurrent); }
    }

    private static (string Status, string QuestionId) MatchStatus(FirmwareVerificationTrial trial,
        (FirmwareIdentity Identity, string Package, FirmwareScript? Script, string Status) current)
    {
        if (current.Status == FirmwareVerificationMatchStatuses.UnknownCurrent) return (current.Status, "");
        if (!trial.Binding.MachineId.Equals(current.Identity.MachineId, StringComparison.Ordinal)) return (FirmwareVerificationMatchStatuses.DifferentMachine, "");
        if (!trial.Binding.Board.Equals(current.Identity.Board, StringComparison.Ordinal)) return (FirmwareVerificationMatchStatuses.DifferentBoard, "");
        if (!trial.Binding.BiosRevision.Equals(current.Identity.Bios, StringComparison.Ordinal)) return (FirmwareVerificationMatchStatuses.DifferentBios, "");
        if (!string.Equals(trial.Binding.PackageFingerprint, current.Package, StringComparison.Ordinal)) return (FirmwareVerificationMatchStatuses.DifferentPackage, "");
        if (current.Script is null) return (FirmwareVerificationMatchStatuses.DifferentProfile, "");
        var original = new FirmwareScript(File.ReadAllBytes(trial.Binding.OriginalExportPath));
        var reviewed = original.Questions.SingleOrDefault(item => item.Id == trial.Binding.Question.Id);
        var question = reviewed is null || FirmwareSemanticProfile.Hash(original) != trial.Binding.BaselineProfileHash || !original.SameValues(current.Script)
            ? null : original.Counterpart(reviewed, current.Script);
        return question is not null && FirmwareVerificationQuestion.From(question).SameTarget(trial.Binding.Question)
            ? (FirmwareVerificationMatchStatuses.Matched, question.Id)
            : (FirmwareVerificationMatchStatuses.DifferentProfile, "");
    }

    private void VerifyBinding(FirmwareVerificationTrial trial, FirmwareVerificationBinding binding)
    {
        binding.Validate();
        if (trial.Binding != binding) throw new InvalidDataException("The firmware evidence belongs to a different PC, BIOS, package or question.");
    }

    private static void ValidateEvidence(FirmwareVerificationTrial trial, string status, FirmwareVerificationEvidence evidence)
    {
        evidence.Validate();
        if (evidence.Phase is FirmwareEvidencePhases.Baseline or FirmwareEvidencePhases.Review or FirmwareEvidencePhases.Write
            or FirmwareEvidencePhases.Immediate or FirmwareEvidencePhases.Restart or FirmwareEvidencePhases.Behavior
            or FirmwareEvidencePhases.Restoration)
        {
            if (string.IsNullOrWhiteSpace(evidence.FilePath) || string.IsNullOrWhiteSpace(evidence.FileHash))
                throw new InvalidDataException("Firmware evidence needs the exact readback or command artifact and its hash.");
        }
        if (evidence.CapturedAt < trial.StartedAt || evidence.CapturedAt > DateTimeOffset.UtcNow.AddMinutes(1))
            throw new InvalidDataException("Firmware evidence is stale or dated in the future.");
        if ((evidence.Phase is FirmwareEvidencePhases.Baseline or FirmwareEvidencePhases.Review or FirmwareEvidencePhases.Write or FirmwareEvidencePhases.Immediate)
            && evidence.BootIdentity != trial.Binding.BootIdentity)
            throw new InvalidDataException("Firmware evidence has the wrong boot identity.");
        if (evidence.Phase == FirmwareEvidencePhases.Restart && evidence.BootIdentity == trial.Binding.BootIdentity)
            throw new InvalidDataException("Restart evidence needs a changed boot identity.");
        if (evidence.Phase == FirmwareEvidencePhases.Behavior && (evidence.Method is "firmwareExport" or "readback"))
            throw new InvalidDataException("Behavior evidence needs a distinct observation method.");
        if (evidence.Phase == FirmwareEvidencePhases.Restoration && evidence.ObservedValue != trial.BaselineValue)
            throw new InvalidDataException("Restoration evidence must show the baseline value.");
        if (evidence.Phase == FirmwareEvidencePhases.Review) ValidateReviewArtifact(trial, evidence);
        if (evidence.Phase == FirmwareEvidencePhases.Write) ValidateWriteArtifact(trial, evidence, status == FirmwareTrialStatuses.WriteRejected);
        if (evidence.Phase is FirmwareEvidencePhases.Baseline or FirmwareEvidencePhases.Immediate
            or FirmwareEvidencePhases.Restart)
            ValidateFirmwareReadback(trial, evidence);
        if (evidence.Phase == FirmwareEvidencePhases.Restoration) ValidateRestorationArtifact(trial, evidence);
    }

    private static void ValidateStatus(FirmwareVerificationTrial trial, string status, FirmwareVerificationEvidence[] evidence)
    {
        if (status is not (FirmwareTrialStatuses.Inconclusive or FirmwareTrialStatuses.Untested)
            && (!evidence.Any(e => e.Phase == FirmwareEvidencePhases.Review)
                || !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Write)
                || !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Review && e.ObservedValue == trial.TestValue)
                || !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Write && e.ObservedValue == trial.TestValue)))
            throw new InvalidDataException("A firmware result needs the reviewed script and attempted write evidence.");
        if (status == FirmwareTrialStatuses.WriteRejected && !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Write))
            throw new InvalidDataException("A rejected write needs native command evidence.");
        if (status == FirmwareTrialStatuses.UnchangedImmediately && !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Immediate && e.ObservedValue == trial.BaselineValue))
            throw new InvalidDataException("Immediate unchanged status needs a baseline readback.");
        if (status == FirmwareTrialStatuses.ValueStored && !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Immediate && e.ObservedValue == trial.TestValue))
            throw new InvalidDataException("Stored-value status needs a test-value readback.");
        if (status == FirmwareTrialStatuses.PersistedAfterRestart && !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restart && e.ObservedValue == trial.TestValue))
            throw new InvalidDataException("Restart-persisted status needs a test-value readback after restart.");
        if (status == FirmwareTrialStatuses.ActualBehaviorVerified && !evidence.Any(e => e.Phase == FirmwareEvidencePhases.Behavior
            && e.Method is not "firmwareExport" and not "readback"
            && (e.BehaviorOutcome is FirmwareBehaviorOutcomes.Changed or FirmwareBehaviorOutcomes.Unchanged)))
            throw new InvalidDataException("Behavior verification needs behavior evidence.");
        if (status == FirmwareTrialStatuses.Inconclusive && evidence.Length == 0)
            throw new InvalidDataException("An inconclusive result still needs evidence.");
    }

    private static bool CanTransition(string current, string next)
        => current == next || (current, next) switch
        {
            (FirmwareTrialStatuses.Untested, FirmwareTrialStatuses.WriteRejected or FirmwareTrialStatuses.UnchangedImmediately
                or FirmwareTrialStatuses.ValueStored or FirmwareTrialStatuses.Inconclusive) => true,
            (FirmwareTrialStatuses.UnchangedImmediately, FirmwareTrialStatuses.ActualBehaviorVerified or FirmwareTrialStatuses.Inconclusive) => true,
            (FirmwareTrialStatuses.ValueStored, FirmwareTrialStatuses.PersistedAfterRestart or FirmwareTrialStatuses.Inconclusive) => true,
            (FirmwareTrialStatuses.PersistedAfterRestart, FirmwareTrialStatuses.ActualBehaviorVerified or FirmwareTrialStatuses.Inconclusive) => true,
            _ => false
        };

    private static FirmwareVerificationTrial ValidateTrial(FirmwareVerificationTrial trial)
    {
        if (!Guid.TryParseExact(trial.Id, "N", out _) || string.IsNullOrWhiteSpace(trial.BaselineValue)
            || string.IsNullOrWhiteSpace(trial.TestValue) || trial.BaselineValue == trial.TestValue
            || !FirmwareTrialStatuses.IsKnown(trial.Status) || trial.Evidence is null)
            throw new InvalidDataException("Saved firmware trial data is incomplete or contradictory.");
        trial.Binding.Validate();
        foreach (var evidence in trial.Evidence) ValidateEvidence(trial, trial.Status, evidence);
        ValidateChronology(trial.Evidence);
        ValidateStatus(trial, trial.Status, trial.Evidence);
        if (trial.RestorationComplete && !trial.Evidence.Any(e => e.Phase == FirmwareEvidencePhases.Restoration && e.ObservedValue == trial.BaselineValue))
            throw new InvalidDataException("Saved firmware trial data claims restoration without restoration evidence.");
        return trial;
    }

    private static void ValidateFirmwareReadback(FirmwareVerificationTrial trial, FirmwareVerificationEvidence evidence)
    {
        if (evidence.Phase != FirmwareEvidencePhases.Baseline
            && string.Equals(Path.GetFullPath(evidence.FilePath), trial.Binding.OriginalExportPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("A later firmware readback cannot reuse the original pre-write artifact.");
        var original = new FirmwareScript(File.ReadAllBytes(trial.Binding.OriginalExportPath));
        var reviewed = original.Questions.SingleOrDefault(item => item.Id == trial.Binding.Question.Id)
            ?? throw new InvalidDataException("The original firmware export does not contain the reviewed question.");
        var script = new FirmwareScript(File.ReadAllBytes(evidence.FilePath));
        if (original.Crc != trial.Binding.HiiChecksum || !original.SameLayout(script))
            throw new InvalidDataException("Firmware readback has a different HII checksum.");
        var question = original.Counterpart(reviewed, script)
            ?? throw new InvalidDataException("Firmware readback does not contain the reviewed question.");
        if (!FirmwareVerificationQuestion.From(question).SameTarget(trial.Binding.Question))
            throw new InvalidDataException("Firmware readback question type, options or storage binding changed.");
        if (script.Validate(question, question.Current) != evidence.ObservedValue)
            throw new InvalidDataException("Firmware readback value disagrees with the recorded observation.");
        if (evidence.Phase == FirmwareEvidencePhases.Restoration && !original.SameValues(script))
            throw new InvalidDataException("Restoration readback differs from the complete original firmware profile.");
    }

    private static void ValidateReviewArtifact(FirmwareVerificationTrial trial, FirmwareVerificationEvidence evidence, bool inverse = false)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(evidence.FilePath))!;
        var review = ReadArtifact<FirmwareReview>(evidence.FilePath);
        if ((!inverse && review.SessionHash != trial.Binding.SessionHash) || review.Changes is null || review.Changes.Length != 1)
            throw new InvalidDataException("The reviewed firmware artifact is for a different session or target set.");
        var sessionPath = Path.Combine(directory, "session.json");
        var session = ReadArtifact<FirmwareSession>(sessionPath, review.SessionHash);
        if (session.PackageFingerprint != trial.Binding.PackageFingerprint || (!inverse && session.BackupHash != trial.Binding.OriginalExportHash)
            || session.Identity.MachineId != trial.Binding.MachineId || session.Identity.Board != trial.Binding.Board
            || session.Identity.Bios != trial.Binding.BiosRevision || session.Identity.Boot != trial.Binding.BootIdentity)
            throw new InvalidDataException("The reviewed firmware session does not match the evidence binding.");
        var change = review.Changes[0];
        var expectedBefore = inverse ? trial.TestValue : trial.BaselineValue;
        var expectedAfter = inverse ? trial.BaselineValue : trial.TestValue;
        var original = new FirmwareScript(File.ReadAllBytes(trial.Binding.OriginalExportPath));
        var originalQuestion = original.Questions.SingleOrDefault(item => item.Id == trial.Binding.Question.Id)
            ?? throw new InvalidDataException("The original firmware export does not contain the reviewed question.");
        if (change.Id != trial.Binding.Question.Id || change.Name != originalQuestion.Name
            || change.Before != expectedBefore || change.After != expectedAfter
            || change.BeforeLabel != originalQuestion.DisplayValue(expectedBefore)
            || change.AfterLabel != originalQuestion.DisplayValue(expectedAfter))
            throw new InvalidDataException("The reviewed firmware target or values do not match the trial.");
        var changesPath = Path.Combine(directory, "changes.txt");
        if (!string.Equals(OperationFiles.HashFile(changesPath), review.ScriptHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The reviewed firmware script hash does not match review.json.");
        var script = new FirmwareScript(File.ReadAllBytes(changesPath));
        if (script.Crc != trial.Binding.HiiChecksum || script.Questions.Count != 1)
            throw new InvalidDataException("The reviewed firmware script is not bound to the original HII export.");
        var question = script.Questions.SingleOrDefault(item => item.Name == originalQuestion.Name
            && SameQuestionShape(FirmwareVerificationQuestion.From(item), trial.Binding.Question));
        if (question is null
            || script.Validate(question, question.Current) != (inverse ? trial.BaselineValue : trial.TestValue))
            throw new InvalidDataException("The reviewed firmware script target or value is not the approved trial.");
    }

    private static bool SameQuestionShape(FirmwareVerificationQuestion actual, FirmwareVerificationQuestion expected)
        => actual.Kind == expected.Kind && actual.Width == expected.Width
            && actual.OptionsFingerprint == expected.OptionsFingerprint
            && actual.StorageGuid == expected.StorageGuid
            && actual.StorageName == expected.StorageName
            && actual.StorageBinding == expected.StorageBinding;

    private static void ValidateWriteArtifact(FirmwareVerificationTrial trial, FirmwareVerificationEvidence evidence, bool rejected, bool inverse = false)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(evidence.FilePath))!;
        var journal = ReadArtifact<FirmwareJournal>(evidence.FilePath);
        var reviewPath = Path.Combine(directory, "review.json");
        var reviewHash = OperationFiles.HashFile(reviewPath);
        if (journal.ReviewHash != reviewHash || journal.Result is null)
            throw new InvalidDataException("The firmware journal is missing its exact review or native command result.");
        if (rejected ? journal.Result.Succeeded || journal.Status != "needsAttention" : !journal.Result.Succeeded
            || journal.Status is not ("restartRequired" or "applied"))
            throw new InvalidDataException("The firmware journal outcome does not authorize this trial status.");
        ValidateReviewArtifact(trial, new FirmwareVerificationEvidence(FirmwareEvidencePhases.Review, "workflowReview", FirmwareBehaviorOutcomes.NotApplicable, trial.TestValue,
            trial.Binding.BootIdentity, reviewPath, OperationFiles.HashFile(reviewPath), "", "", "review", evidence.CapturedAt), inverse);
    }

    private static void ValidateRestorationArtifact(FirmwareVerificationTrial trial, FirmwareVerificationEvidence evidence)
    {
        if (evidence.Method == "noInverse")
        {
            var unchanged = trial.Status == FirmwareTrialStatuses.ActualBehaviorVerified
                && trial.Evidence.Any(item => item.Phase == FirmwareEvidencePhases.Immediate && item.ObservedValue == trial.BaselineValue)
                && trial.Evidence.Any(item => item.Phase == FirmwareEvidencePhases.Restart && item.ObservedValue == trial.BaselineValue);
            var rejected = trial.Status == FirmwareTrialStatuses.WriteRejected
                && trial.Evidence.Any(item => item.Phase == FirmwareEvidencePhases.Immediate && item.ObservedValue == trial.BaselineValue);
            if (!string.IsNullOrWhiteSpace(evidence.AuxiliaryFilePath) || (!unchanged && !rejected))
                throw new InvalidDataException("No-inverse restoration requires a completed unchanged observation or a rejected write readback.");
            ValidateFirmwareReadback(trial, evidence);
            return;
        }
        if (evidence.Method != "inverse" || string.IsNullOrWhiteSpace(evidence.AuxiliaryFilePath))
            throw new InvalidDataException("Restoration must identify either no inverse or an inverse command and readback.");
        ValidateWriteArtifact(trial, evidence, false, true);
        ValidateFirmwareReadback(trial, evidence with
        {
            Phase = FirmwareEvidencePhases.Restoration,
            Method = "firmwareExport",
            FilePath = evidence.AuxiliaryFilePath,
            FileHash = evidence.AuxiliaryFileHash,
            AuxiliaryFilePath = "",
            AuxiliaryFileHash = ""
        });
    }

    private static T ReadArtifact<T>(string path, string? expectedHash = null)
    {
        try { return OperationFiles.Read<T>(path, expectedHash); }
        catch (JsonException error) { throw new InvalidDataException("Firmware authority artifact is not valid JSON.", error); }
    }

    private static void ValidateChronology(FirmwareVerificationEvidence[] evidence)
    {
        var lastPhase = -1;
        DateTimeOffset? lastTime = null;
        foreach (var item in evidence)
        {
            var phase = item.Phase switch
            {
                FirmwareEvidencePhases.Baseline => 0,
                FirmwareEvidencePhases.Review => 1,
                FirmwareEvidencePhases.Write => 2,
                FirmwareEvidencePhases.Immediate => 3,
                FirmwareEvidencePhases.Restart => 4,
                FirmwareEvidencePhases.Behavior => 5,
                FirmwareEvidencePhases.Restoration => 6,
                _ => throw new InvalidDataException("Firmware evidence has an unknown phase.")
            };
            if (phase < lastPhase || (lastTime is not null && item.CapturedAt < lastTime.Value))
                throw new InvalidDataException("Firmware evidence phases or timestamps are out of order.");
            lastPhase = phase;
            lastTime = item.CapturedAt;
        }
    }

    private string PathFor(string id) => Path.Combine(_root, ValidateId(id) + ".json");

    private static string ValidateId(string id)
    {
        if (!Guid.TryParseExact(id, "N", out _)) throw new InvalidDataException("The firmware trial identity is invalid.");
        return id;
    }
}
