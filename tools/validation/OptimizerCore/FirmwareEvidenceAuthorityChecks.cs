using System.Text;
using RooIndustries.Optimizer;

static class FirmwareEvidenceAuthorityChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-firmware-authority-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var script = new FirmwareScript(Encoding.UTF8.GetBytes(FirmwareChecks.ExportText));
            var question = script.Questions.Single(item => item.Name == "Performance mode");
            var baselinePath = Path.Combine(root, "original.txt");
            var baselineReadbackPath = Path.Combine(root, "readback.txt");
            var changesPath = Path.Combine(root, "changes.txt");
            var reviewPath = Path.Combine(root, "review.json");
            var journalPath = Path.Combine(root, "journal.json");
            var copiedWritePath = Path.Combine(root, "copied-write.txt");
            File.WriteAllText(baselinePath, FirmwareChecks.ExportText);
            File.Copy(baselinePath, baselineReadbackPath);
            File.WriteAllBytes(changesPath, script.Changes(new Dictionary<string, string> { [question.Id] = "01" }));
            var identity = new FirmwareIdentity("authority-pc", "authority-board", "F4", "boot-1");
            var session = new FirmwareSession("authority", identity, "package", OperationFiles.HashFile(baselinePath), DateTimeOffset.UtcNow);
            var sessionPath = Path.Combine(root, "session.json");
            OperationFiles.Write(sessionPath, session);
            var binding = FirmwareVerificationBinding.FromOriginalExport(session, baselinePath, question.Id, OperationFiles.HashFile(sessionPath));
            var change = new FirmwareChange(question.Id, question.Name, "00", "01", "Balanced", "Performance");
            OperationFiles.Write(reviewPath, new FirmwareReview(OperationFiles.HashFile(sessionPath), OperationFiles.HashFile(changesPath), [change]));
            OperationFiles.Write(journalPath, new FirmwareJournal(OperationFiles.HashFile(reviewPath), "restartRequired", "Native import completed", new FirmwareCommandResult(0, "native import completed", ""), DateTimeOffset.UtcNow));
            File.Copy(changesPath, copiedWritePath);
            var store = new FirmwareVerificationStore(root);
            static FirmwareVerificationEvidence Evidence(string phase, string method, string value, string boot, string path, DateTimeOffset capturedAt)
                => new(phase, method, FirmwareBehaviorOutcomes.NotApplicable, value, boot, path, OperationFiles.HashFile(path), "", "", "artifact", capturedAt);
            var now = DateTimeOffset.UtcNow;
            var review = Evidence(FirmwareEvidencePhases.Review, "review", "01", "boot-1", reviewPath, now);
            var immediate = Evidence(FirmwareEvidencePhases.Immediate, "firmwareExport", "00", "boot-1", baselineReadbackPath, now);
            var copiedWrite = Evidence(FirmwareEvidencePhases.Write, "import", "01", "boot-1", copiedWritePath, now);
            var trial = store.BeginTrial(binding, "00", "01", now.AddMinutes(-1));
            var accepted = false;
            try { store.Record(trial.Id, binding, FirmwareTrialStatuses.ValueStored, review, copiedWrite, immediate); }
            catch (InvalidDataException) { }
            accepted = store.Read(trial.Id).Status == FirmwareTrialStatuses.ValueStored;
            check(!accepted, "A copied change script and success-looking output cannot prove a native firmware write");

            var reversed = store.BeginTrial(binding, "00", "01", now.AddMinutes(-5));
            var write = Evidence(FirmwareEvidencePhases.Write, "import", "01", "boot-1", journalPath, now.AddMinutes(-3));
            var reversedAccepted = false;
            try
            {
                store.Record(reversed.Id, binding, FirmwareTrialStatuses.ValueStored,
                    review with { CapturedAt = now.AddMinutes(-1) }, write, immediate with { CapturedAt = now.AddMinutes(-2) });
                reversedAccepted = true;
            }
            catch (InvalidDataException) { }
            check(!reversedAccepted, "Firmware evidence phases must be rejected when their timestamps run backwards");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
        check(!Directory.Exists(root), "Firmware authority fixtures remove their evidence files");
    }
}
