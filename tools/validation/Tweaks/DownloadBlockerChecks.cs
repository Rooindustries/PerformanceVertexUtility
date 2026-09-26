using RooIndustries.Optimizer;

static class DownloadBlockerChecks
{
    public static void Native(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var path = Path.Combine(root, "downloads"); var address = new ControlAddress("download-blocker", "fixture:" + path, "blocked");
        var policy = new ControlAddress("file-acl", "fixture:" + path, "permissions"); var store = new WindowsControlStore();
        try
        {
            var before = store.Read(address); var plan = new ControlPlan([before], [new(before, ControlValues.From(true))], []);
            ControlExecution.Apply(plan, store, _ => { });
            check(Directory.Exists(path) && store.Read(address).Value.GetBoolean(), "A missing download folder is created and its owned restriction is verified");
            var denied = false; try { File.WriteAllText(Path.Combine(path, "probe.txt"), "unexpected"); } catch (UnauthorizedAccessException error) when ((error.HResult & 0xffff) == 5) { denied = true; }
            check(denied, "The newly created blocker prevents ordinary new file writes");
            ControlExecution.Rollback(plan, 1, store);
            check(!Directory.Exists(path) && !File.Exists(path + ".blocker.json") && store.Read(address).Same(before), "Restore removes an unchanged empty folder created by this operation");
            Directory.CreateDirectory(path); File.WriteAllText(Path.Combine(path, "existing.txt"), "retained data"); var original = store.Read(policy);
            before = store.Read(address); plan = new([before], [new(before, ControlValues.From(true))], []);
            ControlExecution.Apply(plan, store, _ => { }); ControlExecution.Rollback(plan, 1, store);
            check(File.ReadAllText(Path.Combine(path, "existing.txt")) == "retained data" && store.Read(policy).Same(original), "An existing download directory keeps its data and exact original permissions");
            Directory.Delete(path, true);
            before = store.Read(address); plan = new([before], [new(before, ControlValues.From(true))], []);
            ControlExecution.Apply(plan, store, _ => { });
            var record = OperationFiles.Read<DownloadBlockerReceipt>(path + ".blocker.json");
            store.Write(store.Read(policy), record.Original!.Value);
            File.WriteAllText(Path.Combine(path, "new-data.txt"), "preserve new data");
            store.Write(store.Read(policy), record.Applied!.Value);
            store.Write(store.Read(address), ControlValues.From(false));
            check(Directory.Exists(path) && File.ReadAllText(Path.Combine(path, "new-data.txt")) == "preserve new data" && !store.Read(address).Value.GetBoolean(), "Undo retains an app-created folder that acquired unrelated data");
            check(store.Read(policy).Same(record.Original), "Retaining new data still restores the original folder permissions");
            Directory.Delete(path, true);
            before = store.Read(address); plan = new([before], [new(before, ControlValues.From(true))], []);
            ControlExecution.Apply(plan, store, _ => { });
            var released = true; try { ControlExecution.Apply(new([before], [], [], null, [new(new ControlHeld(before, ControlValues.From(false)))]), store, _ => { }); } catch (InvalidDataException) { released = false; }
            check(released, "A commit ignores a control it releases without writing even if Windows changed it meanwhile");
            var retaken = false; try { ControlExecution.Apply(new([before], [], [], null, [new(new ControlHeld(before, ControlValues.From(true)))]), store, _ => { }); } catch (InvalidDataException) { retaken = true; }
            check(retaken, "A commit refuses a released control that went back to the tweaked value");
            var kept = false; try { ControlExecution.Apply(new([before], [], [new(before, ControlValues.From(false))]), store, _ => { }); } catch (InvalidDataException) { kept = true; }
            check(kept, "A commit still refuses when a control it keeps ownership of changed");
            var active = store.Read(address); var undo = new ControlPlan([active], [new(active, ControlValues.From(false))], []);
            ControlExecution.Apply(undo, store, _ => { });
            check(!Directory.Exists(path), "Undo removes the folder it created");
            ControlExecution.Rollback(undo, 1, store);
            var recreated = store.Read(address);
            check(Directory.Exists(path) && recreated.Value.GetBoolean() && !recreated.LostLease, "Recovery after a failed undo recreates the blocked folder and verifies it");
            ControlExecution.Rollback(undo, 1, store);
            check(store.Read(address).Value.GetBoolean(), "Checking recovery again after the folder was recreated succeeds");
            store.Write(recreated, ControlValues.From(false));
            check(!Directory.Exists(path) && !File.Exists(path + ".blocker.json"), "A later undo removes the recreated folder");
        }
        finally
        {
            var current = store.Read(address);
            if (current.Value.GetBoolean() || current.LostLease) store.Write(current, ControlValues.From(false));
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Download blocker validation removes all owned test files");
    }
}
