#nullable enable
namespace RooIndustries.Optimizer;

public static class DataFolder
{
    public const string NotProtected = "The app's data folder is not protected yet. Open the app as an administrator, then try again.";

    public static readonly ProtectedFolder Kind = new("app's data folder", "open the app again (its saved settings and undo history will be lost)",
        "A running game session, the Roo Industries Governor or another Roo Industries task is using the app's data folder, so it could not be protected yet. Close the game's launcher or restart Windows, then open the app again.",
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
        var rules = new ProcessPolicyStore(Path.Combine(root, "process-rules"));
        try
        {
            if (Directory.Exists(rules.Root) && rules.RequestStop())
            {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (rules.Status().HostRunning == true && clock.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(200);
            }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
        return TimerControl.SuspendForMove(Path.Combine(root, "operations"));
    }
}
