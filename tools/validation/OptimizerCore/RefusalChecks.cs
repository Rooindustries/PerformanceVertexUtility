using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class RefusalChecks
{
    public static void Run(Action<bool, string> check, TestVolume volume)
    {
        var root = TestFixtures.InheritingRoot("explicit-refusal");
        var far = TestFixtures.InheritingFolder(Path.Combine(volume.Root, "roo-industries-explicit-refusal-" + Guid.NewGuid().ToString("N")));
        var source = Path.Combine(far, "App");
        var explicitOnly = Path.Combine(source, "explicit.txt");
        var ordinary = Path.Combine(source, "ordinary.txt");
        var operations = Path.Combine(root, "Operations");
        var user = WindowsIdentity.GetCurrent().User!.Value;
        try
        {
            Directory.CreateDirectory(source);
            Directory.CreateDirectory(operations);
            File.WriteAllText(explicitOnly, "explicit");
            File.WriteAllText(ordinary, "ordinary");
            SetDacl(explicitOnly, "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + user + ")");
            var before = Sddl(explicitOnly);
            var ordinaryBefore = Sddl(ordinary);
            var sourceBefore = Sddl(source);
            var bytesBefore = (File.ReadAllBytes(explicitOnly), File.ReadAllBytes(ordinary));
            check(!before.Contains(":AI", StringComparison.Ordinal) && !before.Contains("ID;", StringComparison.Ordinal), "The refusal fixture has a file with an explicit-only DACL");
            var identityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("explicit refusal fixture"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:explicit-refusal", ProviderIdentityHash = identityHash, Owner = OperationOwner.Current(),
                RegistrationPresent = false, ProviderQueryComplete = true, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var engine = new FileCleanupEngine(() => authority);
            var reviewPath = Path.Combine(operations, "review.json");
            var journalPath = Path.Combine(operations, "journal.json");
            OperationFiles.Write(reviewPath, engine.Preview(authority.AppId, identityHash, [source], true));
            string? error = null;
            try { engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath); }
            catch (InvalidDataException refusal) { error = refusal.Message; }
            Console.WriteLine("Explicit-only refusal: " + (error ?? "not refused"));
            check(error is not null && error.Contains("Backup verification differs in permissions", StringComparison.Ordinal), "Copying cleanup from another drive refuses an item whose explicit-only permissions it cannot restore exactly and says why");
            check(!File.Exists(journalPath), "A refused cleanup leaves no journal, so it can run again from its review");
            check(!Directory.EnumerateFiles(operations, "file-backup-*").Any(), "A refused cleanup removes the backup copies it had already made");
            check(File.ReadAllBytes(explicitOnly).SequenceEqual(bytesBefore.Item1) && File.ReadAllBytes(ordinary).SequenceEqual(bytesBefore.Item2) && Sddl(explicitOnly) == before && Sddl(ordinary) == ordinaryBefore && Sddl(source) == sourceBefore, "A refused cleanup leaves the files, the folder and their permissions unchanged");
        }
        finally { foreach (var folder in new[] { root, far }.Where(Directory.Exists)) Directory.Delete(folder, true); }
        check(!Directory.Exists(root) && !Directory.Exists(far), "Refusal validation removes its fixture");
    }

    internal static string Sddl(string path)
    {
        using var handle = Open(path, 0x20000);
        GetKernelObjectSecurity(handle, 7, null, 0, out var needed);
        var bytes = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 7, bytes, needed, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return Sddl(bytes, 7);
    }

    internal static string Sddl(byte[] bytes, uint information)
    {
        if (!ConvertSecurityDescriptorToStringSecurityDescriptor(bytes, 1, information, out var text, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Marshal.PtrToStringUni(text) ?? ""; } finally { LocalFree(text); }
    }

    static void SetDacl(string path, string sddl) => SetSecurity(path, sddl, 4);

    internal static void SetSecurity(string path, string sddl, uint information)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out var descriptor, out var size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var bytes = new byte[size];
            Marshal.Copy(descriptor, bytes, 0, (int)size);
            using var handle = Open(path, 0x20000 | 0x40000 | ((information & 1) != 0 ? 0x80000u : 0));
            if (!SetKernelObjectSecurity(handle, information, bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { LocalFree(descriptor); }
    }

    static SafeFileHandle Open(string path, uint access)
    {
        var handle = CreateFile(path, access, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        return handle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetKernelObjectSecurity(SafeHandle handle, uint information, [Out] byte[]? descriptor, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetKernelObjectSecurity(SafeHandle handle, uint information, byte[] descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(byte[] descriptor, uint revision, uint information, out IntPtr text, out uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
}
