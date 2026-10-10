using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using RooIndustries.Optimizer;

sealed record ChildObservation(string Image, int ProcessId, Dictionary<string, string> Variables, string Source)
{
    public Dictionary<string, string> Meta { get; init; } = [];
}

sealed class ChildEnv : IDisposable
{
    static readonly string[] Unrelated = ["LOGONSERVER", "USERDNSDOMAIN", "PYTHONPATH", "NODE_OPTIONS", "DOTNET_gcServer", "COMPlus_gcServer", "JAVA_HOME", "ROOT_MARKER_TEST", "ROOTESTMARKER"];
    static readonly string[] DeveloperNames = ["DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT_X86", "DOTNET_ROOT_ARM64", "DOTNET_ROOT(x86)"];
    static readonly string[] Machine = ["OS", "NUMBER_OF_PROCESSORS", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION"];

    public static readonly string[] PowerShellAdds = ["PSExecutionPolicyPreference"];

    public readonly string Folder;
    public readonly string Token;
    public readonly bool Release;
    public readonly string Windows;
    public readonly string System32;
    public readonly string TempBranch;
    public readonly Dictionary<string, string> Values = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, string?> saved = new(StringComparer.OrdinalIgnoreCase);

    public static string PowerShell => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");

    public static ChildEnv Begin(string mode, IReadOnlyDictionary<string, string>? overrides = null) => new(mode, overrides);

    public static void Run(Action<bool, string> check, string mode, IReadOnlyDictionary<string, string>? overrides, Action<ChildEnv> body)
    {
        var env = Begin(mode, overrides);
        try { body(env); }
        finally { env.Dispose(); }
        check(env.RestoredAndRemoved(), "The marker folder is removed and every changed variable is restored");
    }

    public static async Task RunAsync(Action<bool, string> check, string mode, IReadOnlyDictionary<string, string>? overrides, Func<ChildEnv, Task> body)
    {
        var env = Begin(mode, overrides);
        try { await body(env); }
        finally { env.Dispose(); }
        check(env.RestoredAndRemoved(), "The marker folder is removed and every changed variable is restored");
    }

    ChildEnv(string mode, IReadOnlyDictionary<string, string>? overrides)
    {
        Release = RooIndustries.Optimizer.RuntimeEnvironment.Release;
        if (mode != (Release ? "release" : "dev"))
            throw new InvalidOperationException("Build mode mismatch: the run asked for '" + mode + "' but these binaries are " + (Release ? "release" : "dev") + " builds. Rebuild with the matching -p:RooIndustriesRelease value.");
        Windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        System32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var commonFiles = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles);
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        var drive = Path.GetPathRoot(profile)!.TrimEnd('\\');
        var root = DataFolder.Root;
        var protectedTemp = Path.Combine(root, "temp");
        var secured = Directory.Exists(protectedTemp) && DataFolder.Secured(root);
        var temp = secured ? protectedTemp : Path.Combine(Windows, "Temp");
        TempBranch = secured ? "data-folder temp " + protectedTemp : "Windows temp " + temp;
        var expected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = Windows, ["windir"] = Windows, ["SystemDrive"] = Path.GetPathRoot(Windows)!.TrimEnd('\\'), ["ComSpec"] = Path.Combine(System32, "cmd.exe"),
            ["PATH"] = string.Join(';', System32, Windows, Path.Combine(System32, "Wbem"), Path.Combine(System32, "WindowsPowerShell", "v1.0")),
            ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC",
            ["TEMP"] = temp, ["TMP"] = temp,
            ["PSModulePath"] = Path.Combine(programFiles, "WindowsPowerShell", "Modules") + ";" + Path.Combine(System32, "WindowsPowerShell", "v1.0", "Modules"),
            ["ProgramFiles"] = programFiles, ["ProgramW6432"] = programFiles, ["ProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            ["CommonProgramFiles"] = commonFiles, ["CommonProgramW6432"] = commonFiles, ["CommonProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86),
            ["ProgramData"] = programData, ["ALLUSERSPROFILE"] = programData, ["PUBLIC"] = KnownFolder(new Guid("DFDF76A2-C82A-4D63-906A-5644AC457385")),
            ["USERPROFILE"] = profile, ["HOMEDRIVE"] = drive, ["HOMEPATH"] = profile[drive.Length..],
            ["LOCALAPPDATA"] = AppData(profile, "Local AppData", "Local"), ["APPDATA"] = AppData(profile, "AppData", "Roaming"),
            ["USERNAME"] = Environment.UserName, ["USERDOMAIN"] = Environment.UserDomainName, ["COMPUTERNAME"] = Environment.MachineName,
            ["OS"] = "Windows_NT", ["DriverData"] = Path.Combine(System32, "Drivers", "DriverData"),
            ["NUMBER_OF_PROCESSORS"] = Environment.ProcessorCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["PROCESSOR_ARCHITECTURE"] = RuntimeInformation.ProcessArchitecture switch { Architecture.Arm64 => "ARM64", Architecture.Arm => "ARM", Architecture.X86 => "x86", _ => "AMD64" },
        };
        using (var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (var key = hklm.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"))
            foreach (var name in Machine)
                if (key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string { Length: > 0 } value) expected[name] = value;
        foreach (var pair in expected) Values[pair.Key] = pair.Value;

        Token = Guid.NewGuid().ToString("N");
        Folder = Path.Combine(Path.GetTempPath(), "roo-industries-envmarker-" + Token);
        Directory.CreateDirectory(Path.Combine(Folder, "temp"));
        var originalPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var name in Values.Keys) Mark(name, "marker-" + Token + "-" + name);
        Mark("windir", Folder); Mark("SystemRoot", Folder);
        Mark("PATH", Folder + ";" + originalPath);
        Mark("ComSpec", Path.Combine(Folder, "cmd.exe"));
        Mark("PATHEXT", ".MARK");
        Mark("TEMP", Path.Combine(Folder, "temp")); Mark("TMP", Path.Combine(Folder, "temp"));
        foreach (var name in Unrelated) Mark(name, "marker-" + Token + "-" + name);
        Mark(BrandCompatibility.LegacyEnvironmentPrefix + "MARKER_TEST", "marker-" + Token + "-" + BrandCompatibility.LegacyEnvironmentPrefix + "MARKER_TEST");
        Mark("ROO_INDUSTRIES_TEST_MARKER_TEST", "marker-" + Token + "-ROO_INDUSTRIES_TEST_MARKER_TEST");
        Mark("DOTNET_ROOT", Folder);
        Mark("ROO_INDUSTRIES_DOTNET_EXE", Path.Combine(Folder, "dotnet.exe"));
        foreach (var pair in overrides ?? new Dictionary<string, string>()) Mark(pair.Key, pair.Value);
        var block = Environment.GetEnvironmentVariables();
        foreach (var pair in Values)
            if (string.Equals(block[pair.Key] as string, pair.Value, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The marker for " + pair.Key + " equals the real value '" + pair.Value + "', so it could not prove anything.");
    }

    void Mark(string name, string value)
    {
        if (!saved.ContainsKey(name)) saved[name] = Environment.GetEnvironmentVariable(name);
        Environment.SetEnvironmentVariable(name, value);
    }

    public void Dispose()
    {
        foreach (var pair in saved) Environment.SetEnvironmentVariable(pair.Key, pair.Value);
        for (var attempt = 0; attempt < 50 && Directory.Exists(Folder); attempt++)
        {
            try { Directory.Delete(Folder, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Thread.Sleep(200); }
        }
    }

    public bool RestoredAndRemoved() => !Directory.Exists(Folder) && saved.All(pair => Environment.GetEnvironmentVariable(pair.Key) == pair.Value);

    public Dictionary<string, string> Passthrough()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            if (entry.Key is string name && entry.Value is string value &&
                (name.StartsWith(BrandCompatibility.LegacyEnvironmentPrefix, StringComparison.OrdinalIgnoreCase) || DeveloperNames.Contains(name, StringComparer.OrdinalIgnoreCase)))
                result[name] = value;
        return result;
    }

    public List<string> Verify(ChildObservation seen, IEnumerable<KeyValuePair<string, string?>> product, params string[] tolerated) => Verify(seen, product, false, tolerated);

    public List<string> Verify(ChildObservation seen, IEnumerable<KeyValuePair<string, string?>> product, bool parentOwnEnvironmentPoisoned, params string[] tolerated)
    {
        var failures = new List<string>();
        var actual = seen.Variables;
        var powerShell = string.Equals(seen.Image, PowerShell, StringComparison.OrdinalIgnoreCase);
        if (actual.Count < Values.Count) failures.Add("only " + actual.Count + " variables were reported, expected at least " + Values.Count);
        foreach (var pair in Values)
        {
            if (!actual.TryGetValue(pair.Key, out var value)) failures.Add(pair.Key + " is missing (expected " + pair.Value + ")");
            else if (string.Equals(value, pair.Value, StringComparison.OrdinalIgnoreCase)) continue;
            else if (powerShell && pair.Key == "PATHEXT" && string.Equals(value, pair.Value + ";.CPL", StringComparison.OrdinalIgnoreCase)) continue;
            else if (parentOwnEnvironmentPoisoned && pair.Key is "TEMP" or "TMP" && string.Equals(value, Path.Combine(Windows, "Temp"), StringComparison.OrdinalIgnoreCase)) continue;
            else failures.Add(pair.Key + " is '" + Clip(value) + "' but Windows reports '" + pair.Value + "'");
        }
        var developer = Passthrough();
        if (!developer.ContainsKey(BrandCompatibility.LegacyEnvironmentPrefix + "MARKER_TEST") || !developer.ContainsKey("ROO_INDUSTRIES_TEST_MARKER_TEST") || !developer.ContainsKey("DOTNET_ROOT")) failures.Add("the developer markers are not set in the test process");
        var allowed = new HashSet<string>(Values.Keys, StringComparer.OrdinalIgnoreCase);
        foreach (var name in new[] { "DOTNET_EnableDiagnostics", "COMPlus_EnableDiagnostics", "DOTNET_EnableDiagnostics_IPC", "COMPlus_EnableDiagnostics_IPC", "DOTNET_EnableDiagnostics_Debugger", "COMPlus_EnableDiagnostics_Debugger", "DOTNET_EnableDiagnostics_Profiler", "COMPlus_EnableDiagnostics_Profiler" })
        {
            allowed.Add(name);
            if (actual.GetValueOrDefault(name) != "0") failures.Add(name + " is not pinned to 0");
        }
        foreach (var pair in product) allowed.Add(pair.Key);
        foreach (var name in tolerated) allowed.Add(name);
        if (!Release) allowed.UnionWith(developer.Keys);
        foreach (var pair in actual)
        {
            if (!allowed.Contains(pair.Key)) failures.Add("unexpected variable " + pair.Key + "=" + Clip(pair.Value));
            if (pair.Value.Contains(Token, StringComparison.OrdinalIgnoreCase) && (Release || !developer.ContainsKey(pair.Key))) failures.Add(pair.Key + " carries a marker value: " + Clip(pair.Value));
        }
        foreach (var name in Unrelated) if (actual.ContainsKey(name)) failures.Add(name + " was inherited");
        var windowsPrefix = Windows.TrimEnd('\\') + "\\";
        if (actual.TryGetValue("PATH", out var path))
            foreach (var entry in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
                if (!string.Equals(entry.TrimEnd('\\'), Windows.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) && !entry.StartsWith(windowsPrefix, StringComparison.OrdinalIgnoreCase)) failures.Add("PATH has an entry outside the Windows folder: " + entry);
        foreach (var pair in developer)
        {
            var present = actual.TryGetValue(pair.Key, out var value);
            if (Release && present) failures.Add("release build passed the developer variable " + pair.Key);
            if (!Release && (!present || value != pair.Value)) failures.Add("non-release build did not pass the developer variable " + pair.Key + " unchanged");
        }
        foreach (var pair in product)
        {
            if (!actual.TryGetValue(pair.Key, out var value) || value.Length == 0) failures.Add("the product variable " + pair.Key + " did not arrive");
            else if (pair.Value is not null && value != pair.Value) failures.Add("the product variable " + pair.Key + " is '" + Clip(value) + "' but the product should have set '" + pair.Value + "'");
        }
        return failures;
    }

    public static string? ImageFailure(ChildObservation seen, string expected)
        => string.Equals(Path.GetFullPath(seen.Image), Path.GetFullPath(expected), StringComparison.OrdinalIgnoreCase) ? null : "the child image is '" + seen.Image + "' but the full path started should be '" + expected + "'";

    public static void Report(Action<bool, string> check, string label, ChildEnv env, ChildObservation seen, List<string> failures)
    {
        Console.WriteLine("INFO " + label + ": " + seen.Variables.Count + " variables from " + seen.Source + " (pid " + seen.ProcessId + ", " + (env.Release ? "release" : "non-release") + ", TEMP branch: " + env.TempBranch + ")");
        check(failures.Count == 0, label + (failures.Count == 0 ? "" : " leaks the parent's environment: " + string.Join(" | ", failures)));
    }

    public static ChildObservation ReadDump(string path, DateTime notBefore, string source)
    {
        if (!File.Exists(path)) throw new InvalidOperationException("The child never wrote its environment report " + path);
        if (File.GetLastWriteTimeUtc(path) < notBefore) throw new InvalidOperationException("The environment report " + path + " is older than the child start.");
        var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var meta = new Dictionary<string, string>();
        foreach (var line in File.ReadAllLines(path, new UTF8Encoding(false)))
        {
            var split = line.IndexOf('=', 1);
            if (split <= 0) continue;
            if (line[0] == '#') meta[line[1..split]] = line[(split + 1)..];
            else variables[line[..split]] = line[(split + 1)..];
        }
        if (variables.Count == 0) throw new InvalidOperationException("The environment report " + path + " is empty.");
        return new(meta.GetValueOrDefault("IMAGE", ""), int.Parse(meta.GetValueOrDefault("PID", "0"), System.Globalization.CultureInfo.InvariantCulture), variables, source) { Meta = meta };
    }

    public static string DumpScript(string pathExpression)
        => "$e=[Environment]::GetEnvironmentVariables();$l=New-Object System.Collections.Generic.List[string];$l.Add('#IMAGE='+[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);$l.Add('#PID='+$PID);foreach($k in $e.Keys){$l.Add(([string]$k+'='+[string]$e[$k]))};[IO.File]::WriteAllLines(" + pathExpression + ",$l.ToArray(),(New-Object Text.UTF8Encoding($false)))\n";

    public static string Clip(string value) => value.Length > 120 ? value[..120] + "..." : value;

    public static string RepoRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "backend", "profiles", "protected-processes.json"))) return directory.FullName;
        throw new DirectoryNotFoundException("The repository root was not found above " + AppContext.BaseDirectory);
    }

    public static string DotNetMuxer()
    {
        var runtime = Path.GetDirectoryName(typeof(object).Assembly.Location)!;
        var muxer = Path.GetFullPath(Path.Combine(runtime, "..", "..", "..", "dotnet.exe"));
        return File.Exists(muxer) ? muxer : throw new FileNotFoundException("dotnet.exe was not found next to the running runtime.", muxer);
    }

    static string AppData(string profile, string name, string suffix)
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        using var key = Registry.Users.OpenSubKey(identity.User!.Value + @"\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");
        var raw = key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        return raw is null ? Path.Combine(profile, "AppData", suffix) : Path.GetFullPath(raw.Replace("%USERPROFILE%", profile, StringComparison.OrdinalIgnoreCase));
    }

    static string KnownFolder(Guid id)
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        if (SHGetKnownFolderPath(id, 0x4000, identity.Token, out var path) != 0) throw new Win32Exception("The known folder is unavailable.");
        try { return Marshal.PtrToStringUni(path)!; }
        finally { Marshal.FreeCoTaskMem(path); }
    }

    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid folder, uint flags, IntPtr token, out IntPtr path);
}

