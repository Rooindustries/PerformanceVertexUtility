using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class ReviewLabelChecks
{
    const string DynamicTicks = "windows.487406904cd4e971", Hypervisor = "windows.f621c6877f2af1d1", Sehop = "windows.ff7c1955e9c48cfa", Cfg = "windows.6eec44b714e4d017";
    const string BottomUp = "windows.eebc9f3fde48834c", Ipv6 = "windows.150b88b3d0534e99", DevicePower = "windows.16775bf1b44a5304", Logitech = "windows.71e22a554a5cb947";
    const string Defender = "windows.171a004ed11767da", NeverSend = "choice-abe3c9cd2753a893";

    public static async Task Run(string root, string repo, Action<bool, string> check)
    {
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend/catalogs/windows-tweaks.json"));
        var devices = Enumerable.Range(1, 40).Select(index => @"PCI\VEN_1022&DEV_14" + index.ToString("D2") + @"&SUBSYS_00000000&REV_00\3&2411E6FE&0&" + index.ToString("X2")).ToArray();
        var adapters = new[] { Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D") };
        var fixture = Seeded(Path.Combine(root, "review-labels"), catalog, devices, adapters);
        App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
        var picks = new Dictionary<string, string>
        {
            [DynamicTicks] = "Disabled", [Hypervisor] = "Off", [Sehop] = "disabled", [Cfg] = "disabled", [Ipv6] = "Disabled", [DevicePower] = "Disabled", [Logitech] = "Enabled", [Defender] = NeverSend,
        };
        var rows = picks.ToDictionary(pick => pick.Key, pick => model.Rows.Single(row => row.Id == pick.Key));
        foreach (var (id, option) in picks)
        {
            var row = rows[id];
            check(row.Available, row.Name + " can be selected in the review fixture: " + row.Detail);
            row.Selected = row.Choices.Single(choice => choice.Id == catalog.Settings.Single(setting => setting.Id == id).Options.Single(item => item.Name == option || item.Id == option).Id);
        }
        await model.ReviewCommand.ExecuteAsync(null);
        Print(model);
        check(model.HasReview && model.Changes.Count == picks.Count, "Each chosen native setting produces exactly one review line: " + model.Status + " " + model.Detail);
        foreach (var (id, row) in rows)
        {
            var lines = model.Changes.Where(change => change.Name == row.Name).ToArray();
            var expected = char.ToUpperInvariant(row.Selected.Name[0]) + row.Selected.Name[1..];
            check(lines.Length == 1 && lines[0].After == expected, row.Name + " shows the chosen value " + expected + ": " + string.Join(" | ", lines.Select(line => line.Before + " → " + line.After)));
        }
        check(model.Changes.All(change => Readable(change.Name) && Readable(change.Before) && Readable(change.After) && Readable(change.Target)),
            "Every review line is plain text without GUIDs, JSON or raw control identities");
        check(model.Changes.All(change => change.Before != change.After), "No review line repeats the same value on both sides");
        check(model.Changes.All(change => !ActionChecks.SourceDirection(change.Before) && !ActionChecks.SourceDirection(change.After)),
            "No review line shows a source tool's internal choice name, like apply or source-default");
        var bottomUp = model.Rows.Single(row => row.Id == BottomUp).Name;
        check(model.Changes.All(change => change.Name != bottomUp), "SEHOP and Control Flow Guard are never labelled as another mitigation");
        var line = model.Changes.Single(change => change.Name == rows[DynamicTicks].Name);
        check(line.Before == "No override" && line.After == "Disabled", "Dynamic timer ticks shows No override → Disabled when Disabled is chosen");
        line = model.Changes.Single(change => change.Name == rows[Hypervisor].Name);
        check(line.Before == "Automatic" && line.After == "Off", "Hypervisor at startup shows Automatic → Off instead of numbers");
        line = model.Changes.Single(change => change.Name == rows[Ipv6].Name);
        check(line.Before == "Enabled" && line.After == "Disabled", "IPv6 on resolved adapters shows its setting name and Enabled → Disabled");
        line = model.Changes.Single(change => change.Name == rows[DevicePower].Name);
        check(line.Before == "Enabled" && line.After == "Disabled", "Device power saving summarizes every device as Enabled → Disabled");
        line = model.Changes.Single(change => change.Name == rows[Defender].Name);
        check(line.Before == "Windows default" && line.After == "Never send samples", "Defender sample submission shows Windows default → Never send samples: " + line.Before + " → " + line.After);

        model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
        check(fixture.Applies == 1 && model.Status == "Windows settings saved", "The reviewed native settings apply in the fixture: " + model.Status + " " + model.Detail);
        var path = Path.Combine(root, "review-labels", "windows.json");
        var current = OperationFiles.Read<TweakFixture>(path);
        var blocker = new ControlAddress("download-blocker", "logitech-downloads", "blocked");
        current.Controls[blocker.Key] = current.Controls[blocker.Key] with { Value = ControlValues.From(false), LostLease = true };
        OperationFiles.Write(path, current);
        var undo = fixture.Engine.Preview(model.ProfileId, []);
        check(undo.Controls?.Changes.Any(change => ControlValues.Equal(change.Before.Value, change.After)) == true, "The undo plan contains a value-preserving lease release");
        await model.RefreshCommand.ExecuteAsync(null);
        await model.ReviewRestoreCommand.ExecuteAsync(null);
        Print(model);
        var refresh = model.Changes.Where(change => change.Name == rows[Logitech].Name).ToArray();
        check(refresh.Length == 1 && refresh[0].After == WindowsTweaksViewModel.OwnershipRefresh && refresh[0].Before == "Disabled",
            "A same-value lease release is listed as re-taking ownership instead of being hidden: " + string.Join(" | ", refresh.Select(change => change.Before + " → " + change.After)));
        check(model.HasReview && model.Changes.Count > 0 && model.Changes.All(change => change.Before != change.After),
            "The undo review never shows a value changing to itself, like Disabled → Disabled: " + string.Join(" | ", model.Changes.Select(change => change.Name + ": " + change.Before + " → " + change.After)));
        check(model.Changes.All(change => Readable(change.Name) && Readable(change.Before) && Readable(change.After) && Readable(change.Target)
            && !ActionChecks.SourceDirection(change.Before) && !ActionChecks.SourceDirection(change.After)), "Every undo review line is plain text");
        string Undo(string id) { var found = model.Changes.SingleOrDefault(change => change.Name == rows[id].Name); return found is null ? "missing" : found.Before + " → " + found.After; }
        check(Undo(DynamicTicks) == "Disabled → No override" && Undo(Hypervisor) == "Off → Automatic" && Undo(Ipv6) == "Disabled → Enabled" && Undo(Sehop) == "Disabled → Not set" && Undo(DevicePower) == "Disabled → Enabled"
            && Undo(Defender) == "Never send samples → Windows default",
            "Undo lines show the applied choice going back to the original value: " + string.Join(" | ", new[] { DynamicTicks, Hypervisor, Ipv6, Sehop, DevicePower, Defender }.Select(Undo)));

        var timerFixture = new Fixture(Path.Combine(root, "review-labels-timer"), catalog) { Missing = false };
        var timerPath = Path.Combine(root, "review-labels-timer", "windows.json");
        var timerState = OperationFiles.Read<TweakFixture>(timerPath);
        foreach (var address in new ControlAddress[] { new("timer-startup", "system", "enabled"), new("timer", "system", "half-millisecond") })
            timerState.Controls[address.Key] = new(address, address.Key, "fixture", ControlValues.From(false));
        OperationFiles.Write(timerPath, timerState);
        App.Operations = timerFixture; var timerModel = new WindowsTweaksViewModel(); await timerModel.RefreshCommand.ExecuteAsync(null);
        var startup = timerModel.Rows.Single(row => row.Id == "windows.e9d78835a38cf818"); var request = timerModel.Rows.Single(row => row.Id == "windows.14ff050f1e4e53b5");
        startup.Selected = startup.Choices.Single(choice => choice.Id == "choice-88665aca77848447");
        await timerModel.ReviewCommand.ExecuteAsync(null);
        Print(timerModel);
        check(timerModel.Changes.Count == 2 && timerModel.Changes.Select(change => change.Name).Distinct().Count() == 2 && timerModel.Changes.Any(change => change.Name == startup.Name) && timerModel.Changes.Any(change => change.Name == request.Name),
            "A setting that changes two controls names each line after what it changes: " + string.Join(" | ", timerModel.Changes.Select(change => change.Name + ": " + change.Before + " → " + change.After)));

        var sampleFixture = new Fixture(Path.Combine(root, "review-labels-defender"), catalog) { Missing = false };
        var samplePath = Path.Combine(root, "review-labels-defender", "windows.json");
        var sampleState = OperationFiles.Read<TweakFixture>(samplePath);
        var consent = new ControlAddress("defender", "system", "SubmitSamplesConsent");
        sampleState.Controls[consent.Key] = new(consent, consent.Key, "fixture", ControlValues.From(3));
        OperationFiles.Write(samplePath, sampleState);
        App.Operations = sampleFixture; var sampleModel = new WindowsTweaksViewModel(); await sampleModel.RefreshCommand.ExecuteAsync(null);
        var sampling = sampleModel.Rows.Single(row => row.Id == Defender);
        check(sampling.Current == "Send all samples automatically", "The Defender row reads a sample choice the app doesn't offer in words: " + sampling.Current);
        sampling.Selected = sampling.Choices.Single(choice => choice.Id == NeverSend);
        await sampleModel.ReviewCommand.ExecuteAsync(null);
        Print(sampleModel);
        check(sampleModel.Changes.Count == 1 && sampleModel.Changes[0].Before == "Send all samples automatically" && sampleModel.Changes[0].After == "Never send samples",
            "A Defender sample choice the app doesn't offer is named in words, not its number: " + string.Join(" | ", sampleModel.Changes.Select(change => change.Before + " → " + change.After)));
    }

    private static void Print(WindowsTweaksViewModel model)
    {
        foreach (var change in model.Changes) Console.WriteLine("REVIEW " + change.Name + " | " + change.Before + " → " + change.After + " | " + change.Target);
    }

    private static bool Readable(string text) => text.Length is > 0 and < 200 && !text.Contains('{') && !text.Contains("interfaces:", StringComparison.OrdinalIgnoreCase) && !text.Contains('|')
        && !text.Contains(" · system · ", StringComparison.Ordinal) && !text.Contains("current · ", StringComparison.Ordinal);

    private static Fixture Seeded(string directory, TweakCatalog catalog, string[] devices, string[] adapters)
    {
        var fixture = new Fixture(directory, catalog) { Missing = false };
        var path = Path.Combine(directory, "windows.json");
        var state = OperationFiles.Read<TweakFixture>(path);
        void Put(ControlAddress address, object? value, ControlAddress? resolved = null)
        {
            var read = new TweakControlRead(resolved ?? address, (resolved ?? address).Key, "fixture", ControlValues.From(value));
            state.Controls[address.Key] = read; state.Controls[read.Address.Key] = read;
        }
        Put(new("boot-configuration", "current", "disabledynamictick"), null);
        Put(new("boot-configuration", "current", "hypervisorlaunchtype"), 1);
        state.Controls[new ControlAddress("mitigations", "system", "policy").Key] = new(new("mitigations", "system", "policy"), "mitigations:system:policy", "fixture", MitigationControl.Snapshot(null, null, null));
        Put(new("network-adapter", "primary", "ipv6-binding"), adapters.ToDictionary(adapter => adapter, _ => true), new("network-adapter", "interfaces:" + string.Join(";", adapters), "ipv6-binding"));
        Put(new("device-power", "non-network", "enabled"), devices.ToDictionary(device => device, _ => true));
        Put(new("download-blocker", "logitech-downloads", "blocked"), false);
        Put(new("defender", "system", "SubmitSamplesConsent"), 1);
        OperationFiles.Write(path, state);
        return fixture;
    }
}
