#nullable enable
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public static class DataFolder
{
    public const string NotProtected = "The app's data folder is not protected yet. Open the app as an administrator, then try again.";
    public const string SuspendKey = @"SOFTWARE\RooIndustries\OptimizationSuite\SuspendedForMove";

    public static readonly ProtectedFolder Kind = new("app's data folder", "open the app again (its saved settings and undo history will be lost)",
        "The app's data folder could not be protected yet because Windows would not let the app move it. Something has a file inside it open: a File Explorer window showing the folder, a game launcher or another Roo Industries task. Close those or restart Windows, then open the app again.",
        OperationsFolder.NotAdministrator, true, [], Quiesce, Skip);

    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static PolicyRootLease? _lease;
    private static bool _resumed;

    private sealed record Suspended(string[] Tasks, bool Timer, string Operations);

    public static string Root => PolicyRootSecurity.Normalize(BrandCompatibility.LocalDataRoot);

    public static bool Holds(string child) => string.Equals(Path.GetDirectoryName(PolicyRootSecurity.Normalize(child)), Root, StringComparison.OrdinalIgnoreCase);

    public static bool Secured(string root) => PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) && PolicyRootSecurity.Problem(root, Kind, deep: false) is null;

    public static string Ensure()
    {
        var root = Root;
        if (!Secured(root)) PolicyRootSecurity.Secure(root, Kind);
        if (PolicyRootSecurity.Elevated()) { PolicyRootSecurity.RepairMarker(root); ResumeInterrupted(root); }
        return root;
    }

    public static void EnsureFor(string child)
    {
        if (Holds(child)) Ensure();
    }

    public static string Require()
    {
        if (!PolicyRootSecurity.Elevated()) return Root;
        lock (Gate)
        {
            var root = Root;
            if (_lease is { Moved: false }) return root;
            if (!_resumed) { _resumed = true; ResumeInterrupted(root); }
            if (!PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root))) throw new UnauthorizedAccessException(NotProtected);
            PolicyRootSecurity.RepairMarker(root);
            PolicyRootLease lease;
            try { lease = PolicyRootLease.Acquire(root, Kind, deep: false); }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException) { throw new UnauthorizedAccessException(NotProtected + " (" + error.Message + ")", error); }
            _lease?.Dispose();
            _lease = lease;
            return root;
        }
    }

    private static SkipDecision? Skip(string relative, bool folder)
    {
        var parts = relative.Split(Path.DirectorySeparatorChar);
        bool Is(int index, string name) => parts.Length > index && string.Equals(parts[index], name, StringComparison.OrdinalIgnoreCase);
        if (Is(0, "tools") || Is(0, "tool-cache")) return new("it holds programs unpacked before the folder was protected; the app unpacks them again when needed");
        if (Is(0, "firmware") && (Is(1, "packages") || parts.Length == 2 && !folder && Is(1, "workspace.json")))
            return new("it holds the BIOS tool package from before the folder was protected; set the BIOS tool up again on the Firmware page");
        if (Is(0, "settings") && parts.Length == 2 && !folder && Is(1, "custom-windows-settings.json"))
            return new("it defines Windows changes and was saved before the folder was protected; import the custom settings file again on the Windows settings page");
        if (Is(0, "temp")) return new("temporary files", Keep: false);
        return Is(0, "operations") && parts.Length > 1 ? OperationsFolder.Skip(string.Join(Path.DirectorySeparatorChar, parts[1..]), folder) : null;
    }

    public static string TaskPrefix(string defaultPrefix)
    {
#if GOVERNOR_TEST_HOOKS
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_GOVERNOR_TASK_PREFIX") is { Length: > 0 } test) return test;
#endif
        return defaultPrefix;
    }

    private static Suspended? Load(string marker)
    {
        using var key = Registry.LocalMachine.OpenSubKey(SuspendKey);
        try { return key?.GetValue(marker) is string text ? JsonSerializer.Deserialize<Suspended>(text, Json) : null; }
        catch (JsonException) { return null; }
    }

    private static void Save(string marker, Suspended record)
    {
        using var key = Registry.LocalMachine.CreateSubKey(SuspendKey, true);
        key.SetValue(marker, JsonSerializer.Serialize(record, Json), RegistryValueKind.String);
    }

    private static void Forget(string marker)
    {
        using var key = Registry.LocalMachine.OpenSubKey(SuspendKey, true);
        key?.DeleteValue(marker, false);
    }

    private static Action? Quiesce(string root)
    {
        static bool Link(string path) => Directory.Exists(path) && new DirectoryInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint);
        var marker = PolicyRootSecurity.MarkerName(root);
        if (Link(root)) return null;
        var record = Load(marker) ?? new([], false, "");
        var tasks = record.Tasks.ToList();
        var rules = new ProcessPolicyStore(Path.Combine(root, "process-rules"));
        if (Directory.Exists(rules.Root) && !Link(rules.Root))
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var suffix = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity.User!.Value + "|" + rules.Root.ToUpperInvariant())))[..20];
            foreach (var name in new[] { @"\" + TaskPrefix("RooIndustriesOptimizationSuite.ProcessRules.") + suffix, @"\" + TaskPrefix("RooOptimizationSuite.ProcessRules.") + suffix }.Distinct())
            {
                if (Schtasks("/Query", "/TN", name, "/XML") is not { } xml || Regex.IsMatch(xml, "(?s)<Settings>.*?<Enabled>false</Enabled>.*?</Settings>") || tasks.Contains(name)) continue;
                tasks.Add(name);
                Save(marker, record with { Tasks = tasks.ToArray() });
                Schtasks("/Change", "/TN", name, "/DISABLE");
            }
            foreach (var name in tasks) Schtasks("/End", "/TN", name);
            if (PolicyRootSecurity.Problem(rules.Root, ProtectedFolder.Rules, deep: false) is null)
            {
                try
                {
                    if (rules.RequestStop())
                    {
                        var clock = Stopwatch.StartNew();
                        while (rules.Status().HostRunning == true && clock.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(200);
                    }
                }
                catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or UnauthorizedAccessException or JsonException) { }
            }
            else Thread.Sleep(500);
        }
        var operations = Path.Combine(root, "operations");
        var timer = record.Timer;
        if (!Link(operations) && TimerControl.EndLegacyWorker(operations, () => { timer = true; Save(marker, new(tasks.ToArray(), true, operations)); })) timer = true;
        record = new(tasks.ToArray(), timer, operations);
        if (record.Tasks.Length == 0 && !record.Timer) return null;
        Save(marker, record);
        return () => ResumeFrom(marker, record);
    }

    private static void ResumeFrom(string marker, Suspended record)
    {
        var failed = new List<string>();
        foreach (var name in record.Tasks)
        {
            if (Schtasks("/Query", "/TN", name, "/XML") is null) continue;
            if (Schtasks("/Change", "/TN", name, "/ENABLE") is null) failed.Add(name);
            else Schtasks("/Run", "/TN", name);
        }
        var timer = record.Timer;
        if (timer)
        {
            try { TimerControl.StartAfterMove(record.Operations); timer = false; }
            catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException or InvalidDataException or System.ComponentModel.Win32Exception or TimeoutException) { }
        }
        if (failed.Count == 0 && !timer) Forget(marker);
        else Save(marker, new(failed.ToArray(), timer, record.Operations));
    }

    public static void ResumeInterrupted() => ResumeInterrupted(Root);

    public static void ResumeInterrupted(string root)
    {
        var marker = PolicyRootSecurity.MarkerName(root);
        if (Load(marker) is null) return;
        using var mutex = new Mutex(false, PolicyRootSecurity.MutexName(marker));
        bool held;
        try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
        if (!held) return;
        try { if (Load(marker) is { } record) ResumeFrom(marker, record); }
        finally { mutex.ReleaseMutex(); }
    }

    private static string? Schtasks(params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start);
        if (process is null) return null;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30000)) { try { process.Kill(true); } catch (InvalidOperationException) { } return null; }
        process.WaitForExit();
        errors.GetAwaiter().GetResult();
        return process.ExitCode == 0 ? output.GetAwaiter().GetResult() : null;
    }
}
