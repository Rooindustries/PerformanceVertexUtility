using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Roo.Optimizer;

static class RegistryChecks
{
    public static void Run(Action<bool, string> check)
    {
        var name = "Software\\RooCleanupTests\\" + Guid.NewGuid().ToString("N");
        var files = Path.Combine(Path.GetTempPath(), "roo-registry-" + Guid.NewGuid().ToString("N"));
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        Directory.CreateDirectory(files);
        try
        {
            using (var sentinel = hive.CreateSubKey(name + "\\Sentinel")) sentinel.SetValue("Keep", "unchanged");
            using (hive.CreateSubKey(name + "\\Receipts")) { }
            using (var app = hive.CreateSubKey(name + "\\App"))
            {
                Write(app, "", 3, []);
                Write(app, "None", 0, [0, 1, 254]);
                Write(app, "Little", 4, [0x78, 0x56, 0x34, 0x12]);
                Write(app, "Big", 5, [0x12, 0x34, 0x56, 0x78]);
                Write(app, "Wide", 11, [8, 7, 6, 5, 4, 3, 2, 1]);
                Write(app, "Text", 1, Encoding.Unicode.GetBytes("Roo λ\0"));
                Write(app, "Expand", 2, Encoding.Unicode.GetBytes("%TEMP%\\Roo\0"));
                Write(app, "Multi", 7, Encoding.Unicode.GetBytes("one\0two\0\0"));
                using var child = app.CreateSubKey("Child");
                Write(child, "Bytes", 3, [9, 8, 0, 6]);
            }
            var target = new RegistryAddress("CurrentUser", "Registry64", name + "\\App", "key", null);
            var before = RawTree(hive, target.KeyPath);
            var captured = RegistryNative.Capture(target);
            check(captured.Exists && captured.Node!.Values.Single(value => value.Name == "").Bytes.Length == 0 && captured.Node.Values.Single(value => value.Name == "Expand").Type == 2,
                "Registry capture preserves unnamed empty data and literal expandable-string type");
            var shared = RegistryNative.Capture(target with { View = "Registry32" });
            check(shared.Node!.NativeName == captured.Node!.NativeName, "Shared HKCU view aliases resolve to one physical native key name");
            var providerHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("independent fixture identity"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:registry", ProviderIdentityHash = providerHash, Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var current = authority;
            var engine = new RegistryCleanupEngine(() => current);
            var receipt = new RegistryAddress("CurrentUser", "Registry64", name + "\\Receipts\\" + Guid.NewGuid().ToString("N"), "key", null);
            void Rejected(Action action, string text)
            {
                var refused = false;
                try { action(); } catch (InvalidDataException) { refused = true; } catch (InvalidOperationException) { refused = true; }
                check(refused, text);
            }
            Rejected(() => engine.Preview(authority.AppId, providerHash, [target, target with { View = "Registry32" }], receipt, true, true), "View aliases cannot become duplicate deletion targets");
            Rejected(() => engine.Preview(authority.AppId, providerHash, [target], receipt, true, false), "Unknown original key persistence requires an explicit recreation policy");
            foreach (var blocked in new[]
            {
                authority with { RegistrationPresent = true }, authority with { ProviderQueryComplete = null },
                authority with { RebootPending = true }, authority with { RebootPending = null },
                authority with { RemoverRunning = true }, authority with { RemovalResolved = null },
            })
            {
                current = blocked;
                Rejected(() => engine.Preview(authority.AppId, providerHash, [target], receipt, true, true), "An independent missing or blocking removal signal prevents registry cleanup");
                check(RawTree(hive, target.KeyPath) == before, "Blocked registry preview leaves all original raw values unchanged");
            }
            current = authority;
            var preview = engine.Preview(authority.AppId, providerHash, [target], receipt, true, true);
            var reviewPath = Path.Combine(files, "review.json");
            var journalPath = Path.Combine(files, "journal.json");
            OperationFiles.Write(reviewPath, preview);
            var applied = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath);
            if (applied.Status != "applied") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(applied, OperationFiles.Json));
            check(applied.Status == "applied" && hive.OpenSubKey(target.KeyPath) is null, "Reviewed registry tree deletion commits and removes the selected key");
            using (var sentinel = hive.OpenSubKey(name + "\\Sentinel")) check((string?)sentinel!.GetValue("Keep") == "unchanged", "Registry sibling sentinel survives cleanup");
            var restored = engine.Restore(journalPath);
            if (restored.Status != "restored") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(restored, OperationFiles.Json));
            check(restored.Status == "restored" && RawTree(hive, target.KeyPath) == before, "Registry restore reproduces independent type-and-byte snapshots for all supported values");
            using (var edited = hive.OpenSubKey(target.KeyPath, true)) Write(edited!, "Text", 1, Encoding.Unicode.GetBytes("later user change\0"));
            var afterChange = RawTree(hive, target.KeyPath);
            check(engine.Restore(journalPath).Status == "changedAfterRestore" && RawTree(hive, target.KeyPath) == afterChange, "Repeated registry restore preserves data changed after the first restore");

