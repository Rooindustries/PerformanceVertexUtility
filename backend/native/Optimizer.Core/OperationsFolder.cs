#nullable enable
namespace RooIndustries.Optimizer;

public static class OperationsFolder
{
    public const string NotAdministrator = "Changes need administrator rights. Open the app as an administrator and try again.";
    public const string TimerFolder = "windows-timer";

    public static string EarlierBackup(string path) => "This backup was made by an earlier version of the app, before its data folder was protected, so it can't be restored automatically. Its files are kept at " + Path.GetDirectoryName(Path.GetFullPath(path)) + ".";

    public static readonly ProtectedFolder Kind = new("app's recovery folder", "try again (its undo history will be lost)",
        "A running game session or another Roo Industries task is using the app's recovery folder, so it could not be protected yet. Close the game's launcher or restart Windows, then try again.",
        NotAdministrator, true, [], TimerFolder, TimerControl.SuspendForMove);

    public static string DefaultRoot => Path.Combine(BrandCompatibility.LocalDataRoot, "operations");

    public static bool Secure(string root)
    {
        DataFolder.EnsureFor(root);
        return PolicyRootSecurity.Secure(root, Kind);
    }

    public static string Ensure(string root)
    {
        root = PolicyRootSecurity.Normalize(root);
        DataFolder.EnsureFor(root);
        if (!PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) || PolicyRootSecurity.Problem(root, Kind, deep: false) is not null) Secure(root);
        if (PolicyRootSecurity.Elevated()) PolicyRootSecurity.RepairUserFolder(root, Kind);
        return root;
    }

    public static PolicyRootLease Lease(string root) => PolicyRootLease.Acquire(root, Kind, deep: false);

    public static PolicyRootLease LeaseContaining(string path)
    {
        var full = PolicyRootSecurity.Normalize(path);
        for (var directory = Path.GetDirectoryName(full); directory is not null; directory = Path.GetDirectoryName(directory))
        {
            if (!Directory.Exists(directory)) continue;
            if (PolicyRootSecurity.WriterOf(directory) is not null) break;
            if (PolicyRootSecurity.Problem(directory, Kind, deep: false) is not null) continue;
            var lease = Lease(directory);
            var timer = Path.Combine(directory, TimerFolder) + Path.DirectorySeparatorChar;
            if (!full.StartsWith(timer, StringComparison.OrdinalIgnoreCase) && !string.Equals(full + Path.DirectorySeparatorChar, timer, StringComparison.OrdinalIgnoreCase)) return lease;
            lease.Dispose();
            break;
        }
        throw new UnauthorizedAccessException("The game session folder is not inside the app's protected recovery folder. Open the app as an administrator and try again.");
    }
}
