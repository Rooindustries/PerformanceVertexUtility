using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using RooIndustries.OptimizationSuite.Services;

namespace Roo70Fixture;

internal static class Boundary
{
    public static string? Root { get; private set; }

    public static void Bind(string root)
    {
        if (Root is not null) throw new InvalidOperationException("Owned log root already bound.");
        Root = root;
    }
}

internal sealed record LogCase(string Id, string Input, string Expected);

internal static class Program
{
    private const string SourceCommit = BuildBinding.SourceCommit;
    private const string AppLogSha256 = BuildBinding.AppLogSha256;
    private const string RedactorSha256 = BuildBinding.RedactorSha256;
    private const string SourceTag = "roo70-fixture";
    private const string PositiveMarker = "ROO_INDUSTRIES_BUG_REPORT_APPLOG_9PASS";

    public static int Main(string[] args)
    {
        try
        {
            if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Windows execution required.");
            if (args.Length == 5 && args[0] == "--reader-holder") return ReaderAdverse.Hold(args[1], args[2], args[3], args[4]);
            if (args.Length != 3) throw new ArgumentException("Exactly frameRoot, ownedLogRoot and nonce are required.");
            var nonce = args[2];
            if (!Regex.IsMatch(nonce, "\\A[0-9a-f]{32}\\z", RegexOptions.CultureInvariant))
                throw new ArgumentException("Invalid owned nonce.");
            var frameRoot = FullDirectory(args[0]);
            var ownedLogRoot = FullDirectory(args[1]);
            if (!frameRoot.StartsWith(@"C:\RooBuild\", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Frame must be below the approved staging parent.");
            if (!ownedLogRoot.StartsWith(frameRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || Path.GetFileName(ownedLogRoot) != "pvu70-applog-" + nonce)
                throw new ArgumentException("Log root must be the named owned descendant.");
            RequirePlainAncestors(frameRoot);
            RequirePlainAncestors(ownedLogRoot);
            if (Directory.EnumerateFileSystemEntries(ownedLogRoot).Any())
                throw new InvalidOperationException("Owned log leaf must already exist and be empty.");
            var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var user = Environment.UserName;
            var machine = Environment.MachineName;
            if (string.IsNullOrWhiteSpace(profile)) throw new InvalidOperationException("Actual profile root is unavailable.");
            if (user.Length < 2 || machine.Length < 2) throw new InvalidOperationException("Actual user and machine names must each have at least two characters.");
            LogCase[] cases =
            [
                new LogCase("raw", @"C:\Users\" + @"Zqx Bob O'Neil\AppData\x.log", @"C:\Users\<user>\AppData\x.log"),
                new LogCase("forward", "C:/Users/" + "Zqxbob/AppData/x.log", "C:/Users/<user>/AppData/x.log"),
                new LogCase("r9", @"C:/Users/\u003Cuser\u003E%USERPROFILE%\u003Cuser\u003EZqxbob/x", "C:/Users/<user>/x"),
                new LogCase("own", profile + @"\AppData\x.log", @"%USERPROFILE%\AppData\x.log"),
                new LogCase("user", user, "<user>"),
                new LogCase("machine", machine, "<pc-name>"),
                new LogCase("sid", "S-1-5-21-11-22-33-44", "<sid>"),
                new LogCase("shared", "C:/Users/Public/x.log", "C:/Users/Public/x.log"),
                new LogCase("already-redacted", "C:/Users/<user>/x.log", "C:/Users/<user>/x.log")
            ];
            if (cases.Length != 9) throw new InvalidOperationException("Nine planned writes are required.");
            foreach (var item in cases) { RequireRoundTrip(item.Input); RequireRoundTrip(item.Expected); }
            if (AppLog.Observer is not null) throw new InvalidOperationException("No log observer is permitted.");
            Boundary.Bind(ownedLogRoot);
            var filePath = Path.Combine(ownedLogRoot, "logs", "app.log");
            if (AppLog.FilePath != filePath) throw new InvalidOperationException("AppLog selected an unexpected sink.");
            if (!AppLog.Enable()) throw new InvalidOperationException("AppLog did not enable.");
            foreach (var item in cases) AppLog.Write(SourceTag, item.Input);
            if (!File.Exists(filePath)) throw new InvalidOperationException("Actual AppLog sink was not created.");
            if (File.Exists(filePath + ".old")) throw new InvalidOperationException("Unexpected rotated log.");
            var maxBytes = (long)(typeof(AppLog).GetField("MaxBytes", BindingFlags.NonPublic | BindingFlags.Static)?.GetRawConstantValue()
                ?? throw new InvalidOperationException("Production log budget is unavailable."));
            var info = new FileInfo(filePath);
            if (info.Length <= 0 || info.Length >= maxBytes) throw new InvalidOperationException("Actual log size is outside its budget.");
            var bytes = File.ReadAllBytes(filePath);
            var text = new UTF8Encoding(false, true).GetString(bytes);
            RequireRoundTrip(text);
            var allLines = text.Split(Environment.NewLine, StringSplitOptions.None);
            if (allLines.Length != cases.Length + 1 || allLines[^1] != "")
                throw new InvalidOperationException("Actual line count or final newline differs from nine writes.");
            var tag = " [" + SourceTag + "] ";
            var actual = new List<object>();
            for (var index = 0; index < cases.Length; index++)
            {
                var line = allLines[index];
                if (line.Length < 19 + tag.Length
                    || !DateTime.TryParseExact(line.AsSpan(0, 19), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)
                    || !line.AsSpan(19).StartsWith(tag, StringComparison.Ordinal))
                    throw new InvalidOperationException("Timestamp or fixed source tag mismatch at case " + cases[index].Id + ".");
                var payload = line[(19 + tag.Length)..];
                RequireRoundTrip(payload);
                if (payload != cases[index].Expected)
                    throw new InvalidOperationException("Exact payload mismatch at case " + cases[index].Id + ".");
                actual.Add(new { id = cases[index].Id, input = cases[index].Input, expected = cases[index].Expected,
                    actualPayload = payload, timestamp = line[..19], passed = true });
            }
            var leafEntries = Directory.GetFileSystemEntries(ownedLogRoot);
            var logEntries = Directory.GetFileSystemEntries(Path.Combine(ownedLogRoot, "logs"));
            if (leafEntries.Length != 1 || leafEntries[0] != Path.Combine(ownedLogRoot, "logs")
                || logEntries.Length != 1 || logEntries[0] != filePath)
                throw new InvalidOperationException("Unexpected owned leaf resources.");
            RequirePlainAncestors(Path.Combine(ownedLogRoot, "logs"));
            if ((File.GetAttributes(filePath) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Log file is a reparse point.");
            var assemblyPath = Assembly.GetExecutingAssembly().Location;
            var receipt = new
            {
                sourceCommit = SourceCommit,
                sourceHashes = new { appLog = AppLogSha256, redactor = RedactorSha256 },
                frameRoot, ownedLogRoot, nonce,
                environment = new { profile, user, machine },
                path = filePath, caseCount = cases.Length, passCount = actual.Count, cases = actual,
                fileLength = info.Length, maxBytes, encoding = "UTF-8 strict", fileSha256 = Hash(bytes), fileBytesBase64 = Convert.ToBase64String(bytes),
                assemblyPath, assemblySha256 = Hash(File.ReadAllBytes(assemblyPath)),
                proofSeam = "Only BrandCompatibility.LocalDataRoot is a fixture stub returning the guarded owned empty leaf. AppLog and BugRedactor are unedited linked production files; real file append and actual Current identity are used.",
                productionStartupProved = false, native = true, positiveMarker = PositiveMarker
            };
            var json = JsonSerializer.Serialize(receipt);
            using var parsed = JsonDocument.Parse(json);
            RequireJsonScalars(parsed.RootElement);
            Console.WriteLine(json);
            Console.Out.Flush();
            ReaderAdverse.AttachIfRequested(frameRoot, nonce, "applog");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("ROO70_APPLOG_DISK_FAILED: " + error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }

    private static string FullDirectory(string value)
    {
        if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("A fully qualified directory is required.");
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    }

    private static void RequirePlainAncestors(string path)
    {
        for (DirectoryInfo? directory = new(path); directory is not null; directory = directory.Parent)
        {
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("All existing root and ancestor directories must be plain directories.");
        }
    }

    private static void RequireRoundTrip(string value)
    {
        RequireScalars(value);
        var decoded = JsonSerializer.Deserialize<string>(JsonSerializer.Serialize(value))
            ?? throw new InvalidOperationException("JSON string became null.");
        RequireScalars(decoded);
        if (decoded != value) throw new InvalidOperationException("JSON string round-trip changed content.");
    }

    private static void RequireScalars(string value)
    {
        for (var index = 0; index < value.Length; index++)
        {
            if (!char.IsSurrogate(value[index])) continue;
            if (!char.IsHighSurrogate(value[index]) || index + 1 >= value.Length || !char.IsLowSurrogate(value[++index]))
                throw new InvalidOperationException("Unpaired UTF16 surrogate.");
        }
    }

    private static void RequireJsonScalars(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String) RequireRoundTrip(value.GetString()!);
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var item in value.EnumerateArray()) RequireJsonScalars(item);
        else if (value.ValueKind == JsonValueKind.Object)
            foreach (var property in value.EnumerateObject()) { RequireRoundTrip(property.Name); RequireJsonScalars(property.Value); }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
