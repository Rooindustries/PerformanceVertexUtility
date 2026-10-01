#nullable enable
namespace RooIndustries.Optimizer;

public static class DataFolder
{
    public const string NotProtected = "The app's data folder is not protected yet. Open the app as an administrator, then try again.";

    public static readonly ProtectedFolder Kind = new("app's data folder", "open the app again (its saved settings and undo history will be lost)",
        "A File Explorer window, a running game session or another Roo Industries task is using the app's data folder, so it could not be protected yet. Close File Explorer windows showing that folder and the game's launcher, or restart Windows, then open the app again.",
        OperationsFolder.NotAdministrator, true, [],
        Path.Combine("operations", OperationsFolder.TimerFolder), Quiesce);

    private static readonly object Gate = new();
    private static PolicyRootLease? _lease;

    public static string Root => PolicyRootSecurity.Normalize(BrandCompatibility.LocalDataRoot);

    public static bool Holds(string child) => string.Equals(Path.GetDirectoryName(PolicyRootSecurity.Normalize(child)), Root, StringComparison.OrdinalIgnoreCase);

    public static bool Secured(string root) => PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) && PolicyRootSecurity.Problem(root, Kind, deep: false) is null;

    public static string Ensure()
    {
        var root = Root;
        if (!Secured(root)) PolicyRootSecurity.Secure(root, Kind);
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
            if (!PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root))) throw new UnauthorizedAccessException(NotProtected);
            PolicyRootLease lease;
            try { lease = PolicyRootLease.Acquire(root, Kind, deep: false); }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException) { throw new UnauthorizedAccessException(NotProtected + " (" + error.Message + ")", error); }
            _lease?.Dispose();
            _lease = lease;
            return root;
        }
    }

    private static Action? Quiesce(string root)
    {
        static bool Link(string path) => Directory.Exists(path) && new DirectoryInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint);
        if (Link(root)) return null;
        var paused = new List<string>();
        var rules = new ProcessPolicyStore(Path.Combine(root, "process-rules"));
        if (Directory.Exists(rules.Root) && !Link(rules.Root))
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var suffix = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(identity.User!.Value + "|" + rules.Root.ToUpperInvariant())))[..20];
            foreach (var name in new[] { @"\RooIndustriesOptimizationSuite.ProcessRules." + suffix, @"\RooOptimizationSuite.ProcessRules." + suffix })
                if (Schtasks("/Query", "/TN", name, "/XML") is { } xml && !System.Text.RegularExpressions.Regex.IsMatch(xml, "(?s)<Settings>.*?<Enabled>false</Enabled>.*?</Settings>") &&
                    Schtasks("/Change", "/TN", name, "/DISABLE") is not null) paused.Add(name);
            try
            {
                if (rules.RequestStop())
                {
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    while (rules.Status().HostRunning == true && clock.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(200);
                }
            }
            catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
        }
        Action? timer;
        try { timer = Link(Path.Combine(root, "operations")) ? null : TimerControl.SuspendForMove(Path.Combine(root, "operations")); }
        catch
        {
            foreach (var name in paused) Schtasks("/Change", "/TN", name, "/ENABLE");
            throw;
        }
        if (timer is null && paused.Count == 0) return null;
        return () =>
        {
            try { timer?.Invoke(); }
            finally { foreach (var name in paused) Schtasks("/Change", "/TN", name, "/ENABLE"); }
        };
    }

    private static string? Schtasks(params string[] arguments)
    {
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = System.Diagnostics.Process.Start(start);
        if (process is null) return null;
        var output = process.StandardOutput.ReadToEndAsync();
        process.StandardError.ReadToEnd();
        if (!process.WaitForExit(30000)) { process.Kill(); return null; }
        return process.ExitCode == 0 ? output.GetAwaiter().GetResult() : null;
    }
}
