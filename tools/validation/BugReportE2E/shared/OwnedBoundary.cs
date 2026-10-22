using System.Text.RegularExpressions;
namespace Roo70Fixture;
public sealed record OwnedBoundary(string Frame, string Data, string Output, string Nonce)
{
    public static OwnedBoundary Parse(string[] args)
    {
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Windows desktop fixture only.");
        if (args.Length != 6 || args[0] != "--owned-root" || args[2] != "--nonce" || args[4] != "--output")
            throw new ArgumentException("Exact owned-root/nonce/output CLI required.");
        var nonce = args[3];
        if (!Regex.IsMatch(nonce, "\\A[0-9a-f]{32}\\z")) throw new ArgumentException("Invalid nonce.");
        string Full(string value)
        {
            if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("Full owned path required.");
            return Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
        }
        var data = Full(args[1]);
        var output = Full(args[5]);
        string Frame(string value)
        {
            for (var item = Directory.GetParent(value); item is not null; item = item.Parent)
                if (Regex.IsMatch(item.FullName, @"\AC:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-" + nonce + @"\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) return item.FullName;
            throw new ArgumentException("No same-nonce original staging frame ancestor.");
        }
        var frame = Frame(data);
        if (!string.Equals(Frame(output), frame, StringComparison.OrdinalIgnoreCase)
            || data.Equals(output, StringComparison.OrdinalIgnoreCase)
            || output.StartsWith(data + "\\", StringComparison.OrdinalIgnoreCase)
            || data.StartsWith(output + "\\", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Separate original-ledger data/output leaves required.");
        foreach (var path in new[] { data, output })
        {
            for (DirectoryInfo? item = new(path); item is not null; item = item.Parent)
                if (!item.Exists || (item.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Owned ancestors must exist without reparses.");
            if (Directory.EnumerateFileSystemEntries(path).Any()) throw new InvalidOperationException("Owned leaves must already exist and be empty.");
        }
        return new(frame, data, output, nonce);
    }
}
