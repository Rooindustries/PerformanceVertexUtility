using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using RooIndustries.Optimizer;

static class NativeFileControlChecks
{
    [DllImport("advapi32.dll", EntryPoint = "SetFileSecurityW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetFileSecurity(string path, uint information, byte[] descriptor);
    public static void Run(Action<bool, string> check, Action<Action, string> reject)
    {
        void Denied(Action operation, string name)
        {
            var denied = false;
            try { operation(); } catch (UnauthorizedAccessException error) when ((error.HResult & 0xffff) == 5) { denied = true; }
            check(denied, name);
        }
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var file = Path.Combine(root, "original.txt"); File.WriteAllText(file, "preserve original bytes");
        var directory = Path.Combine(root, "downloads"); Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "existing.txt"), "existing child");
        var address = new ControlAddress("file-acl", "fixture:" + file, "permissions");
        var directoryAddress = address with { Target = "fixture:" + directory };
        var store = new WindowsControlStore();
        var original = store.Read(address); var directoryOriginal = store.Read(directoryAddress);
        try
        {
            foreach (var missing in new[] { Path.Combine(root, "aitagent.exe"), Path.Combine(root, "compattel", "DiagTrackRunner.exe") })
            {
                string? message = null;
                try { store.Read(address with { Target = "fixture:" + missing }); } catch (FileNotFoundException error) { message = error.Message; }
                check(message == Path.GetFileName(missing) + " is not installed on this PC.", "A Windows file this PC doesn't have reads as not installed, not as a failed check: " + Path.GetRelativePath(root, missing));
            }
            var program = Path.Combine(root, "compattelrunner.exe"); File.WriteAllText(program, "fixture program");
            var shaped = new RawSecurityDescriptor("D:P(A;;0x1200a9;;;SY)(A;;0x1200a9;;;BA)(A;;0x1200a9;;;BU)(A;;FA;;;" + WindowsIdentity.GetCurrent().User!.Value + ")");
            var shapedBytes = new byte[shaped.BinaryLength]; shaped.GetBinaryForm(shapedBytes, 0);
            if (!SetFileSecurity(program, 4, shapedBytes)) throw new Win32Exception();
            var programAddress = address with { Target = "fixture:" + program };
            var programBefore = store.Read(programAddress);
            check((programBefore.Value.GetProperty("flags").GetInt32() & 0x1400) == 0x1000, "The System32-style fixture has a protected DACL without auto-inheritance");
            var programPlan = new ControlPlan([programBefore], [new(programBefore, programBefore.Expand(ControlValues.From(new { denyMask = 0x20, enabled = true })))], []);
            ControlExecution.Apply(programPlan, store, _ => { });
            check(ControlValues.Equal(store.Read(programAddress).Value, programPlan.Changes[0].After), "Blocking a System32-style program writes exactly the reviewed DACL and inheritance flags");
            ControlExecution.Rollback(programPlan, 1, store);
            check(store.Read(programAddress).Same(programBefore), "Undo restores the System32-style program's exact DACL and inheritance flags");
            var desired = original.Expand(ControlValues.From(new { denyMask = 0x1f01ff }));
            var plan = new ControlPlan([original], [new(original, desired)], []); var attempted = 0;
            ControlExecution.Apply(plan, store, count => attempted = count);
            check(attempted == 1 && ControlValues.Equal(store.Read(address).Value, desired), "Native file restriction writes and reads back the exact reviewed DACL");
            Denied(() => File.ReadAllText(file), "An ordinary new file read is denied by the full-access restriction");
            check(ControlValues.Equal(store.Read(address).Expand(ControlValues.From(new { denyMask = 0x1f01ff })), desired), "An existing identical deny ACE is not duplicated");
            ControlExecution.Rollback(plan, attempted, store);
            check(store.Read(address).Same(original) && File.ReadAllText(file) == "preserve original bytes", "Native file restoration retains exact DACL, owner, flags and file contents");
            var childBefore = File.ReadAllText(Path.Combine(directory, "existing.txt"));
            var directoryPlan = new ControlPlan([directoryOriginal], [new(directoryOriginal, directoryOriginal.Expand(ControlValues.From(new { denyMask = 0x116 })))], []);
            ControlExecution.Apply(directoryPlan, store, _ => { });
            Denied(() => File.WriteAllText(Path.Combine(directory, "new.txt"), "unexpected"), "A directory restriction prevents new file creation");
            File.WriteAllText(Path.Combine(directory, "existing.txt"), childBefore + " retained write access");
            check(File.ReadAllText(Path.Combine(directory, "existing.txt")).EndsWith("retained write access"), "Non-inheriting directory restriction leaves existing children accessible");
            ControlExecution.Rollback(directoryPlan, 1, store);
            check(store.Read(directoryAddress).Same(directoryOriginal), "Directory restoration preserves the exact original permissions");
            var stale = store.Read(address);
            File.Move(file, file + ".saved"); File.WriteAllText(file, "replacement");
            reject(() => store.Write(stale, desired), "A replacement file cannot inherit a reviewed restriction");
            File.Delete(file); File.Move(file + ".saved", file);
            var ownershipAddress = address with { Kind = "file-ownership" };
            var ownershipBefore = store.Read(ownershipAddress);
            var ownershipPlan = new ControlPlan([ownershipBefore], [new(ownershipBefore, ownershipBefore.Expand(ControlValues.From(new { takeOwnership = true })))], []);
            ControlExecution.Apply(ownershipPlan, store, _ => { });
            check(store.Read(ownershipAddress).Value.GetProperty("owner").GetString() == OperationOwner.Current().UserSid, "Ownership action sets the selected item's owner to the initiating Windows user");
            ControlExecution.Rollback(ownershipPlan, 1, store);
            check(store.Read(ownershipAddress).Same(ownershipBefore), "Ownership undo restores the exact original owner and DACL");
            var link = Path.Combine(root, "alias"); Directory.CreateSymbolicLink(link, directory);
            reject(() => store.Read(address with { Target = "fixture:" + Path.Combine(link, "existing.txt") }), "A reparse ancestor is rejected before a permission change");
            Directory.Delete(link);
        }
        finally
        {
            foreach (var before in new[] { original, directoryOriginal })
            {
                var current = store.Read(before.Address);
                if (current.Id != before.Id) throw new IOException("A fixture path was replaced; its recovery snapshot was retained.");
                if (!current.Same(before)) store.Write(store.Read(before.Address with { Kind = "file-ownership" }), before.Value);
                if (!store.Read(before.Address).Same(before)) throw new IOException("Native file fixture restoration failed: " + before.Address.Target);
            }
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Native file-control fixture is completely removed");
    }
}
