using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class FirmwarePageChecks
{
    const string Writing = "Writing the reviewed changes to the BIOS. Keep the app open until it's done. You can use other pages while it runs.";
    const string Busy = "Another BIOS read or write is still running. Wait for it to finish, then try again.";

    public static string Prepare(string fixture, string root)
    {
        var authority = Path.Combine(fixture, "fixture-authority.txt");
        if (!File.Exists(authority) || File.ReadAllText(authority) != "roo-industries-firmware-cli-fixture/v1") throw new InvalidDataException("BIOS page checks need the disposable CLI fixture.");
        var package = ScewinProvider.SetUp(fixture, ScewinProvider.Inspect(fixture), Path.Combine(root, "packages"));
        File.WriteAllText(Path.Combine(package, "fixture-authority.txt"), "roo-industries-firmware-cli-fixture/v1");
        OperationFiles.Write(Path.Combine(root, "workspace.json"), new FirmwareWorkspace(package));
        return package;
    }

    public static async Task RunAsync(Action<bool, string> check, string fixture)
    {
        var failures = new List<string>();
        var only = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_SCENARIO");
        FirmwareViewModel? seen = null;
        var note = "";
        async Task Scenario(string name, Func<Task<bool>> body)
        {
            if (!string.IsNullOrEmpty(only) && !name.Contains(only, StringComparison.OrdinalIgnoreCase)) return;
            seen = null; note = "";
            bool passed;
            try { passed = await body(); }
            catch (Exception error) { passed = false; name += " (" + error.GetType().Name + ": " + error.Message + ")"; }
            if (!passed && seen is not null) name += " [page: stage=" + seen.Stage + " busy=" + seen.Busy + " changes=" + seen.ChangedCount + " message='" + seen.Message + "']";
            if (!passed && note.Length > 0) name += " [" + note + "]";
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        static async Task<bool> Until(Func<bool> condition)
        {
            for (var i = 0; i < 400 && !condition(); i++) await Task.Delay(50);
            return condition();
        }
        async Task<FirmwareViewModel> Revisit()
        {
            var page = FirmwareViewModel.ForPage();
            await page.InitializeAsync();
            return seen = page;
        }
        async Task Pick(FirmwareViewModel page, string option, string delay)
        {
            if (!page.IsEditing) await page.LoadAsync();
            page.Search = ""; page.ChangedOnly = false;
            var choice = page.Settings.Single(row => row.Name == "Fixture option");
            choice.SelectedOption = choice.Options.Single(item => item.Value == option);
            page.Settings.Single(row => row.Name == "Fixture delay").Selection = delay;
        }

        var root = Path.Combine(Path.GetTempPath(), "roo-industries-firmware-page-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_FIRMWARE_ROOT", root);
        var package = Prepare(fixture, root);
        var hold = Path.Combine(package, "fixture-import-hold.txt");
        var refusal = Path.Combine(package, "fixture-import-exit.txt");
        var state = Path.Combine(package, "fixture-state.txt");
        string[] Calls(string kind) => File.Exists(Path.Combine(package, "calls.log"))
            ? File.ReadAllLines(Path.Combine(package, "calls.log")).Where(line => line.StartsWith(kind + "|", StringComparison.Ordinal)).ToArray() : [];
        int Sessions() => Directory.Exists(Path.Combine(root, "sessions")) ? Directory.GetDirectories(Path.Combine(root, "sessions")).Length : 0;
        var pending = new List<Task>();
        try
        {
            string? editing = null;
            await Scenario("Leaving the BIOS page while editing and coming back keeps the picked values", async () =>
            {
                var page = await Revisit();
                await Pick(page, "01", "9");
                editing = page.SessionDirectory;
                page.Search = "Fixture"; page.ChangedOnly = true;
                var exports = Calls("/o").Length;
                var back = await Revisit();
                return page.IsEditing && back.IsEditing && back.ChangedCount == 2 && back.SessionDirectory == editing && back.HasUnsavedPicks
                    && back.Settings.Single(row => row.Name == "Fixture option").Selection == "01" && back.Settings.Single(row => row.Name == "Fixture delay").Selection == "9"
                    && back.Search == "Fixture" && back.ChangedOnly && Calls("/o").Length == exports;
            });

            Task? write = null;
            string? writing = null;
            await Scenario("Leaving during a BIOS write and coming back shows the write still running", async () =>
            {
                var page = await Revisit();
                if (!page.IsEditing || page.ChangedCount != 2) await Pick(page, "01", "9");
                await page.ReviewAsync();
                if (!page.IsReview || page.Changes.Count != 2) return false;
                writing = page.SessionDirectory;
                File.WriteAllText(hold, "held by the BIOS page checks");
                write = page.ApplyAsync();
                pending.Add(write);
                if (!await Until(() => Calls("/i").Length == 1)) return false;
                var back = await Revisit();
                return back.Busy && back.IsReview && back.SessionDirectory == writing && back.Message == Writing
                    && !back.CanApply && !back.CanLoad && !back.CanStartOver && !back.CanVerify && !write.IsCompleted;
            });

            await Scenario("Pressing Load during a BIOS write starts nothing and shows no file-lock error", async () =>
            {
                var back = await Revisit();
                var sessions = Sessions();
                var exports = Calls("/o").Length;
                await back.LoadAsync();
                return write is { IsCompleted: false } && back.Busy && back.IsReview && back.Message == Writing
                    && Sessions() == sessions && Calls("/o").Length == exports && Calls("/i").Length == 1;
            });

            await Scenario("A second BIOS read during a write says so in plain words", () =>
            {
                try { new FirmwareWorkflow(new ScewinProvider(package), Path.Combine(root, "sessions")).Load(); }
                catch (IOException error) { note = "second read said '" + error.Message + "'"; }
                return Task.FromResult(write is { IsCompleted: false } && note == "second read said '" + Busy + "'");
            });

            await Scenario("Coming back after the BIOS write finished shows its result once", async () =>
            {
                File.Delete(hold);
                if (write is null) return false;
                await write.WaitAsync(TimeSpan.FromSeconds(30));
                var back = await Revisit();
                var shown = back.IsResult && !back.Busy && back.ResultStatus == "restartRequired" && back.CanRestart && back.CanStartOver
                    && back.ResultHeadline == "Changes saved. Restart when ready." && back.SessionDirectory == writing
                    && back.History.Count(row => row.Directory == writing && row.Label.EndsWith("Restart pending", StringComparison.Ordinal)) == 1;
                var again = await Revisit();
                return shown && again.IsResult && again.ResultStatus == "restartRequired"
                    && Calls("/i").Length == 1 && File.ReadAllText(state) == "01|9";
            });

            await Scenario("Start over discards the picks on purpose and loads fresh settings", async () =>
            {
                var page = await Revisit();
                await page.StartOverAsync();
                var cleared = page.IsSetup && page.SessionDirectory is null && !page.CanOpenFiles && !page.CanStartOver && page.CanLoad;
                await page.LoadAsync();
                var fresh = page.SessionDirectory;
                page.Settings.Single(row => row.Name == "Fixture delay").Selection = "7";
                var picked = page.IsEditing && page.ChangedCount == 1 && page.HasUnsavedPicks && page.CanStartOver;
                await page.StartOverAsync();
                var discarded = page.IsSetup && page.ChangedCount == 0 && page.Settings.Count == 0 && page.Changes.Count == 0 && page.Search == "" && !page.ChangedOnly;
                var back = await Revisit();
                await back.LoadAsync();
                return cleared && picked && discarded && back.IsEditing && back.ChangedCount == 0 && back.SessionDirectory != fresh
                    && back.Settings.Single(row => row.Name == "Fixture delay").Selection == "9" && File.ReadAllText(state) == "01|9";
            });

            await Scenario("A BIOS write that fails while the user is away shows the failure on return and unlocks the page", async () =>
            {
                var page = await Revisit();
                if (!page.IsEditing) await page.LoadAsync();
                page.Settings.Single(row => row.Name == "Fixture delay").Selection = "7";
                await page.ReviewAsync();
                if (!page.IsReview) return false;
                File.WriteAllText(hold, "held by the BIOS page checks");
                File.WriteAllText(refusal, "1");
                var imports = Calls("/i").Length;
                var failing = page.ApplyAsync();
                pending.Add(failing);
                if (!await Until(() => Calls("/i").Length == imports + 1)) return false;
                var during = await Revisit();
                var running = during.Busy && during.IsReview;
                File.Delete(hold);
                await failing.WaitAsync(TimeSpan.FromSeconds(30));
                var back = await Revisit();
                return running && back.IsResult && !back.Busy && back.ResultStatus == "needsAttention" && back.CanVerify && back.CanStartOver && !back.CanRestart
                    && back.Message.StartsWith("SCEWIN returned 1.", StringComparison.Ordinal) && File.ReadAllText(state) == "01|9";
            });
            File.Delete(refusal);

            await Scenario("Closing the app during a BIOS write still offers the interrupted import for checking", async () =>
            {
                var closing = new FirmwareViewModel();
                await closing.InitializeAsync();
                await closing.LoadAsync();
                closing.Settings.Single(row => row.Name == "Fixture delay").Selection = "6";
                await closing.ReviewAsync();
                var interrupted = closing.SessionDirectory;
                File.WriteAllText(hold, "held by the BIOS page checks");
                var imports = Calls("/i").Length;
                var running = closing.ApplyAsync();
                pending.Add(running);
                if (!await Until(() => Calls("/i").Length == imports + 1)) return false;
                var reopened = new FirmwareViewModel();
                await reopened.InitializeAsync();
                var row = reopened.History.Single(item => item.Directory == interrupted);
                await reopened.OpenHistoryAsync(row);
                var offered = row.Label.EndsWith("Import interrupted", StringComparison.Ordinal) && reopened.IsResult && reopened.ResultStatus == "importing"
                    && reopened.Message.StartsWith("The previous import was interrupted.", StringComparison.Ordinal) && reopened.CanVerify;
                File.Delete(hold);
                await running.WaitAsync(TimeSpan.FromSeconds(30));
                return offered && closing.ResultStatus == "restartRequired";
            });
        }
        finally
        {
            File.Delete(hold);
            File.Delete(refusal);
            try { await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(30)); } catch (Exception error) { failures.Add("A BIOS write did not finish: " + error.Message); }
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_FIRMWARE_ROOT", null);
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
        check(!Directory.Exists(root), "BIOS page checks remove their package, sessions and exports");
        check(failures.Count == 0, "BIOS page state checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
