using RooIndustries.Optimizer;

static class PowerPlanChecks
{
    public static void Native(Action<bool, string> check, Action<Action, string> reject)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"), "power");
        var address = new ControlAddress("power-plan", "fixture:" + root, "selection");
        var owned = new Guid("98472f39-9146-5073-8c16-73ea66ded98f"); var original = PowerSchemes.Active(); var schemes = PowerSchemes.Schemes();
        if (schemes.Contains(owned)) throw new InvalidDataException("The disposable power GUID already exists.");
        var store = new WindowsControlStore(); var before = store.Read(address);
        var claim = new ControlClaim("ultimate", "on", before, before.Expand(ControlValues.From(new { enabled = true })), true);
        var desired = ControlComposition.Resolve(before, null, [], [claim]).Desired;
        var plan = new ControlPlan([before], [new(before, desired, ["active", "plan"])], []);
        var receiptPath = Path.Combine(root, "power-plan.json");
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            check(PowerSchemes.Active() == owned && PowerSchemes.Fingerprint(owned) == before.Value.GetProperty("template").GetString(), "Native Ultimate plan duplicates the reviewed template and verifies activation");
            var receipt = OperationFiles.Read<PowerPlanReceipt>(receiptPath);
            OperationFiles.Write(receiptPath, receipt with { Phase = "creating" });
            reject(() => store.Read(address), "A matching plan plus creation intent cannot become confirmed ownership");
            check(PowerSchemes.Active() == owned && PowerSchemes.Schemes().Contains(owned), "Uncertain creation leaves the active plan intact for recovery");
            OperationFiles.Write(receiptPath, receipt);
            var other = schemes.First(id => id != original);
            PowerSchemes.Select(other);
            var failed = false; try { ControlExecution.Rollback(plan, 1, store); } catch (InvalidOperationException) { failed = true; }
            check(failed && PowerSchemes.Active() == other && PowerSchemes.Schemes().Contains(owned), "Power recovery preserves a different externally selected scheme");
            PowerSchemes.Select(owned);
            ControlExecution.Rollback(plan, 1, store);
            check(PowerSchemes.Active() == original && PowerSchemes.Schemes().SequenceEqual(schemes), "Power restore returns to the exact original selection and removes only the owned scheme");
            check(!File.Exists(receiptPath), "Successful native power restoration removes its creation receipt");
            ControlExecution.Apply(plan, store, _ => { });
            var active = store.Read(address);
            var off = active.Expand(ControlValues.From(new { enabled = false }));
            store.Write(active, ControlComposition.Resolve(active, null, [], [new("ultimate", "off", active, off, true)]).Desired);
            check(PowerSchemes.Active() == original && !PowerSchemes.Schemes().Contains(owned), "Explicit power-plan off returns to the captured prior plan and removes its owned copy");
        }
        finally
        {
            if (PowerSchemes.Schemes().Contains(owned))
            {
                var receipt = OperationFiles.Read<PowerPlanReceipt>(receiptPath);
                if (receipt.Phase != "created" || receipt.Plan != owned || PowerSchemes.Fingerprint(owned) != receipt.Fingerprint) throw new InvalidDataException("Power fixture ownership could not be confirmed; evidence retained.");
                PowerSchemes.Select(original); PowerSchemes.Delete(owned);
            }
            if (PowerSchemes.Active() != original || !PowerSchemes.Schemes().SequenceEqual(schemes)) throw new InvalidDataException("Power fixture cleanup differs from the captured inventory.");
            if (Directory.Exists(root)) Directory.Delete(Path.GetDirectoryName(root)!, true);
        }
        check(!Directory.Exists(root), "Power validation leaves no temporary plan or fixture directory");
    }
}
