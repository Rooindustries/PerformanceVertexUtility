using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

static class PrivateRegistry
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegLoadAppKeyW(string file, out IntPtr key, int access, int options, int reserved);
    [DllImport("advapi32.dll")] private static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    [DllImport("advapi32.dll")] private static extern int RegCloseKey(IntPtr key);
    private static readonly IntPtr Machine = new(unchecked((int)0x80000002)), Users = new(unchecked((int)0x80000003));
    private static IntPtr _machine, _users;
    private static void Require(int code) { if (code != 0) throw new Win32Exception(code); }

    [ModuleInitializer]
    public static void Initialize()
    {
        using var descriptor = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "release-host-fixture.json")));
        var work = descriptor.RootElement.GetProperty("work").GetString()!;
        var local = descriptor.RootElement.GetProperty("local").GetString()!;
        if (!Directory.Exists(local) || !File.Exists(Path.Combine(work, "fixture-owner.txt"))) throw new InvalidDataException("The private registry fixture is unowned.");
        AppDomain.CurrentDomain.FirstChanceException += (_, args) =>
        {
            if (args.Exception is Win32Exception) File.AppendAllText(Path.Combine(work, "native-errors.txt"), args.Exception + Environment.NewLine);
        };
        using var token = WindowsIdentity.GetCurrent();
        var sid = token.User!.Value;
        var profile = RuntimeProfile(token);
        using var version = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")!;
        var build = version.GetValue("CurrentBuildNumber") as string ?? throw new InvalidDataException("Missing Windows build.");
        var edition = version.GetValue("EditionID") as string ?? throw new InvalidDataException("Missing Windows edition.");
        Require(RegLoadAppKeyW(Path.Combine(work, "machine-" + Guid.NewGuid().ToString("N") + ".hive"), out _machine, 0xF003F, 1, 0));
        Require(RegLoadAppKeyW(Path.Combine(work, "users-" + Guid.NewGuid().ToString("N") + ".hive"), out _users, 0xF003F, 1, 0));
        using (var machine = RegistryKey.FromHandle(new SafeRegistryHandle(_machine, false), RegistryView.Registry64))
        {
            using var values = machine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            values.SetValue("CurrentBuildNumber", build); values.SetValue("EditionID", edition);
            using var folders = values.CreateSubKey(@"ProfileList\" + sid);
            folders.SetValue("ProfileImagePath", profile, RegistryValueKind.ExpandString);
        }
        using (var users = RegistryKey.FromHandle(new SafeRegistryHandle(_users, false), RegistryView.Registry64))
        using (var folders = users.CreateSubKey(sid + @"\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
        {
            folders.SetValue("Local AppData", local);
            folders.SetValue("AppData", Path.Combine(profile, "AppData", "Roaming"));
        }
        Require(RegOverridePredefKey(Machine, _machine)); Require(RegOverridePredefKey(Users, _users));
        AppDomain.CurrentDomain.ProcessExit += (_, _) =>
        {
            RegOverridePredefKey(Users, IntPtr.Zero); RegOverridePredefKey(Machine, IntPtr.Zero);
            RegCloseKey(_users); RegCloseKey(_machine);
        };
    }

    [DllImport("userenv.dll", EntryPoint = "GetUserProfileDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetUserProfileDirectory(IntPtr token, System.Text.StringBuilder path, ref int length);
    private static string RuntimeProfile(WindowsIdentity token)
    {
        var length = 32768; var path = new System.Text.StringBuilder(length);
        if (!GetUserProfileDirectory(token.Token, path, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return path.ToString();
    }
}