            using (var values = hive.CreateSubKey(name + "\\Values"))
            {
                Write(values, "", 3, []);
                Write(values, "Keep", 4, [9, 0, 0, 0]);
            }
            var valueTarget = target with { KeyPath = name + "\\Values", Kind = "value", ValueName = "" };
            var valueBefore = RawTree(hive, valueTarget.KeyPath);
            var valuePreview = engine.Preview(authority.AppId, providerHash, [valueTarget], receipt with { KeyPath = receipt.KeyPath + "-value" }, true, false);
            var valuePath = Path.Combine(files, "value-review.json");
            var valueJournal = Path.Combine(files, "value-journal.json");
            OperationFiles.Write(valuePath, valuePreview);
            check(engine.Apply(valuePath, OperationFiles.HashFile(valuePath), valueJournal).Status == "applied", "An unnamed registry value can be removed without deleting its parent");
            using (var values = hive.OpenSubKey(valueTarget.KeyPath, true))
            {
                check(values is not null && !values.GetValueNames().Contains("") && values.GetValueNames().Contains("Keep"), "Value cleanup preserves parent and sibling values");
                Write(values!, "", 3, [7, 7]);
            }
            var foreignValue = RawTree(hive, valueTarget.KeyPath);
            check(engine.Restore(valueJournal).Status == "needsReconciliation" && RawTree(hive, valueTarget.KeyPath) == foreignValue, "A recreated registry value independently blocks restoration");
            using (var values = hive.OpenSubKey(valueTarget.KeyPath, true)) values!.DeleteValue("");
            check(engine.Restore(valueJournal).Status == "restored" && RawTree(hive, valueTarget.KeyPath) == valueBefore, "Value recovery preserves the distinction between absent and empty data");

            using (var values = hive.CreateSubKey(name + "\\SharedValues"))
            {
                Write(values, "First", 4, [1, 0, 0, 0]);
                Write(values, "Second", 4, [2, 0, 0, 0]);
                Write(values, "Unselected", 4, [3, 0, 0, 0]);
            }
            var firstValue = valueTarget with { KeyPath = name + "\\SharedValues", ValueName = "First" };
            var secondValue = firstValue with { ValueName = "Second" };
            var sharedValuePreview = engine.Preview(authority.AppId, providerHash, [firstValue, secondValue], receipt with { KeyPath = receipt.KeyPath + "-shared-values" }, true, false);
            var sharedValuePath = Path.Combine(files, "shared-values-review.json");
            var sharedValueJournal = Path.Combine(files, "shared-values-journal.json");
            OperationFiles.Write(sharedValuePath, sharedValuePreview);
            using (var values = hive.OpenSubKey(firstValue.KeyPath, true)) Write(values!, "Unselected", 4, [4, 0, 0, 0]);
            var sharedValueResult = engine.Apply(sharedValuePath, OperationFiles.HashFile(sharedValuePath), sharedValueJournal);
            if (sharedValueResult.Status != "applied") Console.WriteLine(sharedValueResult.Error);
            using (var values = hive.OpenSubKey(firstValue.KeyPath))
                check(sharedValueResult.Status == "applied" && !values!.GetValueNames().Contains("First") && !values.GetValueNames().Contains("Second") && (int)values.GetValue("Unselected")! == 4,
                    "Multiple selected values can be deleted while an independently changed sibling value is preserved");
            check(engine.Restore(sharedValueJournal).Status == "restored", "Independent value recovery does not require undoing shared-parent metadata changes");
            using (var values = hive.OpenSubKey(firstValue.KeyPath))
                check((int)values!.GetValue("First")! == 1 && (int)values.GetValue("Second")! == 2 && (int)values.GetValue("Unselected")! == 4,
                    "Restoring selected registry values preserves a newer unselected sibling");

