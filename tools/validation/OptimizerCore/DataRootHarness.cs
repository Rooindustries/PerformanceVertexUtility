using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class DataRootHarness
{
    public static readonly string Local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static string Name(string label) => "RooIndustriesDataFix-" + label + "-" + Guid.NewGuid().ToString("N")[..12];

    public static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    public static void Junction(string link, string target)
    {
        var (exit, output) = Run("cmd.exe", "/c mklink /J \"" + link + "\" \"" + target + "\"");
        if (exit != 0) throw new InvalidOperationException("mklink /J failed for " + link + ": " + output);
    }

    public static (int Exit, string Output) Run(string file, string arguments, int timeout = 60000)
    {
        using var process = Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })!;
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(timeout)) { process.Kill(true); throw new TimeoutException(file + " did not finish."); }
        return (process.ExitCode, output.Result + error.Result);
    }

    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int kind, out int value, int size, out int returned);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();

    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr value, int size, out int returned);

    public static bool? AdministratorsEnabled(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (!OpenProcessToken(process.Handle, 0x8, out var token)) return null;
            try
            {
                GetTokenInformation(token, 2, IntPtr.Zero, 0, out var needed);
                var buffer = Marshal.AllocHGlobal(needed);
                try
                {
                    if (!GetTokenInformation(token, 2, buffer, needed, out _)) return null;
                    var count = Marshal.ReadInt32(buffer);
                    var offset = IntPtr.Size;
                    for (var index = 0; index < count; index++)
                    {
                        var sid = new System.Security.Principal.SecurityIdentifier(Marshal.ReadIntPtr(buffer, offset + index * 2 * IntPtr.Size));
                        var attributes = Marshal.ReadInt32(buffer, offset + index * 2 * IntPtr.Size + IntPtr.Size);
                        if (sid.Value == "S-1-5-32-544") return (attributes & 0x4) != 0 && (attributes & 0x10) == 0;
                    }
                    return false;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { CloseHandle(token); }
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }

    public static bool ShellElevated
    {
        get
        {
            var session = System.Diagnostics.Process.GetCurrentProcess().SessionId;
            var shell = System.Diagnostics.Process.GetProcessesByName("explorer").Where(candidate => candidate.SessionId == session).Select(candidate => candidate.Id).FirstOrDefault();
            return shell > 0 && Elevated(shell) == true;
        }
    }

    public static bool? Elevated(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (!OpenProcessToken(process.Handle, 0x8, out var token)) return null;
            try { return GetTokenInformation(token, 20, out var elevation, 4, out _) ? elevation != 0 : null; }
            finally { CloseHandle(token); }
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }

    public static bool IsLink(string path) => Directory.Exists(path) && new DirectoryInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint);

    public static Process Start(string[] args, Dictionary<string, string>? env = null)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in args) start.ArgumentList.Add(argument);
        foreach (var pair in env ?? []) start.Environment[pair.Key] = pair.Value;
        return Process.Start(start)!;
    }

    public static (int Exit, string Output) Child(string[] args, Dictionary<string, string>? env = null, int timeout = 180000)
    {
        using var process = Start(args, env);
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(timeout)) { process.Kill(true); throw new TimeoutException("The child process did not finish: " + string.Join(" ", args)); }
        return (process.ExitCode, (output.Result + error.Result).Trim());
    }

    public static string Standard(params string[] args)
    {
        var result = Path.Combine(Local, "RooIndustriesDataFix-std-" + Guid.NewGuid().ToString("N") + ".txt");
        var dotnet = Path.Combine(Environment.GetEnvironmentVariable("DOTNET_ROOT") ?? Path.GetDirectoryName(Environment.ProcessPath)!, "dotnet.exe");
        var dll = System.Reflection.Assembly.GetEntryAssembly()!.Location;
        var script = "$env:DOTNET_ROOT=" + Quote(Path.GetDirectoryName(dotnet)!) + "; & " + Quote(dotnet) + " " + Quote(dll) + " --child-standard " + string.Join(" ", args.Select(Quote)) + " *> " + Quote(result);
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var system = Environment.SystemDirectory;
        var (exit, output) = Run(Path.Combine(system, "runas.exe"), "/trustlevel:0x20000 \"" + Path.Combine(system, "conhost.exe") + " --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded + "\"", 30000);
        for (var index = 0; index < 150 && !File.Exists(result); index++) Thread.Sleep(200);
        Thread.Sleep(400);
        if (!File.Exists(result)) throw new InvalidOperationException("The standard-token helper did not report (runas exit " + exit + "): " + output);
        var text = File.ReadAllText(result).Trim();
        File.Delete(result);
        return text;
    }

    public static void StandardBackground(string log, Dictionary<string, string> env, params string[] args)
    {
        var dotnet = Path.Combine(Environment.GetEnvironmentVariable("DOTNET_ROOT") ?? Path.GetDirectoryName(Environment.ProcessPath)!, "dotnet.exe");
        var dll = System.Reflection.Assembly.GetEntryAssembly()!.Location;
        var script = "$env:DOTNET_ROOT=" + Quote(Path.GetDirectoryName(dotnet)!) + "; " + string.Join("", env.Select(pair => "$env:" + pair.Key + "=" + Quote(pair.Value) + "; ")) + "& " + Quote(dotnet) + " " + Quote(dll) + " " + string.Join(" ", args.Select(Quote)) + " *> " + Quote(log);
        var system = Environment.SystemDirectory;
        Run(Path.Combine(system, "runas.exe"), "/trustlevel:0x20000 \"" + Path.Combine(system, "conhost.exe") + " --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) + "\"", 30000);
    }

    public static void Forget(params string[] paths)
    {
        using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true);
        using var suspended = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\RooIndustries\OptimizationSuite\SuspendedForMove", true);
        foreach (var path in paths)
        {
            var name = PolicyRootSecurity.MarkerName(path);
            markers?.DeleteValue(name, false); markers?.DeleteValue(name + PolicyRootSecurity.ProtectedAtSuffix, false);
            suspended?.DeleteValue(name, false);
        }
    }

    public static string Long(string path) => path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path : @"\\?\" + Path.GetFullPath(path);

    public static void Delete(params string[] paths)
    {
        foreach (var path in paths)
        {
            var directory = new DirectoryInfo(Long(path));
            if (directory.Exists) Remove(directory);
            else if (File.Exists(Long(path))) { File.SetAttributes(Long(path), FileAttributes.Normal); File.Delete(Long(path)); }
        }
    }

    private static void Remove(DirectoryInfo root)
    {
        var folders = new Stack<DirectoryInfo>();
        var visited = new List<DirectoryInfo>();
        folders.Push(root);
        while (folders.Count > 0)
        {
            var folder = folders.Pop();
            if (folder.Attributes.HasFlag(FileAttributes.ReparsePoint)) { folder.Delete(); continue; }
            visited.Add(folder);
            foreach (var entry in folder.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = true }))
            {
                if (entry is DirectoryInfo child) folders.Push(child);
                else { try { entry.Attributes = FileAttributes.Normal; entry.Delete(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Take(entry.FullName); entry.Attributes = FileAttributes.Normal; entry.Delete(); } }
            }
        }
        visited.Reverse();
        foreach (var folder in visited) { try { folder.Attributes = FileAttributes.Directory; folder.Delete(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Take(folder.FullName); folder.Delete(); } }
    }

    private static void Take(string path)
    {
        Run("takeown.exe", "/F \"" + path.Replace(@"\\?\", "") + "\" /A");
        Run("icacls.exe", "\"" + path.Replace(@"\\?\", "") + "\" /reset /C /Q");
    }

    public static void Sweep(string name)
    {
        foreach (var path in Directory.GetDirectories(Local, name + ".*").Concat(Directory.GetDirectories(Local, name + "-*"))) Delete(path);
    }

    public static long Length(string path) => File.Exists(Long(path)) ? new FileInfo(Long(path)).Length : -1;

    public static string? Read(string path) { try { return File.ReadAllText(Long(path)); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; } }

    public static string[] Names(string folder) => Directory.Exists(folder) ? LocalTree.Entries(folder, links: true).Select(entry => Path.GetRelativePath(folder, entry.FullName)).OrderBy(path => path, StringComparer.OrdinalIgnoreCase).ToArray() : [];

    public static object? Api(Type type, string name, params object?[] arguments)
    {
        var method = type.GetMethod(name, arguments.Select(argument => argument?.GetType() ?? typeof(string)).ToArray()) ?? throw new MissingMethodException(type.Name + "." + name);
        try { return method.Invoke(null, arguments); }
        catch (System.Reflection.TargetInvocationException error) { throw error.InnerException!; }
    }

    public static bool Has(Type type, string name) => type.GetMethods().Any(method => method.Name == name);

    public static string[] Aside(string root, string kind = "untrusted") => Directory.GetDirectories(Path.GetDirectoryName(root)!, Path.GetFileName(root) + "." + kind + "-*");
}

static class DataRootChild
{
    public static void Run(string[] args)
    {
        try
        {
            switch (args[0])
            {
                case "--timer-worker-fake": Thread.Sleep(TimeSpan.FromMinutes(3)); return;
                case "--child-secure-data":
                    var migrated = PolicyRootSecurity.Secure(args[1], DataFolder.Kind);
                    if (args.Contains("--resume")) typeof(DataFolder).GetMethod("ResumeInterrupted", [typeof(string)])?.Invoke(null, [args[1]]);
                    Console.WriteLine("SECURED migrated=" + migrated);
                    return;
                case "--child-secure-operations": Console.WriteLine("SECURED migrated=" + OperationsFolder.Secure(args[1])); return;
                case "--child-resolve": Console.WriteLine("ROOT " + BrandCompatibility.DataRoot(args[1])); return;
                case "--child-data-root":
                    if (args[1] == "pin-first") { RooIndustries.Optimizer.RuntimeEnvironment.Sanitize(); RooIndustries.Optimizer.RuntimeEnvironment.PinProfile(); }
                    Console.WriteLine("ROOT " + BrandCompatibility.LocalDataRoot);
                    Console.WriteLine("LOCAL " + Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
                    return;
                case "--child-writer": Writer(args[1], int.Parse(args[2]), int.Parse(args[3])); return;
                case "--child-standard": Standard(args[1..]); return;
            }
        }
        catch (Exception error) { Console.WriteLine("FAILED " + error.GetType().Name + ": " + error.Message); Environment.ExitCode = 1; }
    }

    private static void Writer(string root, int milliseconds, int limit)
    {
        var clock = Stopwatch.StartNew(); var count = 0;
        while (clock.ElapsedMilliseconds < milliseconds && count < limit)
        {
            if (!Directory.Exists(root))
            {
                try { Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "writer-" + count + ".txt"), "written while the folder was being protected " + count); count++; }
                catch (IOException) { }
            }
            Thread.SpinWait(2000);
        }
        Console.WriteLine("WRITER recreated " + count);
    }

    private static void Standard(string[] args)
    {
        switch (args[0])
        {
            case "whoami":
                using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent())
                    Console.WriteLine("WHOAMI admin-group=" + new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) + " assembly=" + System.Reflection.Assembly.GetEntryAssembly()!.Location);
                return;
            case "junction": Console.WriteLine(Native.Junction(args[1], args[2])); return;
            case "write":
                try { File.WriteAllText(args[1], args[2]); Console.WriteLine("WROTE"); } catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name); }
                return;
            case "rename":
                try { Directory.Move(args[1], args[2]); Console.WriteLine("RENAMED"); } catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name); }
                return;
            case "delete":
                try { File.Delete(args[1]); Console.WriteLine("DELETED"); } catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name); }
                return;
            case "plant":
                try
                {
                    foreach (var item in args[2..])
                    {
                        var split = item.IndexOf('|');
                        var path = Path.Combine(args[1], item[..split]);
                        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                        File.WriteAllText(path, item[(split + 1)..]);
                    }
                    Console.WriteLine("PLANTED");
                }
                catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name + " " + error.Message); }
                return;
            case "junction-new":
                try { Directory.CreateDirectory(args[1]); Console.WriteLine(Native.Junction(args[1], args[2])); } catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name); }
                return;
            case "mkdir":
                try { Directory.CreateDirectory(args[1]); Console.WriteLine("CREATED"); } catch (Exception error) { Console.WriteLine("DENIED " + error.GetType().Name); }
                return;
        }
    }

    private static class Native
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, int inputSize, byte[]? output, int outputSize, out int returned, IntPtr overlapped);

        public static string Junction(string directory, string target)
        {
            var substitute = Encoding.Unicode.GetBytes(@"\??\" + target); var print = Encoding.Unicode.GetBytes(target);
            var buffer = new byte[16 + substitute.Length + 2 + print.Length + 2];
            BitConverter.GetBytes(0xA0000003u).CopyTo(buffer, 0);
            BitConverter.GetBytes((ushort)(buffer.Length - 8)).CopyTo(buffer, 4);
            BitConverter.GetBytes((ushort)substitute.Length).CopyTo(buffer, 10);
            BitConverter.GetBytes((ushort)(substitute.Length + 2)).CopyTo(buffer, 12);
            BitConverter.GetBytes((ushort)print.Length).CopyTo(buffer, 14);
            substitute.CopyTo(buffer, 16); print.CopyTo(buffer, 16 + substitute.Length + 2);
            using var handle = CreateFileW(directory, 0x2, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) return "OPEN-FAILED " + Marshal.GetLastWin32Error();
            return DeviceIoControl(handle, 0x000900A4, buffer, buffer.Length, null, 0, out _, IntPtr.Zero) ? "CONVERTED" : "SET-FAILED " + Marshal.GetLastWin32Error();
        }
    }
}
