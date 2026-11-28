using System.Security.AccessControl;
using RooIndustries.Optimizer;

static class VolumeWriteChecks
{
    private sealed record Generation(int Number);

    public static void Run(Action<bool, string> check, string directory, string label, bool keepsPermissions)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "cs-state.json");
        OperationFiles.Write(path, new Generation(1));
        var created = File.GetCreationTimeUtc(path);
        var security = Security(path);
        Thread.Sleep(1100);
        OperationFiles.Write(path, new Generation(2));
        check(OperationFiles.Read<Generation>(path).Number == 2 && File.GetCreationTimeUtc(path) == created,
            label + ": the C# writer replaces a saved file and keeps its creation time");
        if (keepsPermissions)
            check(Security(path) == security, label + ": the C# rewrite keeps the file's owner and permissions");
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            OperationFiles.Write(path, new Generation(3));
        check(OperationFiles.Read<Generation>(path).Number == 3,
            label + ": a C# rewrite succeeds while a reader holds the file");
    }

    private static string Security(string path)
    {
        var sections = AccessControlSections.Owner | AccessControlSections.Access;
        return new FileInfo(path).GetAccessControl().GetSecurityDescriptorSddlForm(sections);
    }
}