            using (var first = hive.CreateSubKey(name + "\\AtomicFirst")) Write(first, "Keep", 4, [1, 0, 0, 0]);
            using (var second = hive.CreateSubKey(name + "\\AtomicSecond")) Write(second, "Changed", 4, [1, 0, 0, 0]);
            var atomicFirst = target with { KeyPath = name + "\\AtomicFirst" };
            var atomicSecond = target with { KeyPath = name + "\\AtomicSecond" };
            var atomicBefore = RawTree(hive, atomicFirst.KeyPath);
            var atomicPreview = engine.Preview(authority.AppId, providerHash, [atomicFirst, atomicSecond], receipt with { KeyPath = receipt.KeyPath + "-atomic" }, true, true);
            var atomicPath = Path.Combine(files, "atomic-review.json");
            OperationFiles.Write(atomicPath, atomicPreview);
            using (var second = hive.OpenSubKey(atomicSecond.KeyPath, true)) Write(second!, "Changed", 3, [1, 0, 0, 0]);
            var secondChanged = RawTree(hive, atomicSecond.KeyPath);
            check(engine.Apply(atomicPath, OperationFiles.HashFile(atomicPath), Path.Combine(files, "atomic-journal.json")).Status == "needsReconciliation" &&
                RawTree(hive, atomicFirst.KeyPath) == atomicBefore && RawTree(hive, atomicSecond.KeyPath) == secondChanged,
                "A later target's type change rolls back an earlier staged deletion without overwriting new data");

            using (var malformed = hive.CreateSubKey(name + "\\Malformed")) WriteUnterminatedString(malformed, "Text");
            var malformedTarget = target with { KeyPath = name + "\\Malformed" };
            var malformedBefore = RawTree(hive, malformedTarget.KeyPath);
            check(malformedBefore.Contains("Text|1|4100\n", StringComparison.Ordinal), "Malformed fixture retains its missing terminator at the tested registry boundary");
            Rejected(() => engine.Preview(authority.AppId, providerHash, [malformedTarget], receipt with { KeyPath = receipt.KeyPath + "-malformed" }, true, true), "Malformed registry string data is retained without pretending it can be restored normally");
            check(RawTree(hive, malformedTarget.KeyPath) == malformedBefore, "Unsupported registry representations remain byte-for-byte unchanged");

            using (var rolled = RegistryTransaction.Begin()) RegistryNative.DeleteReviewed(RegistryNative.Capture(atomicFirst), rolled);
            check(RawTree(hive, atomicFirst.KeyPath) == atomicBefore, "Closing an uncommitted registry transaction restores the staged deletion");
        }
        finally
        {
            hive.DeleteSubKeyTree(name, throwOnMissingSubKey: false);
            using (var parent = hive.OpenSubKey("Software\\RooCleanupTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooCleanupTests", throwOnMissingSubKey: false);
            Directory.Delete(files, true);
        }
        check(hive.OpenSubKey(name) is null && !Directory.Exists(files), "Registry validation removes keys, receipts and backup fixtures");
    }

    private static string RawTree(RegistryKey hive, string path)
    {
        using var key = hive.OpenSubKey(path) ?? throw new InvalidOperationException("Oracle key is missing.");
        var data = new StringBuilder();
        foreach (var name in key.GetValueNames().Order(StringComparer.OrdinalIgnoreCase))
        {
            uint size = 0;
            if (RegQueryValueEx(key.Handle.DangerousGetHandle(), name, IntPtr.Zero, out var type, null, ref size) != 0) throw new InvalidOperationException("Oracle registry size query failed.");
            var bytes = new byte[size];
            if (RegQueryValueEx(key.Handle.DangerousGetHandle(), name, IntPtr.Zero, out type, bytes, ref size) != 0) throw new InvalidOperationException("Oracle registry data query failed.");
            data.Append(name).Append('|').Append(type).Append('|').Append(Convert.ToHexString(bytes)).Append('\n');
        }
        foreach (var child in key.GetSubKeyNames().Order(StringComparer.OrdinalIgnoreCase)) data.Append(child).Append('{').Append(RawTree(hive, path + "\\" + child)).Append('}');
        return data.ToString();
    }
    private static void Write(RegistryKey key, string name, uint type, byte[] bytes)
    {
        var status = RegSetValueEx(key.Handle.DangerousGetHandle(), name, 0, type, bytes, (uint)bytes.Length);
        if (status != 0) throw new InvalidOperationException("Fixture raw registry write failed: " + status);
    }
    private static void WriteUnterminatedString(RegistryKey key, string name)
    {
        var buffer = Marshal.StringToHGlobalUni(name);
        try
        {
            var valueName = new UnicodeString { Length = (ushort)(name.Length * 2), MaximumLength = (ushort)((name.Length + 1) * 2), Buffer = buffer };
            var status = NtSetValueKey(key.Handle.DangerousGetHandle(), ref valueName, 0, 1, [0x41, 0], 2);
            if (status != 0) throw new InvalidOperationException("Unterminated registry fixture write failed: " + status);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [DllImport("ntdll.dll")] private static extern int NtSetValueKey(IntPtr key, ref UnicodeString name, uint title, uint type, byte[] bytes, uint size);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegSetValueEx(IntPtr key, string name, uint reserved, uint type, byte[] bytes, uint length);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern int RegQueryValueEx(IntPtr key, string name, IntPtr reserved, out uint type, [Out] byte[]? bytes, ref uint length);
}
