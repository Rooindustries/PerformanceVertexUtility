using System.ComponentModel;
using System.Runtime.InteropServices;
using RooIndustries.Optimizer;

static class RestorePointChecks
{
    public static void Layout(Action<bool, string> check)
    {
        var type = typeof(RestorePoints).GetNestedType("RestoreStatus", System.Reflection.BindingFlags.NonPublic)!;
        check(Marshal.SizeOf(type) == 12 && Marshal.OffsetOf(type, "Sequence").ToInt32() == 4, "Restore-point status follows the Windows SDK packed 12-byte ABI");
        var bytes = new byte[16]; const long sequence = 0x0001020304050607;
        BitConverter.GetBytes(sequence).CopyTo(bytes, 4);
        var buffer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, buffer, bytes.Length);
            var value = Marshal.PtrToStructure(buffer, type)!;
            check((long)type.GetField("Sequence")!.GetValue(value)! == sequence && Marshal.ReadInt64(buffer, 8) != sequence,
                "The correct native sequence decodes exactly while the previous aligned reader fails");
        }
        finally { Marshal.FreeHGlobal(buffer); }
        var previous = new WindowsRestorePoint(21, "Existing point", DateTime.UtcNow.AddHours(-1));
        var requested = new WindowsRestorePoint(23, "Requested point", DateTime.UtcNow);
        var plan = new RestorePointPreview(OperationOwner.Current(), Guid.NewGuid().ToString("N"), requested.Description, [previous], null);
        var reads = 0; var pauses = 0;
        var delayed = RestorePoints.VerifyUntil(plan, 23, true, () => ++reads < 3 ? [previous] : [previous, requested], () => pauses++, 4);
        check(delayed.Created && delayed.Point == requested && pauses == 2, "Delayed Windows enumeration is verified using the same sequence without another creation request");
        var pending = RestorePoints.VerifyUntil(plan, 23, true, () => [previous, requested with { Description = "Another request" }], () => { }, 2);
        check(pending.Pending && !pending.Created && !pending.AvailableNow, "A visibility deadline or conflicting description stays pending and never claims a backup exists");
        check(!RestorePoints.VerifyUntil(plan, 21, true, () => [previous], () => throw new InvalidOperationException("Unexpected retry"), 2).Pending,
            "An existing sequence is not reclassified as pending creation");
        var rejected = false;
        try { RestorePoints.VerifyUntil(plan, long.MaxValue, true, () => throw new InvalidOperationException("Unexpected query"), () => { }, 1); }
        catch (InvalidDataException) { rejected = true; }
        check(rejected, "A native sequence outside the CIM key range cannot be truncated or marked as pending");
    }
    public static void Native(string root, Action<bool, string> check)
    {
        var plan = RestorePoints.Preview(false);
        var directory = Path.Combine(root, "restore-point-" + plan.OperationId); Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "review.json"); var journal = Path.Combine(directory, "journal.json");
        OperationFiles.Write(path, plan);
        try
        {
            var result = RestorePoints.Create(path, OperationFiles.HashFile(path), journal);
            OperationFiles.Write(Path.Combine(directory, "result.json"), result);
            OperationFiles.Write(Path.Combine(directory, "first-list.json"), RestorePoints.List());
            check(plan.Frequency is null, "The normal restore-point test does not change the creation-frequency policy");
            check(result.Created && result.AvailableNow && result.Point is not null && result.Point.Description == plan.Description && plan.Before.All(point => point.Sequence != result.Point.Sequence),
                "System Restore creates and lists the exact new completed point");
            var count = RestorePoints.List().Length;
            var replay = RestorePoints.Create(path, OperationFiles.HashFile(path), journal);
            check(replay.Point == result.Point && replay.AvailableNow && RestorePoints.List().Length == count, "Repeating the restore-point request reuses its receipt without creating a duplicate");
        }
        finally
        {
            var current = RestorePoints.List();
            OperationFiles.Write(Path.Combine(directory, "before-cleanup.json"), current);
            foreach (var point in current.Where(point => point.Description == plan.Description && plan.Before.All(before => before.Sequence != point.Sequence)))
            {
                var status = SRRemoveRestorePoint(point.Sequence);
                if (status != 0) throw new Win32Exception((int)status, "Removing the test-created restore point failed.");
            }
            var after = RestorePoints.List();
            check(after.All(point => point.Description != plan.Description) && plan.Before.All(before => after.Contains(before)),
                "Only the test-created restore point is removed and every pre-existing point remains");
        }
    }
    [DllImport("srclient.dll")] private static extern uint SRRemoveRestorePoint(uint sequence);
}
