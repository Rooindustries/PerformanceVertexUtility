using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class AppliedStateChecks
{
    public static void Run(Action<bool, string> check)
    {
        var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Applied");
        TweakOption Option(string id, string name, uint? value) => new(id, name, [new(address, value)]);
        TweakDefinition Definition(string id, params TweakOption[] options) => new(id, id, "Apps", "Fixture", 10240, 26200, ["*"], "none", options, [new("Fixture", "fixture", "isolated UI validation")]);
        var withReset = Definition("with-reset", Option("off", "Off", 0), Option("reset", "Remove this override", null));
        var pair = Definition("pair", Option("on", "On", 1), Option("off", "Off", 0));
        var three = Definition("three", Option("a", "Fast", 1), Option("b", "Balanced", 2), Option("c", "Slow", 3));
        var single = Definition("single", Option("only", "Off", 0));
        var levels = Definition("levels", Option("fast", "Fast", 1), Option("slow", "Slow", 2), Option("reset", "Remove this override", null));
        var definitions = new[] { withReset, pair, three, single, levels }.ToDictionary(definition => definition.Id);
        WindowsTweakRow Row(TweakDefinition definition) => new(definition, definitions, _ => { });
        TweakSettingStatus Status(TweakDefinition definition, string[] configured, bool supported = true, string? error = null) =>
            new(definition.Id, definition.Name, supported, configured, [], error, definition.Options.Select(option => option.Id).ToArray());

        var serviceAddress = new ControlAddress("service", "UsoSvc", "delayed-start");
        var service = new TweakDefinition("fixture.service-name", "UsoSvc: delayed start", "Services", "Fixture", 10240, 26200, ["*"], "none",
            [new("on", "Delayed", [], Controls: [new(serviceAddress, ControlValues.From(true))]), new("off", "Not delayed", [], Controls: [new(serviceAddress, ControlValues.From(false))])], [new("Fixture", "fixture", "isolated UI validation")]);
        var serviceRow = new WindowsTweakRow(service, new Dictionary<string, TweakDefinition> { [service.Id] = service }, _ => { });
        TweakSettingStatus ServiceStatus(string displayName) => new(service.Id, service.Name, true, ["on"], [], null, ["on", "off"], [new(serviceAddress, "service:USOSVC:delayed-start", "fixture", ControlValues.From(true), displayName)]);
        serviceRow.Observe(ServiceStatus(": delayed start"));
        var blank = serviceRow.Name;
        serviceRow.Observe(ServiceStatus("Update Orchestrator Service: delayed start"));
        check(blank == "UsoSvc: delayed start" && serviceRow.Name == "Update Orchestrator Service: delayed start",
            "A service without a readable display name keeps its catalog name instead of showing ': delayed start': " + blank);
        var row = Row(withReset);
        check(!row.ToggleOn && !row.IsApplied && row.StateLabel == "Off", "A setting that has not been read starts off");
        row.Observe(Status(withReset, ["off"]));
        check(row.ToggleOn && row.IsApplied && row.Selected.Id.Length == 0 && !row.HasPendingChange && row.StateLabel == "On",
            "The page shows an already applied setting as on without queuing a change");
        row.ToggleOn = false;
        check(row.Selected.Id == "reset" && row.HasPendingChange && !row.ToggleOn && row.StateLabel == "Will turn off" && row.Action.Id == "off",
            "Turning an applied setting off queues its Windows default while keeping the applied value visible");
        row.ToggleOn = true;
        check(row.Selected.Id.Length == 0 && !row.HasPendingChange && row.ToggleOn, "Turning it back on clears the queued revert");
        row.ToggleOn = false; row.ToggleOn = true; row.ToggleOn = false; row.ToggleOn = true;
        check(row.Selected.Id.Length == 0 && !row.HasPendingChange && row.ToggleOn && row.StateLabel == "On", "Repeated switching ends with nothing queued for an applied setting");

        row.Observe(Status(withReset, ["reset"]));
        check(!row.ToggleOn && !row.IsApplied && !row.HasPendingChange, "A setting at its Windows default shows off");
        var saved = Row(withReset);
        saved.Selected = saved.Choices.Single(choice => choice.Id == "reset");
        saved.Observe(Status(withReset, ["reset"]));
        check(!saved.ToggleOn && !saved.IsApplied && !saved.HasPendingChange && saved.StateLabel == "Off", "A saved Windows default that Windows already reads shows off with nothing queued");
        saved.Observe(Status(withReset, ["off"]));
        check(saved.HasPendingChange && saved.Selected.Id == "reset", "A saved Windows default that another program changed back is queued again");
        row.ToggleOn = true;
        check(row.Selected.Id == "off" && row.HasPendingChange && row.StateLabel == "Will turn on", "Turning on a setting that is not applied queues its action");
        row.Observe(Status(withReset, ["off"]));
        check(row.ToggleOn && !row.HasPendingChange && row.StateLabel == "On", "Refreshing after the change was applied leaves the switch on with nothing pending");
        row.Selected = row.Choices[0];
        row.Observe(Status(withReset, []));
        check(!row.ToggleOn && !row.IsApplied, "Refreshing after the value was removed turns the switch off");

        foreach (var (status, reason) in new[]
        {
            (Status(withReset, ["off"], error: "Windows could not read this value."), "an unreadable"),
            (Status(withReset, ["off"], supported: false), "an unsupported"),
            ((TweakSettingStatus?)null, "a missing"),
        })
        {
            var unknown = Row(withReset); unknown.Observe(status);
            check(!unknown.ToggleOn && !unknown.IsApplied && unknown.Selected.Id.Length == 0, "A setting with " + reason + " status is never shown as applied");
        }

        var other = Row(three); other.Observe(Status(three, ["b"]));
        check(!other.ToggleOn && !other.IsApplied && other.Action.Id == "a", "A current value that is not the suggested one is not shown as an applied tweak on a setting without a Windows default");
        other.Action = other.ActionChoices.Single(choice => choice.Id == "b"); other.ToggleOn = true;
        check(other.Selected.Id == "b" && other.IsApplied && !other.HasPendingChange && other.ToggleOn, "Choosing the value Windows already has leaves nothing to change");
        other.Action = other.ActionChoices.Single(choice => choice.Id == "c");
        check(other.Selected.Id == "c" && other.HasPendingChange && other.ToggleOn, "Picking another value queues that value");
        other.Selected = other.Choices[0]; other.Observe(Status(three, ["a"]));
        other.ToggleOn = false;
        check(other.ToggleOn && other.Selected.Id.Length == 0 && other.ChoiceStatus.StartsWith("Already on", StringComparison.Ordinal), "A setting without a way back stays on and says so");

        var level = Row(levels); level.Observe(Status(levels, ["slow"]));
        check(level.ToggleOn && level.AppliedChoice?.Id == "slow" && level.Action.Id == "slow" && level.Selected.Id.Length == 0 && !level.HasPendingChange && level.StateLabel == "On",
            "A setting whose value is another of its choices shows on with that choice beside the switch");
        level.ShowDetails = false;
        check(level.SimpleState == "On · Slow", "Simple mode names the applied choice: " + level.SimpleState);
        level.ShowDetails = true;
        level.ToggleOn = false;
        check(level.Selected.Id == "reset" && level.HasPendingChange && !level.ToggleOn && level.StateLabel == "Will turn off" && level.Action.Id == "slow",
            "Turning it off queues its Windows default while keeping the applied choice visible");
        level.ToggleOn = true;
        check(level.Selected.Id.Length == 0 && !level.HasPendingChange && level.ToggleOn && level.StateLabel == "On", "Turning it back on leaves nothing queued");
        level.Action = level.ActionChoices.Single(choice => choice.Id == "fast");
        check(level.Selected.Id == "fast" && level.HasPendingChange && level.ToggleOn && level.AppliedChoice?.Id == "slow", "Picking another choice beside the applied one queues it");
        level.Action = level.ActionChoices.Single(choice => choice.Id == "slow");
        check(level.Selected.Id.Length == 0 && !level.HasPendingChange && level.ToggleOn, "Picking the applied choice again leaves nothing to change");
        level.Observe(Status(levels, ["reset"]));
        check(!level.ToggleOn && !level.IsApplied && !level.HasPendingChange, "Refreshing after its Windows default returns turns the switch off");
        var both = Row(levels); both.Observe(Status(levels, ["fast", "slow"]));
        check(both.AppliedChoice?.Id == "fast" && both.Action.Id == "fast" && both.ToggleOn, "When the starting choice also matches, the switch shows the starting choice");
        var picked = Row(levels); picked.Selected = picked.Choices.Single(choice => choice.Id == "slow"); picked.Observe(Status(levels, ["fast", "slow"]));
        check(picked.AppliedChoice?.Id == "slow" && !picked.HasPendingChange && picked.ToggleOn, "A loaded choice that matches stays the applied one");
        var unread = Row(levels); unread.Observe(Status(levels, ["slow"], error: "Windows could not read this value."));
        check(!unread.ToggleOn && !unread.IsApplied, "An unreadable setting never shows another choice as applied");
        var stock = Row(pair); stock.Observe(Status(pair, ["off"]));
        check(!stock.ToggleOn && !stock.IsApplied && stock.Action.Id == "on", "A two value setting without a Windows default still shows its other value as off");

        var opposite = Row(pair); opposite.Observe(Status(pair, ["on"]));
        opposite.ToggleOn = false;
        check(opposite.Selected.Id == "off" && !opposite.ToggleOn && opposite.HasPendingChange, "A two value setting without a reset reverts to its other value");

        var lone = Row(single); lone.Observe(Status(single, ["only"]));
        lone.ToggleOn = false;
        check(lone.ToggleOn && lone.Selected.Id.Length == 0, "A single value setting that is applied cannot queue a revert");
    }
}