static class ProcessEnvironmentReader
{
    [StructLayout(LayoutKind.Sequential)] struct Basic { public IntPtr Exit, Peb, Affinity, Priority, Id, Parent; }

    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int information, ref Basic value, int length, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process(IntPtr process, out bool wow64);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, StringBuilder name, ref int size);

    public static int ParentOf(int id)
    {
        var handle = OpenProcess(0x1000, false, id);
        if (handle == IntPtr.Zero) return -1;
        try { var info = new Basic(); return NtQueryInformationProcess(handle, 0, ref info, Marshal.SizeOf<Basic>(), out _) == 0 ? (int)info.Parent : -1; }
        finally { CloseHandle(handle); }
    }

    public static ChildObservation Read(int id)
    {
        if (!Environment.Is64BitProcess) throw new InvalidOperationException("Reading another process's environment needs a 64-bit test process.");
        var handle = OpenProcess(0x1410, false, id);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open process " + id + " to read its environment.");
        try
        {
            if (IsWow64Process(handle, out var wow) && wow) throw new InvalidOperationException("Process " + id + " is a 32-bit process; the reader supports 64-bit children only.");
            var info = new Basic();
            var status = NtQueryInformationProcess(handle, 0, ref info, Marshal.SizeOf<Basic>(), out _);
            if (status != 0) throw new InvalidOperationException("NtQueryInformationProcess failed with 0x" + status.ToString("X8"));
            var parameters = Pointer(handle, info.Peb + 0x20);
            var environment = Pointer(handle, parameters + 0x80);
            var size = (long)Pointer(handle, parameters + 0x3F0);
            if (environment == IntPtr.Zero || size <= 0 || size > 16 * 1024 * 1024) throw new InvalidOperationException("Process " + id + " has no readable environment block (size " + size + ").");
            var bytes = new byte[size];
            if (!ReadProcessMemory(handle, environment, bytes, (IntPtr)bytes.Length, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the environment block of process " + id);
            var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in Encoding.Unicode.GetString(bytes).Split('\0'))
            {
                if (entry.Length == 0) break;
                var split = entry.IndexOf('=', 1);
                if (split > 0) variables[entry[..split]] = entry[(split + 1)..];
            }
            var name = new StringBuilder(1024);
            var length = name.Capacity;
            if (!QueryFullProcessImageNameW(handle, 0, name, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the image path of process " + id);
            return new(name.ToString(), id, variables, "the live process environment block");
        }
        finally { CloseHandle(handle); }
    }

    static IntPtr Pointer(IntPtr process, IntPtr address)
    {
        var buffer = new byte[8];
        if (!ReadProcessMemory(process, address, buffer, (IntPtr)8, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read process memory.");
        return (IntPtr)BitConverter.ToInt64(buffer, 0);
    }
}
