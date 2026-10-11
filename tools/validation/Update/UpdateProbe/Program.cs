using System.Text.Json;
using System.Reflection;
using RooIndustries.Optimizer;

static void Save(string path, object value)
{
    var nonce = Environment.GetEnvironmentVariable("ROO_HARNESS_NONCE") ?? throw new InvalidOperationException("Invocation nonce is required");
    using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    JsonSerializer.Serialize(output, new { nonce, data = value });
}

if (args is ["--resources", var resourceAssembly, var resourceOutput])
{
    var assembly = Assembly.LoadFile(Path.GetFullPath(resourceAssembly));
    var resources = assembly.GetManifestResourceNames().OrderBy(name => name).Select(name =>
    {
        using var input = assembly.GetManifestResourceStream(name)!;
        return new { name, sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(input)).ToLowerInvariant() };
    }).ToArray();
    Save(resourceOutput, resources);
    return;
}
if (args is ["--embedded-feed", var assemblyPath, var outputPath])
{
    var assembly = Assembly.LoadFile(Path.GetFullPath(assemblyPath));
    using var resource = assembly.GetManifestResourceStream("RooIndustries.UpdateFeed") ?? throw new InvalidDataException("Embedded feed is missing");
    using var reader = new StreamReader(resource);
    var feed = reader.ReadToEnd().Trim();
    Save(outputPath, new { assemblyPath, feed });
    Console.WriteLine(feed);
    return;
}
if (args is ["--install-space", var installPath, var spaceOutput])
{
    var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(installPath))!);
    var threshold = 1L << 30;
    var rows = new[] { threshold - 1, threshold, threshold + 1 }.Select(bytes => new { bytes, reason = UpdateFeed.InstallDriveSpaceReason(drive.Name, bytes) }).ToArray();
    if (rows[0].reason != "Free at least 1 GB on drive " + drive.Name.TrimEnd('\\', '/') + " and try again." || rows[1].reason is not null || rows[2].reason is not null)
        throw new InvalidDataException("Install-space comparison failed");
    Save(spaceOutput, new { installPath, drive = drive.Name, availableFreeSpace = drive.AvailableFreeSpace, threshold, rows, realLowDisk = false });
    Console.WriteLine("Install-drive threshold boundaries passed");
    return;
}
if (args.Length < 4) throw new ArgumentException("manifest feed-url current-version output [installer]");
var result = UpdateFeed.Verify(File.ReadAllBytes(args[0]), 200, new Uri(args[1]), args[2]);
UpdateFileResult? file = null;
if (args.Length == 5 && result.Release is { } release)
{
    using var input = new FileStream(args[4], FileMode.Open, FileAccess.Read, FileShare.Read);
    file = await UpdateFeed.VerifyInstallerAsync(input, release);
}
var comparisons = new[]
{
    ("1.0.0-alpha", "1.0.0-alpha.1", -1), ("1.0.0-alpha.1", "1.0.0-alpha.beta", -1),
    ("1.0.0-alpha.beta", "1.0.0-beta", -1), ("1.0.0-beta", "1.0.0-beta.2", -1),
    ("1.0.0-beta.2", "1.0.0-beta.11", -1), ("1.0.0-beta.11", "1.0.0-rc.1", -1),
    ("1.0.0-rc.1", "1.0.0", -1), ("1.0.0+one", "1.0.0+two", 0),
    ("1.0.0-beta.999999999999999999999", "1.0.0-beta.1000000000000000000000", -1),
};
foreach (var (left, right, expected) in comparisons)
    if (!SemanticVersion.TryParse(left, out var a) || !SemanticVersion.TryParse(right, out var b) || Math.Sign(a!.CompareTo(b)) != expected)
        throw new InvalidDataException("SemVer precedence failed: " + left + " vs " + right);
foreach (var invalid in new[] { "01.0.0", "1.0", "1.0.0-beta.01", "1.0.0-", "1.0.0+", "1.0.0/a", "1.0.0\n" })
    if (SemanticVersion.TryParse(invalid, out _)) throw new InvalidDataException("Invalid SemVer accepted: " + invalid);
Save(args[3], new { result, file, semverChecks = comparisons.Length + 7 });
Console.WriteLine(JsonSerializer.Serialize(new { result.Kind, result.Reason, file }));
