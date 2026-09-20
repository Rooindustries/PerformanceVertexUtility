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
    }

    private static string Export(string selected, string stamp)
        => "// Export " + stamp + "\nHIICrc32 = A1B2C3D4\n\n// FORM SET\n// FORM\nSetup Question = Mode\nHelp String = Power mode\nToken =10\nOffset =20\nWidth =01\nOptions =" + (selected == "00" ? "*" : "") + "[00]Off\n         " + (selected == "01" ? "*" : "") + "[01]On\n";
}
