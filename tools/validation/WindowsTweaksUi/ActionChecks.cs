using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class ActionChecks
{
    public static void Run(TweakCatalog catalog, Action<bool, string> check)
    {
        var definitions = catalog.Settings.ToDictionary(setting => setting.Id);
        WindowsTweakRow Row(string id) => new(definitions[id], definitions, _ => { });
        const string edgeResetId = "choice-c4697634bc8964cb";

        foreach (var id in new[] { "windows.e2c95b16cecfc711", "windows.ebf4b29b6f2d80a2", "windows.447cb476fb1e7015", "windows.6195a41a25475f51" })
        {
            var row = Row(id);
            check(row.Action.Name == "Off" && row.Selected.Id.Length == 0 && !row.ToggleOn,
                row.Name + " presents Off without queuing it or the reset action");
            row.ToggleOn = true;
            check(row.Selected.Name == "Off", row.Name + " queues the action displayed beside its switch");
            row.Action = row.ActionChoices.Single(choice => choice.Id == edgeResetId);
            check(row.Selected.Id == edgeResetId && row.Selected.Name == "Use Windows default", row.Name + " requires an explicit reset selection");
            row.ToggleOn = false;
            check(row.Selected.Id.Length == 0 && row.Action.Id == edgeResetId, row.Name + " keeps the visible candidate while clearing pending intent");
        }

        var defaultRow = Row("windows.03b826347901331c");
        defaultRow.Action = defaultRow.ActionChoices.Single(choice => choice.Name == "Windows default");
        check(defaultRow.Selected.Id.Length == 0 && !defaultRow.ToggleOn, "Choosing Windows default does not queue it before the row switch is enabled");
        defaultRow.ToggleOn = true;
        check(defaultRow.Selected.Name == "Windows default", "Windows default remains a separate intentional queued action");

        static bool Numeric(string name) => System.Text.RegularExpressions.Regex.IsMatch(name, @"^(On \(1\)|Off \(0\)|.+: -?\d+)$");
        var inverted = catalog.Settings.First(setting => setting.Options.Length > 1 && setting.Options[0].Name == "Remove this override" && Numeric(setting.Options[1].Name));
        var invertedRow = Row(inverted.Id);
        check(invertedRow.Action.Id == inverted.Options[1].Id, "An inverted catalog pair shows the concrete action before its reset action");

        var numeric = catalog.Settings.First(setting => setting.Options.Length > 2 && setting.Options.Count(option => Numeric(option.Name)) > 1);
        var numericRow = Row(numeric.Id);
        check(numericRow.ActionChoices.Select(choice => choice.Id).SequenceEqual(numeric.Options.Select(option => option.Id)),
            "Numeric choices preserve every catalog option and its identity");
        numericRow.Action = numericRow.ActionChoices[^1];
        numericRow.ToggleOn = true;
        check(numericRow.Selected.Id == numeric.Options[^1].Id, "A numeric row queues the exact displayed choice");

        var bandwidth = Row("windows.11faeaecf4572970");
        check(bandwidth.Action.Id == "choice-95a6ed84299d0109" && bandwidth.Action.Name == "No app reservations",
            "A presentation alias cannot make a bandwidth reset the initial action");
        bool DeletesOverride(TweakOption option) => option.Changes.Length > 0 && (option.Controls?.Length ?? 0) == 0 &&
            option.Changes.All(change => change.Dword is null && change.Value is null && change.Token is null && change.Bits is null && change.Formula is null);
        var resetCandidates = catalog.Settings.Where(definition => definition.Options.Any(DeletesOverride) && definition.Options.Any(option => !DeletesOverride(option)))
            .Where(definition => definition.Options.Any(option => option.Id == Row(definition.Id).Action.Id && DeletesOverride(option))).Select(definition => definition.Id).ToArray();
        check(resetCandidates.Length == 0, "Every mixed catalog entry starts with a concrete action rather than deleting its override: " + string.Join(", ", resetCandidates));

        var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Suggestions");
        var setting = new TweakDefinition("action-contract", "Suggestions", "Windows", "Suggestion preferences", 10240, 26200, ["*"], "none",
            [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)]), new("default", "Remove this override", [new(address, null)])],
            [new("Fixture", "fixture", "Independent action-state contract")]);
        var resetFirst = setting with { Options = [new("default", "Use Windows default", [new(address, null)]), new("off", "Off", [new(address, 0)])] };
        var resetRow = new WindowsTweakRow(resetFirst, new Dictionary<string, TweakDefinition> { [setting.Id] = resetFirst }, _ => { });
        check(resetRow.Action.Id == "off" && resetRow.Selected.Id.Length == 0,
            "A directly named Windows-default option never becomes the initial action ahead of an explicit Off choice");
        var gated = setting with { Id = "fallback-contract", Options = [new("full", "Full", [new(address, 2)]), new("off", "Off", [new(address, 0)]), new("default", "Remove this override", [new(address, null)])] };
        var gatedRow = new WindowsTweakRow(gated, new Dictionary<string, TweakDefinition> { [gated.Id] = gated }, _ => { });
        gatedRow.Observe(new TweakSettingStatus(gated.Id, gated.Name, true, [], [], null, ["off", "default"]));
        check(gatedRow.Action.Id == "full" && gatedRow.Selected.Id.Length == 0, "A starting choice this PC can't use never falls back to a different action");
        var replaced = gated with { Options = [gated.Options[0], new("required", "Required", [new(address, 1)], Replaces: "full"), .. gated.Options[1..]] };
        var replacedRow = new WindowsTweakRow(replaced, new Dictionary<string, TweakDefinition> { [replaced.Id] = replaced }, _ => { });
        replacedRow.Observe(new TweakSettingStatus(replaced.Id, replaced.Name, true, [], [], null, ["required", "off", "default"]));
        check(replacedRow.Action.Id == "required", "A starting choice this PC can't use moves to the choice that replaces it");
        replacedRow.Action = replacedRow.ActionChoices.Single(choice => choice.Id == "full");
        replacedRow.Observe(new TweakSettingStatus(replaced.Id, replaced.Name, true, [], [], null, ["required", "off", "default"]));
        check(replacedRow.Action.Id == "full", "A choice the user picked beside the switch stays after a refresh");
        var observed = new WindowsTweakRow(setting, new Dictionary<string, TweakDefinition> { [setting.Id] = setting }, _ => { });
        observed.Observe(new(setting.Id, setting.Name, true, ["on"],
            [new() { Address = address, NativeKey = @"\REGISTRY\USER\fixture\Software\RooIndustriesUiModelFixture", KeyExists = true,
                Value = new("Suggestions", 4, [1, 0, 0, 0]), MissingKeys = [] }], null, ["on", "off", "default"]));
        check(observed.Current == "On" && observed.ToggleOn && observed.Selected.Id.Length == 0 && !observed.HasPendingChange,
            "An observed enabled setting shows on and never becomes a queued change");
        observed.Selected = observed.Choices.Single(choice => choice.Id == "off");
        check(observed.ToggleOn && observed.Action.Id == "off" && observed.Current == "On",
            "Loading an explicit Off choice shows pending Off separately from current On");
        observed.Selected = observed.Choices.Single(choice => choice.Id == "default");
        check(observed.ToggleOn && observed.Action.Id == "default" && observed.Current == "On",
            "Loading an explicit reset choice preserves its exact action and the observed current state");
        observed.Action = null!;
        check(observed.Action.Id == "default" && observed.Selected.Id == "default",
            "A transient null action binding cannot replace a loaded choice");
        observed.ToggleOn = false;
        check(observed.Selected.Id == "default" && !observed.ToggleOn && observed.HasPendingChange && observed.Current == "On",
            "Turning off an applied setting keeps its reset queued and leaves the observed Windows state untouched");
        observed.Observe(new(setting.Id, setting.Name, true, ["unknown-option"],
            [new() { Address = address, NativeKey = @"\REGISTRY\USER\fixture\Software\RooIndustriesUiModelFixture", KeyExists = true,
                Value = new("Suggestions", 4, [9, 0, 0, 0]), MissingKeys = [] }], null));
        check(observed.Current == "Unknown value" && !observed.ToggleOn, "An unrecognized configured option remains explicit without queuing a change");
        var notifications = new HashSet<string>();
        observed.PropertyChanged += (_, args) => notifications.Add(args.PropertyName ?? "");
        observed.Name = "Live service title";
        check(observed.DetailsAccessibleName == "Live service title details" && observed.ActionAccessibleName == "Change Live service title to"
            && observed.SelectionAccessibleName == "Select Live service title for review" && observed.CurrentAccessibleName == "Live service title: current value Unknown value"
            && new[] { "DetailsAccessibleName", "ActionAccessibleName", "SelectionAccessibleName", "CurrentAccessibleName" }.All(notifications.Contains),
            "Live titles update distinct details, pending-value, selection, and current-state accessibility names");
        observed.Selected = observed.Choices[0];
        observed.Observe(null);
        check(observed.Current == "Not read" && !observed.ToggleOn && observed.Selected.Id.Length == 0,
            "A missing observation remains unknown without selecting a change");

        static bool WindowsDefault(string name) => name is "Remove this override" or "Windows default" or "Use Windows default" or "Not configured" or "source-default" or "Return to previous plan" or "Remove boot override";
        var misread = new List<string>();
        var stockMisread = new List<string>();
        foreach (var definition in catalog.Settings)
        {
            var resets = definition.Options.Where(option => WindowsDefault(option.Name) || WindowsDefault(WindowsTweakPresentation.Choice(definition, option))).Select(option => option.Id).ToHashSet();
            foreach (var option in definition.Options)
            {
                var row = Row(definition.Id); var starting = row.Action.Id;
                row.Observe(new(definition.Id, definition.Name, true, [option.Id], [], null, definition.Options.Select(item => item.Id).ToArray()));
                var applied = !resets.Contains(option.Id) && (resets.Count > 0 || option.Id == starting);
                if (row.IsApplied != applied || row.ToggleOn != applied || row.HasPendingChange || row.Action.Id != (applied ? option.Id : starting)) { (resets.Count > 0 ? misread : stockMisread).Add(definition.Id + " " + option.Id); continue; }
                if (!applied || resets.Count == 0) continue;
                row.ToggleOn = false;
                if (!resets.Contains(row.Selected.Id) || row.StateLabel != "Will turn off" || row.Action.Id != option.Id) misread.Add(definition.Id + " " + option.Id + " off");
            }
        }
        check(stockMisread.Count == 0, "A setting without a Windows default shows only its starting choice as on: " + string.Join(", ", stockMisread.Take(10)));
        check(misread.Count == 0, "Every setting with a Windows default shows any applied choice on beside its switch, and turning it off queues the Windows default: "
            + misread.Count + " misread, " + string.Join(", ", misread.Take(10)));

        var raw = new List<string>();
        foreach (var definition in catalog.Settings)
        {
            foreach (var option in definition.Options)
            {
                var row = Row(definition.Id);
                row.Observe(new(definition.Id, definition.Name, true, [option.Id], [], null, definition.Options.Select(item => item.Id).ToArray()));
                row.ToggleOn = true;
                var shown = row.Choices.Select(choice => choice.Name).Append(row.Current).Append(row.Action.Name).Append(row.Selected.Name).Append(row.SimpleState);
                raw.AddRange(shown.Where(SourceDirection).Select(text => definition.Id + " " + option.Id + " \"" + text + "\""));
            }
        }
        check(raw.Count == 0, "No row shows a source tool's internal choice name, like apply, source-default or lowercase enabled, as its current value, choices or pending change: "
            + raw.Count + " shown, " + string.Join(", ", raw.Distinct().Take(10)));

        const string defender = "windows.171a004ed11767da";
        var consent = new ControlAddress("defender", "system", "SubmitSamplesConsent");
        string Sampling(int value)
        {
            var row = Row(defender);
            row.Observe(new(defender, definitions[defender].Name, true, [], [], null, definitions[defender].Options.Select(item => item.Id).ToArray(),
                [new TweakControlRead(consent, consent.Key, "fixture", ControlValues.From(value))]));
            return row.Current;
        }
        check(Sampling(0) == "Always ask before sending" && Sampling(3) == "Send all samples automatically",
            "A Defender sample choice the app doesn't offer reads in words as the current value: " + Sampling(0) + " | " + Sampling(3));

        var security = catalog.Settings.Where(definition => definition.Options.SelectMany(option => option.Controls ?? []).Any(control => control.Address.Kind is "defender" or "mitigations")).Select(definition => Row(definition.Id)).ToArray();
        var imported = security.Where(row => row.Name == row.Definition.Name || row.Description.Length == 0 || row.Choices.Skip(1).Any(choice => !char.IsUpper(choice.Name[0])))
            .Select(row => row.Id + " \"" + row.Name + "\" " + string.Join("/", row.Choices.Skip(1).Select(choice => choice.Name))).ToArray();
        check(security.Length == 16 && imported.Length == 0, "Every Defender and exploit protection row says what it does in its own name, description and capitalized choices, not the imported catalog's: "
            + security.Length + " rows, " + string.Join(", ", imported));
    }

    public static bool SourceDirection(string text) => System.Text.RegularExpressions.Regex.IsMatch(text, @"(?<![\w-])(apply|source-default)(?![\w-])", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
        || System.Text.RegularExpressions.Regex.IsMatch(text, @"(?<![\w-])(enabled|disabled)(?![\w-])");
}
