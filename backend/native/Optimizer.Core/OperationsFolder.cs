#nullable enable
namespace RooIndustries.Optimizer;

public static class OperationsFolder
{
    public const string NotAdministrator = "Changes need administrator rights. Open the app as an administrator and try again.";
    public const string TimerFolder = "windows-timer";

    public static string EarlierBackup(string path) => "This backup was made by an earlier version of the app, before its data folder was protected, so it can't be restored automatically. Its files are kept at " + Path.GetDirectoryName(Path.GetFullPath(path)) + ".";

    public static readonly ProtectedFolder Kind = new("app's recovery folder", "try again (its undo history will be lost)",
        "A running game session or another Roo Industries task is using the app's recovery folder, so it could not be protected yet. Close the game's launcher or restart Windows, then try again.",
        NotAdministrator, true, [], Quiesce, Skip);

    public static string DefaultRoot => Path.Combine(BrandCompatibility.LocalDataRoot, "operations");

    private static Action? Quiesce(string root)
        => TimerControl.EndLegacyWorker(root, null) ? () => TimerControl.StartAfterMove(root) : null;

    public static SkipDecision? Skip(string relative, bool folder)
    {
        var parts = relative.Split(Path.DirectorySeparatorChar);
        return parts.Length == 2 && !folder && string.Equals(parts[0], TimerFolder, StringComparison.OrdinalIgnoreCase) &&
            parts[1].ToLowerInvariant() is "launch.json" or "stop.json" or "session.json" ? new("timer state of a process that has ended", Keep: false) : null;
    }

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
        if (PolicyRootSecurity.Elevated()) EnsureTimerFolder(root);
        return root;
    }

    public static string EnsureTimerFolder(string root)
    {
        var folder = Path.Combine(PolicyRootSecurity.Normalize(root), TimerFolder);
        var info = new DirectoryInfo(folder);
        if (info.Exists && (info.Attributes.HasFlag(FileAttributes.ReparsePoint) || PolicyRootSecurity.WriterOf(folder) is not null || !PolicyRootSecurity.OwnedByAdministrators(folder)))
        {
            var aside = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(PolicyRootSecurity.Normalize(root)))!, Path.GetFileName(Path.GetDirectoryName(PolicyRootSecurity.Normalize(root))!) + ".untrusted-timer-" + Guid.NewGuid().ToString("N"));
            Directory.Move(folder, aside);
        }
        if (!Directory.Exists(folder)) Directory.CreateDirectory(folder);
        return folder;
    }

    public static void RequireControlFolder(string folder)
    {
        var info = new DirectoryInfo(folder);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint) || PolicyRootSecurity.WriterOf(folder) is not null || !PolicyRootSecurity.OwnedByAdministrators(folder))
            throw new UnauthorizedAccessException("The timer's control folder is not protected (it is missing, a link, or an ordinary user can change it), so it is not used. Open the app as an administrator to repair it.");
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
            return Lease(directory);
        }
        throw new UnauthorizedAccessException("The game session folder is not inside the app's protected recovery folder. Open the app as an administrator and try again.");
    }
}
