using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;
using System.Text;

public static class FirmwareEditorChecks
{
    public static void Run(Action<bool, string> check)
    {
        var row = new FirmwareSettingRow(new FirmwareQuestion("question", "Mode", "Power mode", "00", "choice", 1,
            [new("00", "Off"), new("01", "On")], "Main", ""));
        check(row.VerificationStatus == "Not tested" && !row.IsTestedUnchanged && !FirmwareViewModel.ShouldCollapse(row), "Untested settings remain visible");
        row.SetVerification("Did not change", "The tested value had no effect.", true);
        check(FirmwareViewModel.ShouldCollapse(row), "Only confirmed unchanged settings can collapse");
        row.SelectedOption = row.Options[1];
        check(row.Changed && !FirmwareViewModel.ShouldCollapse(row), "Editing a collapsed setting returns it to the normal list");
        check(FirmwareViewModel.MatchesFilter(row, "mode", true) && !FirmwareViewModel.MatchesFilter(row, "missing", false), "Search and changed-only filtering remain independent");
        row.Selection = "00";
        row.SetVerification("Not tested", "This selected value has not been tested.", false);
        check(row.SelectedOption?.Value == "00" && !row.Changed && row.VerificationStatus == "Not tested", "Choice binding preserves the current value");

        var baseline = new FirmwareScript(Encoding.Latin1.GetBytes(Export("00", "2026-09-20T10:00:00Z")));
        var fresh = new FirmwareScript(Encoding.Latin1.GetBytes(Export("00", "2026-09-20T10:05:00Z")));
        var changed = new FirmwareScript(Encoding.Latin1.GetBytes(Export("01", "2026-09-20T10:05:00Z")));
        check(FirmwareSemanticProfile.Hash(fresh) == FirmwareSemanticProfile.Hash(baseline), "Fresh exports with changed headers and raw hashes retain the semantic baseline profile");
        check(FirmwareSemanticProfile.Hash(changed) != FirmwareSemanticProfile.Hash(baseline), "A changed setting does not retain the semantic baseline profile");

        var now = DateTimeOffset.UtcNow;
        var question = baseline.Questions.Single();
        var bindingQuestion = FirmwareVerificationQuestion.From(question);
        var binding = new FirmwareVerificationBinding("pc", "board", "bios", "boot", baseline.Crc, "package", new string('A', 64), new string('B', 64), "fixture-original.txt", FirmwareSemanticProfile.Hash(baseline), bindingQuestion);
        var evidence = new FirmwareVerificationEvidence(FirmwareEvidencePhases.Immediate, "read", "00", "boot", "", "", "readback", now);
        var incomplete = new FirmwareVerificationTrial("00000000000000000000000000000001", binding, "00", "01", FirmwareTrialStatuses.UnchangedImmediately, false, [evidence], now, now);
        var incompletePresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(incomplete, FirmwareVerificationMatchStatuses.Matched), question);
        check(!incomplete.ConfirmedUnchanged && incompletePresentation.Status == "Not tested" && !incompletePresentation.CanCollapse, "Incomplete unchanged evidence remains outside the collapsed settings");
        check(binding.BootIdentity == "boot" && binding.BiosRevision == "bios" && binding.PackageFingerprint == "package", "Trial binding keeps boot, BIOS and package identity separate");
        var completed = incomplete with
        {
            Status = FirmwareTrialStatuses.ActualBehaviorVerified,
            RestorationComplete = true,
            Evidence = [
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Review, "script", "01", "boot", "", "", "review", now),
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Write, "helper", "01", "boot", "", "", "write", now),
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Immediate, "readback", "00", "boot", "", "", "readback", now),
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Restart, "readback", "01", "boot-new", "", "", "readback", now),
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Behavior, "oracle", FirmwareBehaviorOutcomes.Unchanged, "00", "boot-new", "", "", "", "", "Observed only the tested value 01", now),
                new FirmwareVerificationEvidence(FirmwareEvidencePhases.Restoration, "inverse", "00", "boot-new", "", "", "restored", now)]
        };
        var unchangedPresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed, FirmwareVerificationMatchStatuses.Matched), question);
        var storedPresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed with { Status = FirmwareTrialStatuses.ValueStored }, FirmwareVerificationMatchStatuses.Matched), question);
        var persistedPresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed with { Status = FirmwareTrialStatuses.PersistedAfterRestart }, FirmwareVerificationMatchStatuses.Matched), question);
        var effectTrial = completed with { Evidence = completed.Evidence.Select(evidence => evidence.Phase == FirmwareEvidencePhases.Behavior ? evidence with { BehaviorOutcome = FirmwareBehaviorOutcomes.Changed, ObservedValue = "01" } : evidence).ToArray() };
        var effectPresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(effectTrial, FirmwareVerificationMatchStatuses.Matched), question);
        var inconclusivePresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed with { Evidence = completed.Evidence.Select(evidence => evidence.Phase == FirmwareEvidencePhases.Behavior ? evidence with { BehaviorOutcome = FirmwareBehaviorOutcomes.Inconclusive } : evidence).ToArray() }, FirmwareVerificationMatchStatuses.Matched), question);
        var stalePresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed, FirmwareVerificationMatchStatuses.DifferentBios), question);
        var numericQuestion = new FirmwareQuestion("numeric", "Delay", "Startup delay", "5", "decimal", 1, [], "Main", "");
        var numericPresentation = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(completed with { TestValue = "9", Status = FirmwareTrialStatuses.ValueStored }, FirmwareVerificationMatchStatuses.Matched), numericQuestion);
        check(unchangedPresentation.Status == "Did not change" && unchangedPresentation.CanCollapse, "Confirmed unchanged trials can collapse");
        check(unchangedPresentation.Reason.Contains("On", StringComparison.Ordinal), "Collapsed trial keeps the displayed test value");
        check(storedPresentation.Status == "Value saved", "Stored trials show value saved");
        check(persistedPresentation.Status == "Restart checked", "Restart-persisted trials show restart checked");
        check(effectPresentation.Status == "Effect verified", "Complete changed behavior shows effect verified");
        check(inconclusivePresentation.Status == "Not tested", "Inconclusive behavior stays untested");
        check(numericPresentation.Reason.Contains("9", StringComparison.Ordinal), "Numeric test values are displayed");
        check(!stalePresentation.CanCollapse, "Stale trials stay in the normal list");

        FirmwareSettingRow Described(string id, FirmwareVerificationTrial? trial, string matchStatus = FirmwareVerificationMatchStatuses.Matched)
        {
            var target = new FirmwareSettingRow(question with { Id = id });
            if (trial is null) return target;
            var description = FirmwareViewModel.DescribeVerification(new FirmwareVerificationMatch(trial, matchStatus), question);
            target.SetVerification(description.Status, description.Reason, description.CanCollapse);
            target.IsExperimental = description.Experimental;
            return target;
        }
        var rejected = Described("rejected", incomplete with { Status = FirmwareTrialStatuses.WriteRejected, RestorationComplete = true });
        var rejectedUnrestored = Described("rejected-unrestored", incomplete with { Status = FirmwareTrialStatuses.WriteRejected });
        var unchangedNow = Described("unchanged", incomplete with { RestorationComplete = true });
        var confirmedUnchanged = Described("confirmed", completed);
        var stored = Described("stored", completed with { Status = FirmwareTrialStatuses.ValueStored });
        var untested = Described("untested", null);
        var otherBoard = Described("other-board", incomplete with { Status = FirmwareTrialStatuses.WriteRejected, RestorationComplete = true }, FirmwareVerificationMatchStatuses.DifferentBoard);
        var skipped = FirmwareSettingRow.ReadOnly(new FirmwareExcludedQuestion("Custom HID", "Device text", "This is text or a data block, not a single value SCEWIN can write."));
        check(rejected.IsExperimental && rejected.VerificationStatus == "Can't be changed here" && unchangedNow.IsExperimental && unchangedNow.VerificationStatus == "Did not change",
            "Rejected writes and values that did not change are marked experimental in plain words");
        check(!rejectedUnrestored.IsExperimental && !otherBoard.IsExperimental && !stored.IsExperimental && !untested.IsExperimental,
            "Unfinished tests, another motherboard's tests, stored values and untested settings stay out of Experimental");
        rejected.SelectedOption = rejected.Options[1];
        unchangedNow.SelectedOption = unchangedNow.Options[1];
        var rows = new[] { rejected, rejectedUnrestored, unchangedNow, confirmedUnchanged, stored, untested, otherBoard, skipped };
        var (normal, experimental) = FirmwareViewModel.Split(rows);
        check(rejected.Changed && rejected.IsExperimental && experimental.Contains(rejected) && experimental.Contains(unchangedNow) && experimental.Contains(confirmedUnchanged) && experimental.Contains(skipped)
            && !normal.Any(row => row.IsExperimental || row.IsReadOnly || FirmwareViewModel.ShouldCollapse(row)) && normal.Length == 4,
            "Settings SCEWIN cannot apply never appear in the normal list, even after they are edited");
        stored.SelectedOption = stored.Options[1];
        var withoutOptIn = FirmwareViewModel.ReviewSelections(rows, row => row.Changed, false);
        var withOptIn = FirmwareViewModel.ReviewSelections(rows, row => row.Changed, true);
        check(withoutOptIn.Keys.SequenceEqual(["stored"]) && withOptIn.Keys.Order().SequenceEqual(["rejected", "stored", "unchanged"]) && !withOptIn.ContainsKey(skipped.Question.Id),
            "Experimental edits reach review only after opting in and read-only settings never do");

        var writeTests = Path.Combine(Path.GetTempPath(), "roo-industries-write-tests-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(writeTests, """
                {"schemaVersion":2,"boards":[{"board":"board","bios":"bios","crc":"A1B2C3D4","tested":5,"experimental":{
                  "locked":{"name":"Locked mode","outcome":"protected"},
                  "kept":{"name":"Kept mode","outcome":"unchanged"},
                  "linked":{"name":"Linked mode","outcome":"side-effects","affects":["Gear Mode","Memory Ref Clock"],"affectedCount":22},
                  "fuse":{"name":"Fuse mode","outcome":"risky"},
                  "refused":{"name":"Refused mode","outcome":"rejected"}}}]}
                """);
            var catalog = FirmwareWriteTests.Read(writeTests);
            var identity = new FirmwareIdentity("pc", "board", "bios", "boot");
            FirmwareSettingRow Named(string id, string name) => new(question with { Id = id, Name = name });
            var locked = Named("locked", "Locked mode"); var kept = Named("kept", "Kept mode"); var linked = Named("linked", "Linked mode"); var fuse = Named("fuse", "Fuse mode"); var fine = Named("fine", "Fine mode");
            FirmwareViewModel.ApplyWriteTests([locked, kept, linked, fuse, fine], catalog.For(identity));
            check(locked.IsExperimental && locked.VerificationReason.Contains("BIOS password", StringComparison.Ordinal) && kept.IsExperimental && kept.VerificationStatus == "Did not change" && !fine.IsExperimental,
                "Shipped write test results move only the listed settings of the matching motherboard into Experimental");
            check(linked.IsExperimental && linked.VerificationStatus == "Changes other settings" && linked.VerificationReason.Contains("22 other settings", StringComparison.Ordinal) && linked.VerificationReason.Contains("Gear Mode", StringComparison.Ordinal)
                && fuse.IsExperimental && fuse.VerificationStatus == "Too risky to test",
                "Settings that change other settings say so and name them, and settings too risky to test are experimental");
            var sameBoardOtherId = Named("other-id", "Locked mode");
            FirmwareViewModel.ApplyWriteTests([sameBoardOtherId], catalog.For(identity));
            check(!sameBoardOtherId.IsExperimental, "On a tested motherboard only exact setting identities count, not names");
            var untestedBoard = identity with { Board = "other board", Bios = "other bios" };
            var byNameLinked = Named("x1", "linked MODE"); var byNameRefused = Named("x2", "Refused mode"); var byNameFuse = Named("x3", "Fuse mode"); var byNameKept = Named("x4", "Kept mode"); var byNameLocked = Named("x5", "Locked mode"); var byNameFine = Named("x6", "Fine mode");
            FirmwareViewModel.ApplyWriteTests([byNameLinked, byNameRefused, byNameFuse, byNameKept, byNameLocked, byNameFine], catalog.For(untestedBoard));
            check(byNameLinked.IsExperimental && byNameRefused.IsExperimental && byNameFuse.IsExperimental && byNameKept.IsExperimental && byNameRefused.VerificationReason.Contains("has not been tested", StringComparison.Ordinal),
                "An untested motherboard falls back to the tested boards' results by setting name and says so");
            check(!byNameLocked.IsExperimental && !byNameFine.IsExperimental, "A tested board's password lock and its working settings do not carry over to another motherboard");
            File.WriteAllText(writeTests, """{"schemaVersion":2,"boards":[{"board":"board","bios":"bios","crc":"A1B2C3D4","tested":1,"experimental":{"locked":{"name":"Locked mode","outcome":"stored"}}}]}""");
            var invalid = false; try { FirmwareWriteTests.Read(writeTests); } catch (InvalidDataException) { invalid = true; }
            check(invalid, "A write test catalog with an unknown outcome is rejected");
        }
        finally { File.Delete(writeTests); }

        var mixed = new FirmwareScript(Encoding.Latin1.GetBytes(Export("00", "2026-09-20T10:00:00Z")
            + "\nSetup Question = Camera name\nHelp String = Text field\nToken =11\nOffset =30\nWidth =1E\nValue =00\n"
            + "\nSetup Question = Shared values\nToken =12\nOffset =40\nWidth =01\nOptions =*[00]Auto\n         [00]Also auto\n"
            + "\nSetup Question = Nothing selected\nToken =13\nOffset =41\nWidth =01\nOptions =[00]Off\n         [01]On\n"
            + "\nSetup Question = Empty value\nToken =14\nOffset =42\nWidth =01\nValue =\n"));
        check(mixed.Questions.Count == 1 && mixed.ExcludedQuestions.Select(item => item.Name).SequenceEqual(["Camera name", "Shared values", "Nothing selected", "Empty value"])
            && mixed.ExcludedQuestions.All(item => item.Reason.Length > 0),
            "Settings the export cannot express as one writable value are reported separately with a reason");
    }

    private static string Export(string selected, string stamp)
        => "// Export " + stamp + "\nHIICrc32 = A1B2C3D4\n\n// FORM SET\n// FORM\nSetup Question = Mode\nHelp String = Power mode\nToken =10\nOffset =20\nWidth =01\nOptions =" + (selected == "00" ? "*" : "") + "[00]Off\n         " + (selected == "01" ? "*" : "") + "[01]On\n";
}
