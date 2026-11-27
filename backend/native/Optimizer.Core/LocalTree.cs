#nullable enable
using System.IO.Enumeration;

namespace RooIndustries.Optimizer;

public static class LocalTree
{
    public static IEnumerable<FileSystemInfo> Entries(
        string root, string pattern = "*", bool links = false, bool skipInaccessible = false)
    {
        if (File.GetAttributes(root).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("A walk does not start at a link: " + root);
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = skipInaccessible };
        options.AttributesToSkip = links ? 0 : FileAttributes.ReparsePoint;
        return new FileSystemEnumerable<FileSystemInfo>(root, (ref FileSystemEntry entry) => entry.ToFileSystemInfo(), options)
        {
            ShouldIncludePredicate = (ref FileSystemEntry entry) =>
                FileSystemName.MatchesSimpleExpression(pattern, entry.FileName),
            ShouldRecursePredicate = (ref FileSystemEntry entry) =>
                !entry.Attributes.HasFlag(FileAttributes.ReparsePoint),
        };
    }
}
