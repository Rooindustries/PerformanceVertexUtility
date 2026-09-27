using System.Text;
using RooIndustries.Optimizer;

static class FirmwareVerificationChecks
{
    public static void Run(Action<bool, string> check)
    {
        void Reject(Action action, string message)
        {
            var rejected = false;
            try { action(); } catch (Exception error) when (error is InvalidDataException or IOException) { rejected = true; }
            check(rejected, message);
        }

        var root = Path.Combine(Path.GetTempPath(), "roo-industries-firmware-evidence-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var script = new FirmwareScript(Encoding.UTF8.GetBytes(FirmwareChecks.ExportText));
        var firmwareQuestion = script.Questions.Single(question => question.Name == "Performance mode");
        var baselinePath = Path.Combine(root, "baseline.txt");
        var baselineReadbackPath = Path.Combine(root, "baseline-readback.txt");
        var changedPath = Path.Combine(root, "changed.txt");
        var restartBaselinePath = Path.Combine(root, "restart-baseline.txt");
        var reviewPath = Path.Combine(root, "review.json");
        var sessionPath = Path.Combine(root, "session.json");
        var changesPath = Path.Combine(root, "changes.txt");
        var writePath = Path.Combine(root, "journal.json");
        var rejectedWritePath = Path.Combine(root, "rejected-journal.json");
        var inverseRoot = Path.Combine(root, "inverse");
        var behaviorPath = Path.Combine(root, "behavior.log");
        var wrongChecksumPath = Path.Combine(root, "wrong-checksum.txt");
        var wrongShapePath = Path.Combine(root, "wrong-shape.txt");
        File.WriteAllText(baselinePath, FirmwareChecks.ExportText);
        File.Copy(baselinePath, baselineReadbackPath);
        File.Copy(baselinePath, restartBaselinePath);
        File.WriteAllBytes(changedPath, script.Changes(new Dictionary<string, string> { [firmwareQuestion.Id] = "01" }));
        File.WriteAllBytes(changesPath, File.ReadAllBytes(changedPath));
        File.WriteAllText(behaviorPath, "benchmark readback and workload trace");
        File.WriteAllText(wrongChecksumPath, FirmwareChecks.ExportText.Replace("A1B2C3D4", "DEADBEEF", StringComparison.Ordinal));
        File.WriteAllText(wrongShapePath, FirmwareChecks.ExportText.Replace("[01]Performance", "[01]Turbo", StringComparison.Ordinal));
        var identity = new FirmwareIdentity("pc-1", "board-1", "F4", "boot-1");
        var session = new FirmwareSession("fixture", identity, "package-1", OperationFiles.HashFile(baselinePath), DateTimeOffset.UtcNow);
        OperationFiles.Write(sessionPath, session);
        var binding = FirmwareVerificationBinding.FromOriginalExport(session, baselinePath, firmwareQuestion.Id, OperationFiles.HashFile(sessionPath));
        var reviewChange = new FirmwareChange(firmwareQuestion.Id, firmwareQuestion.Name, "00", "01", "Balanced", "Performance");
        OperationFiles.Write(reviewPath, new FirmwareReview(OperationFiles.HashFile(sessionPath), OperationFiles.HashFile(changesPath), [reviewChange]));
        var now = DateTimeOffset.UtcNow;
        OperationFiles.Write(writePath, new FirmwareJournal(OperationFiles.HashFile(reviewPath), "restartRequired", "Native import completed", new FirmwareCommandResult(0, "native import completed", ""), now));
        OperationFiles.Write(rejectedWritePath, new FirmwareJournal(OperationFiles.HashFile(reviewPath), "needsAttention", "Native import rejected", new FirmwareCommandResult(13, "d - Unknown Error...", "- ERROR: Script file error."), now));
        Directory.CreateDirectory(inverseRoot);
        var inverseSessionPath = Path.Combine(inverseRoot, "session.json");
        OperationFiles.Write(inverseSessionPath, session with { Id = "inverse", BackupHash = OperationFiles.HashFile(changedPath) });
        var changedScript = new FirmwareScript(File.ReadAllBytes(changedPath));
        File.WriteAllBytes(Path.Combine(inverseRoot, "changes.txt"), changedScript.Changes(new Dictionary<string, string> { [firmwareQuestion.Id] = "00" }));
        OperationFiles.Write(Path.Combine(inverseRoot, "review.json"), new FirmwareReview(OperationFiles.HashFile(inverseSessionPath), OperationFiles.HashFile(Path.Combine(inverseRoot, "changes.txt")), [new FirmwareChange(firmwareQuestion.Id, firmwareQuestion.Name, "01", "00", "Performance", "Balanced")]));
        OperationFiles.Write(Path.Combine(inverseRoot, "journal.json"), new FirmwareJournal(OperationFiles.HashFile(Path.Combine(inverseRoot, "review.json")), "applied", "Native inverse completed", new FirmwareCommandResult(0, "native inverse completed", ""), now));
        var question = binding.Question;
        var store = new FirmwareVerificationStore(root);
        static FirmwareVerificationEvidence Evidence(string phase, string method, string outcome, string value, string boot, string file, string output, DateTimeOffset capturedAt, string auxiliary = "")
            => new(phase, method, outcome, value, boot, file, OperationFiles.HashFile(file), auxiliary, string.IsNullOrWhiteSpace(auxiliary) ? "" : OperationFiles.HashFile(auxiliary), output, capturedAt);
        var review = Evidence(FirmwareEvidencePhases.Review, "review", FirmwareBehaviorOutcomes.NotApplicable, "01", "boot-1", reviewPath, "Review accepted", now);
        var write = Evidence(FirmwareEvidencePhases.Write, "import", FirmwareBehaviorOutcomes.NotApplicable, "01", "boot-1", writePath, "Import completed", now);
        var rejectedWrite = Evidence(FirmwareEvidencePhases.Write, "import", FirmwareBehaviorOutcomes.NotApplicable, "01", "boot-1", rejectedWritePath, "Import rejected", now);
        var baseline = Evidence(FirmwareEvidencePhases.Immediate, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-1", baselineReadbackPath, "Readback 00", now);
        var restartBaseline = Evidence(FirmwareEvidencePhases.Restart, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-2", restartBaselinePath, "Readback 00 after restart", now);
        var changed = Evidence(FirmwareEvidencePhases.Immediate, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "01", "boot-1", changedPath, "Readback 01", now);
        var restartChanged = Evidence(FirmwareEvidencePhases.Restart, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "01", "boot-2", changedPath, "Readback 01 after restart", now);
        var behavior = Evidence(FirmwareEvidencePhases.Behavior, "benchmark", FirmwareBehaviorOutcomes.Unchanged, "00", "boot-2", behaviorPath, "The test value had no observable effect", now);
        var changedBehavior = Evidence(FirmwareEvidencePhases.Behavior, "benchmark", FirmwareBehaviorOutcomes.Changed, "01", "boot-2", behaviorPath, "Observed the changed behavior", now);
        var restoration = Evidence(FirmwareEvidencePhases.Restoration, "noInverse", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-2", baselineReadbackPath, "Restored original value", now);
        var inverseRestoration = Evidence(FirmwareEvidencePhases.Restoration, "inverse", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-2", Path.Combine(inverseRoot, "journal.json"), "Restored original value", now, baselineReadbackPath);
        var trialStart = DateTimeOffset.UtcNow.AddMinutes(-1);
        try
        {
            Reject(() => FirmwareVerificationBinding.FromOriginalExport(session, changedPath, firmwareQuestion.Id),
                "A different original artifact cannot establish the baseline profile");
            Reject(() => store.BeginTrial(binding, "00", "00"), "A trial cannot use the same baseline and test value");
            var unchanged = store.BeginTrial(binding, "00", "01", trialStart);
            var immediate = store.Record(unchanged.Id, binding, FirmwareTrialStatuses.UnchangedImmediately, review, write, baseline);
            check(immediate.Status == FirmwareTrialStatuses.UnchangedImmediately && !immediate.Complete,
                "Immediate unchanged readback remains explicitly incomplete");
            var afterRestart = store.Record(unchanged.Id, binding, FirmwareTrialStatuses.ActualBehaviorVerified,
                restartBaseline, behavior);
            check(!afterRestart.ConfirmedUnchanged, "Post-restart behavior is not classified until restoration completes");
            var sameBootEffect = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(sameBootEffect.Id, binding, FirmwareTrialStatuses.UnchangedImmediately, review, write, baseline);
            var sameBootChanged = store.Record(sameBootEffect.Id, binding, FirmwareTrialStatuses.ActualBehaviorVerified,
                changedBehavior with { BootIdentity = "boot-1" });
            check(!sameBootChanged.EffectVerified, "A same-boot changed observation cannot be labeled effect verified");
            var restored = store.CompleteRestoration(unchanged.Id, binding,
                restoration);
            check(!restored.ConfirmedUnchanged && store.ReadConfirmedUnchanged().Count == 0,
                "An unstored write with no observed effect remains outside the collapsed settings query");
            var headerVariantPath = Path.Combine(root, "restored-with-new-header.txt");
            File.WriteAllText(headerVariantPath, "Fresh export header\n" + FirmwareChecks.ExportText);
            check(store.MatchesBaseline(unchanged.Id, identity with { Boot = "boot-2" }, "package-1", headerVariantPath),
                "A later boot and fresh export header still match the semantic baseline profile");
            var unrelatedChangePath = Path.Combine(root, "restored-with-unrelated-change.txt");
            File.WriteAllText(unrelatedChangePath, FirmwareChecks.ExportText.Replace("Value =0A", "Value =0B", StringComparison.Ordinal));
            check(!store.MatchesBaseline(unchanged.Id, identity with { Boot = "boot-2" }, "package-1", unrelatedChangePath),
                "A changed unrelated firmware setting invalidates the semantic baseline match");
            var storageMetadataChangePath = Path.Combine(root, "restored-with-storage-metadata-change.txt");
            File.WriteAllText(storageMetadataChangePath, FirmwareChecks.ExportText.Replace("// Variable = Setup", "// Variable = OtherSetup", StringComparison.Ordinal));
            check(store.ReadMatchingTrials(identity with { Boot = "boot-2" }, "package-1", storageMetadataChangePath)
                .Single(item => item.Trial.Id == unchanged.Id).CurrentStatus == FirmwareVerificationMatchStatuses.DifferentProfile,
                "A changed native variable name invalidates the semantic baseline match");
            check(store.ReadConfirmedUnchanged(identity with { Boot = "boot-2" }, "package-1", headerVariantPath).Count == 0,
                "The collapsed query applies the current machine, board, BIOS, package and semantic profile match");
            var noWrite = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(noWrite.Id, binding, FirmwareTrialStatuses.Inconclusive, baseline);
            check(!store.Read(noWrite.Id).Complete && !store.Read(noWrite.Id).ConfirmedUnchanged,
                "A no-write readback remains outside the confirmed unchanged menu");
            var matching = store.ReadMatchingTrials(identity with { Boot = "boot-2" }, "package-1", headerVariantPath);
            check(matching.Single(item => item.Trial.Id == unchanged.Id).Matches
                && matching.Single(item => item.Trial.Id == unchanged.Id).Trial.Status == FirmwareTrialStatuses.ActualBehaviorVerified,
                "The current-context query returns verified evidence and its positive match together");
            var asyncMatching = store.ReadMatchingTrialsAsync(identity with { Boot = "boot-2" }, "package-1", headerVariantPath)
                .GetAwaiter().GetResult();
            check(asyncMatching.Count == matching.Count, "Current-context evidence can load asynchronously without a second matching implementation");
            var negativeMatching = store.ReadMatchingTrials(identity with { Boot = "boot-2" }, "package-1", unrelatedChangePath);
            check(negativeMatching.Single(item => item.Trial.Id == unchanged.Id).CurrentStatus == FirmwareVerificationMatchStatuses.DifferentProfile,
                "The current-context query reports scoped profile drift instead of hiding the negative result");

            var wrongBinding = binding with { Question = question with { Id = "question-2" } };
            Reject(() => store.Record(unchanged.Id, wrongBinding, FirmwareTrialStatuses.ActualBehaviorVerified,
                restartBaseline, behavior), "Evidence for a different question cannot attach to a trial");
            var restoreFailure = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.UnchangedImmediately, review, write, baseline);
            Reject(() => store.CompleteRestoration(restoreFailure.Id, binding,
                restoration with { ObservedValue = "01" }), "A failed restore cannot be recorded as a completed restoration");
            Reject(() => store.CompleteRestoration(restoreFailure.Id, binding,
                restoration with { Output = "ERROR: restore rejected" }), "A restore command failure cannot complete a trial");
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive,
                restartBaseline with { BootIdentity = "boot-1" }), "A same-boot observation cannot stand in for a reboot");
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive,
                behavior with { Method = "readback" }), "A readback relabeled as behavior is not an actual behavior observation");
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive,
                baseline with { FilePath = "", FileHash = "" }), "A firmware readback without an artifact is unknown");
            var wrongValue = baseline with { ObservedValue = "01" };
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive, wrongValue),
                "A readback value that disagrees with the firmware export is rejected");
            var wrongChecksum = Evidence(FirmwareEvidencePhases.Immediate, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-1", wrongChecksumPath, "Readback 00", now);
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive, wrongChecksum),
                "A readback with a different HII checksum is rejected");
            var wrongShape = Evidence(FirmwareEvidencePhases.Immediate, "firmwareExport", FirmwareBehaviorOutcomes.NotApplicable, "00", "boot-1", wrongShapePath, "Readback 00", now);
            Reject(() => store.Record(restoreFailure.Id, binding, FirmwareTrialStatuses.Inconclusive, wrongShape),
                "A readback with changed question options is rejected");

            var stored = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(stored.Id, stored.Binding, FirmwareTrialStatuses.ValueStored,
                review, write, changed);
            store.Record(stored.Id, stored.Binding, FirmwareTrialStatuses.PersistedAfterRestart,
                restartChanged);
            var storedDone = store.Record(stored.Id, stored.Binding, FirmwareTrialStatuses.ActualBehaviorVerified,
                changedBehavior);
            check(!storedDone.ConfirmedUnchanged, "A stored setting with changed behavior stays outside the unchanged menu");
            File.AppendAllText(changedPath, " changed on disk");
            Reject(() => store.Read(stored.Id), "Reloading evidence rechecks artifact hashes before classification");
            File.WriteAllBytes(changedPath, script.Changes(new Dictionary<string, string> { [firmwareQuestion.Id] = "01" }));
            check(store.ReadConfirmedUnchanged().Count == 0, "A stored and persisted setting with changed behavior stays out of the unchanged menu");

            var storedNoEffect = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(storedNoEffect.Id, storedNoEffect.Binding, FirmwareTrialStatuses.ValueStored, review, write, changed);
            store.Record(storedNoEffect.Id, storedNoEffect.Binding, FirmwareTrialStatuses.PersistedAfterRestart, restartChanged);
            var storedNoEffectDone = store.Record(storedNoEffect.Id, storedNoEffect.Binding, FirmwareTrialStatuses.ActualBehaviorVerified, behavior);
            var storedNoEffectRestored = store.CompleteRestoration(storedNoEffectDone.Id, storedNoEffectDone.Binding, inverseRestoration);
            check(storedNoEffectRestored.ConfirmedUnchanged && store.ReadConfirmedUnchanged().Count == 1,
                "A stored and persisted setting with an independently measured unchanged effect reaches the collapsed menu after inverse restoration");

            var inadequate = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(inadequate.Id, inadequate.Binding, FirmwareTrialStatuses.ValueStored, review, write, changed);
            store.Record(inadequate.Id, inadequate.Binding, FirmwareTrialStatuses.PersistedAfterRestart, restartChanged);
            var inadequateDone = store.Record(inadequate.Id, inadequate.Binding, FirmwareTrialStatuses.Inconclusive,
                behavior with { BehaviorOutcome = FirmwareBehaviorOutcomes.Inconclusive });
            check(!inadequateDone.ConfirmedUnchanged, "An inadequate behavior oracle remains inconclusive even when the value stored and persisted");

            var rejected = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(rejected.Id, rejected.Binding, FirmwareTrialStatuses.WriteRejected,
                review, rejectedWrite, baseline);
            var rejectedDone = store.CompleteRestoration(rejected.Id, rejected.Binding,
                restoration with { BootIdentity = "boot-1" });
            check(rejectedDone.Complete && !rejectedDone.ConfirmedUnchanged, "A rejected write can be complete while remaining outside the collapsed menu");

            var conflict = store.BeginTrial(binding, "00", "01", trialStart);
            store.Record(conflict.Id, conflict.Binding, FirmwareTrialStatuses.UnchangedImmediately,
                review, write, baseline);
            var conflictResult = store.Record(conflict.Id, conflict.Binding, FirmwareTrialStatuses.ActualBehaviorVerified,
                restartBaseline, changedBehavior);
            store.CompleteRestoration(conflictResult.Id, conflictResult.Binding,
                restoration);
            check(!store.Read(conflict.Id).ConfirmedUnchanged, "Conflicting readbacks remain inconclusive for collapse classification");

            var artifact = store.BeginTrial(binding, "00", "01", trialStart);
            File.AppendAllText(baselinePath, " changed");
            Reject(() => store.Record(artifact.Id, artifact.Binding, FirmwareTrialStatuses.UnchangedImmediately,
                review, write, baseline),
                "A changed evidence file is rejected by its recorded hash");
            File.WriteAllText(baselinePath, FirmwareChecks.ExportText);

            var stale = store.BeginTrial(binding, "00", "01", trialStart);
            var old = baseline with { CapturedAt = stale.StartedAt.AddSeconds(-1) };
            Reject(() => store.Record(stale.Id, stale.Binding, FirmwareTrialStatuses.UnchangedImmediately, old),
                "Evidence captured before the trial is stale and cannot establish a result");

            FirmwareVerificationBinding DriftTrialFiles(string name, string questionName, string before, string after, string beforeLabel, string afterLabel)
            {
                var directory = Path.Combine(root, name);
                Directory.CreateDirectory(directory);
                var originalPath = Path.Combine(directory, "original.txt");
                File.WriteAllText(originalPath, FirmwareChecks.VcoreExport("0983808B", "1.079V"));
                var original = new FirmwareScript(File.ReadAllBytes(originalPath));
                var target = original.Questions.First(item => item.Name == questionName);
                var driftSessionPath = Path.Combine(directory, "session.json");
                OperationFiles.Write(driftSessionPath, session with { Id = name, BackupHash = OperationFiles.HashFile(originalPath) });
                var driftChangesPath = Path.Combine(directory, "changes.txt");
                File.WriteAllBytes(driftChangesPath, original.Changes(new Dictionary<string, string> { [target.Id] = after }));
                var driftReviewPath = Path.Combine(directory, "review.json");
                OperationFiles.Write(driftReviewPath, new FirmwareReview(OperationFiles.HashFile(driftSessionPath), OperationFiles.HashFile(driftChangesPath), [new FirmwareChange(target.Id, target.Name, before, after, beforeLabel, afterLabel)]));
                OperationFiles.Write(Path.Combine(directory, "journal.json"), new FirmwareJournal(OperationFiles.HashFile(driftReviewPath), "restartRequired", "Native import completed", new FirmwareCommandResult(0, "native import completed", ""), now));
                return FirmwareVerificationBinding.FromOriginalExport(OperationFiles.Read<FirmwareSession>(driftSessionPath), originalPath, target.Id, OperationFiles.HashFile(driftSessionPath));
            }
            string DriftFile(string name, string text) { var path = Path.Combine(root, name); File.WriteAllText(path, text); return path; }
            FirmwareVerificationEvidence DriftEvidence(string phase, string value, string boot, string path, string method = "firmwareExport", string outcome = FirmwareBehaviorOutcomes.NotApplicable)
                => Evidence(phase, method, outcome, value, boot, path, phase, now);

            var modeBinding = DriftTrialFiles("drift-mode", "Vcore Voltage Mode", "00", "01", "Auto", "Adaptive Vcore");
            var modeTrial = store.BeginTrial(modeBinding, "00", "01", trialStart);
            store.Record(modeTrial.Id, modeBinding, FirmwareTrialStatuses.ValueStored,
                DriftEvidence(FirmwareEvidencePhases.Review, "01", "boot-1", Path.Combine(root, "drift-mode", "review.json"), "review"),
                DriftEvidence(FirmwareEvidencePhases.Write, "01", "boot-1", Path.Combine(root, "drift-mode", "journal.json"), "import"),
                DriftEvidence(FirmwareEvidencePhases.Immediate, "01", "boot-1", DriftFile("drift-mode-immediate.txt", FirmwareChecks.VcoreExport("0983808B", "1.079V", mode: "01"))));
            Reject(() => store.Record(modeTrial.Id, modeBinding, FirmwareTrialStatuses.PersistedAfterRestart,
                DriftEvidence(FirmwareEvidencePhases.Restart, "01", "boot-2", DriftFile("drift-mode-checksum.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.079V", mode: "01")))),
                "A restart readback with a changed HII checksum and no name drift is still rejected");
            Reject(() => store.Record(modeTrial.Id, modeBinding, FirmwareTrialStatuses.PersistedAfterRestart,
                DriftEvidence(FirmwareEvidencePhases.Restart, "01", "boot-2", DriftFile("drift-mode-reverted.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", mode: "00", twin: "1.078V")))),
                "A restart readback whose value reverted is rejected even though only a name drifted");
            Reject(() => store.Record(modeTrial.Id, modeBinding, FirmwareTrialStatuses.PersistedAfterRestart,
                DriftEvidence(FirmwareEvidencePhases.Restart, "01", "boot-2", DriftFile("drift-mode-moved.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", mode: "01", offset: "1050", twin: "1.078V")))),
                "A restart readback where a drifted question moved offset is rejected");
            var modePersisted = store.Record(modeTrial.Id, modeBinding, FirmwareTrialStatuses.PersistedAfterRestart,
                DriftEvidence(FirmwareEvidencePhases.Restart, "01", "boot-2", DriftFile("drift-mode-restart.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", mode: "01", twin: "1.078V"))));
            check(modePersisted.Status == FirmwareTrialStatuses.PersistedAfterRestart, "A restart readback that differs only by live voltage names and HII checksum keeps the trial bound");

            var vcoreBinding = DriftTrialFiles("drift-vcore", "Internal CPU Vcore 1.079V", "0", "5", "0", "5");
            var vcoreTrial = store.BeginTrial(vcoreBinding, "0", "5", trialStart);
            store.Record(vcoreTrial.Id, vcoreBinding, FirmwareTrialStatuses.UnchangedImmediately,
                DriftEvidence(FirmwareEvidencePhases.Review, "5", "boot-1", Path.Combine(root, "drift-vcore", "review.json"), "review"),
                DriftEvidence(FirmwareEvidencePhases.Write, "5", "boot-1", Path.Combine(root, "drift-vcore", "journal.json"), "import"),
                DriftEvidence(FirmwareEvidencePhases.Immediate, "0", "boot-1", DriftFile("drift-vcore-immediate.txt", FirmwareChecks.VcoreExport("0983808B", "1.079V"))));
            var driftedBaseline = DriftFile("drift-vcore-restart.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", twin: "1.078V"));
            store.Record(vcoreTrial.Id, vcoreBinding, FirmwareTrialStatuses.ActualBehaviorVerified,
                DriftEvidence(FirmwareEvidencePhases.Restart, "0", "boot-2", driftedBaseline),
                DriftEvidence(FirmwareEvidencePhases.Behavior, "0", "boot-2", behaviorPath, "benchmark", FirmwareBehaviorOutcomes.Unchanged));
            Reject(() => store.CompleteRestoration(vcoreTrial.Id, vcoreBinding, DriftEvidence(FirmwareEvidencePhases.Restoration, "0", "boot-2",
                DriftFile("drift-vcore-restore-changed.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", mode: "01", twin: "1.078V")), "noInverse")),
                "Restoration with a drifted name still rejects another setting left changed");
            var vcoreRestored = store.CompleteRestoration(vcoreTrial.Id, vcoreBinding, DriftEvidence(FirmwareEvidencePhases.Restoration, "0", "boot-2",
                DriftFile("drift-vcore-restore.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", twin: "1.078V")), "noInverse"));
            check(vcoreRestored.Complete, "A trial on the drifting question completes restoration when every value matches the original after restart");
            var driftIdentity = identity with { Boot = "boot-2" };
            check(store.MatchesBaseline(vcoreTrial.Id, driftIdentity, "package-1", driftedBaseline),
                "A current export that differs only by live voltage names matches the trial baseline");
            check(!store.MatchesBaseline(vcoreTrial.Id, driftIdentity, "package-1", DriftFile("drift-current-changed.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.078V", value: "5", twin: "1.078V"))),
                "A current export with a changed value on the drifted question does not match the trial baseline");
            check(!store.MatchesBaseline(vcoreTrial.Id, driftIdentity, "package-1", DriftFile("drift-current-checksum.txt", FirmwareChecks.VcoreExport("91DA1C04", "1.079V"))),
                "A current export with a changed HII checksum and no name drift does not match the trial baseline");
            var driftedQuestion = new FirmwareScript(File.ReadAllBytes(driftedBaseline)).Questions.Single(item => item.Name == "Internal CPU Vcore 1.078V" && item.Text.Contains("Token =2A9B", StringComparison.Ordinal));
            var driftMatch = store.ReadMatchingTrials(driftIdentity, "package-1", driftedBaseline).Single(item => item.Trial.Id == vcoreTrial.Id);
            check(driftMatch.Matches && driftMatch.CurrentQuestionId == driftedQuestion.Id && driftMatch.CurrentQuestionId != vcoreBinding.QuestionId,
                "A matched trial names the drifted question in the current export so the editor can show its result");
            var original = store.Read(vcoreTrial.Id).Binding.OriginalExportPath;
            var others = store.ReadMatchingTrials(driftIdentity, "package-1", driftedBaseline).Where(item => item.Trial.Id != vcoreTrial.Id && item.Trial.Binding.OriginalExportPath != original)
                .Select(item => (item.Trial.Id, item.CurrentStatus)).ToArray();
            File.Move(original, original + ".moved");
            IReadOnlyList<FirmwareVerificationMatch>? isolated = null; string failure = "";
            try { isolated = store.ReadMatchingTrials(driftIdentity, "package-1", driftedBaseline); }
            catch (Exception error) { failure = error.GetType().Name + ": " + error.Message; }
            finally { File.Move(original + ".moved", original); }
            check(isolated is not null && others.Length > 0 && isolated.SingleOrDefault(item => item.Trial.Id == vcoreTrial.Id)?.CurrentStatus is null or FirmwareVerificationMatchStatuses.Unavailable
                && others.All(other => isolated.SingleOrDefault(item => item.Trial.Id == other.Id)?.CurrentStatus == other.CurrentStatus),
                "A trial whose saved export is missing is shown as unavailable while every other trial keeps its result " + failure);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
        check(!Directory.Exists(root), "Firmware verification fixtures remove all evidence and state");
    }
}
