using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Roo70Fixture;

public static class ReaderAdverse
{
    private const string EnvironmentKey = "ROO_INDUSTRIES_REPORT_READER_HOLDER";
    private const string Protocol = "roo-industries-report-reader/v1";
    private const string ReadyMarker = "ROO_INDUSTRIES_REPORT_READER_HOLDER_READY";

    public static int Hold(string frameRoot, string leaf, string nonce, string kind)
    {
        var clock = Stopwatch.StartNew();
        var frame = Frame(frameRoot, nonce, kind);
        if (!string.Equals(Full(leaf), Path.Combine(frame, "reader-" + kind), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Holder leaf differs from the fixed original frame child.");
        Plain(leaf);
        if (Directory.EnumerateFileSystemEntries(leaf).Any()) throw new InvalidOperationException("Holder leaf must already exist and be empty.");
        using var process = Process.GetCurrentProcess();
        var image = Environment.ProcessPath ?? throw new InvalidOperationException("Holder process image is unavailable.");
        var stagedPath = Path.Combine(leaf, "ready-staged.json");
        var stagedHash = FixtureFiles.WriteNew(stagedPath, new
        {
            schemaVersion = 1, sourceCommit = BuildBinding.SourceCommit, frameRoot = frame, nonce, kind,
            pid = process.Id, creationTimeFileTimeUtc = Birth(process.SafeHandle), imageSha256 = Hash(FixtureFiles.ReadShared(image)), readyMarker = ReadyMarker
        });
        var releasePath = Path.Combine(leaf, "release-ready.json");
        while (!File.Exists(releasePath))
        {
            if (clock.Elapsed >= TimeSpan.FromSeconds(10)) throw new TimeoutException("Original owner did not release staged readiness within ten seconds.");
            Thread.Sleep(25);
        }
        if (clock.Elapsed >= TimeSpan.FromSeconds(10)) throw new TimeoutException("Original staged readiness deadline exceeded.");
        if ((File.GetAttributes(releasePath) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Owner release file is linked.");
        using var releaseDocument = JsonDocument.Parse(FixtureFiles.ReadShared(releasePath));
        var release = releaseDocument.RootElement;
        Shape(release, "protocol", "sourceCommit", "nonce", "kind", "pid", "stagedSha256");
        Match(release, "protocol", "roo-industries-report-ready-release/v1");
        Match(release, "sourceCommit", BuildBinding.SourceCommit); Match(release, "nonce", nonce); Match(release, "kind", kind);
        if (Integer(release, "pid") != process.Id || Hex(release, "stagedSha256") != stagedHash)
            throw new InvalidDataException("Owner release differs from original holder/staged bytes.");
        File.Move(stagedPath, Path.Combine(leaf, "ready.json"));
        while (clock.Elapsed < TimeSpan.FromSeconds(420)) Thread.Sleep(100);
        return 124;
    }

    public static void AttachIfRequested(string frameRoot, string nonce, string kind)
    {
        var encoded = Environment.GetEnvironmentVariable(EnvironmentKey);
        if (encoded is null) return;
        var frame = Frame(frameRoot, nonce, kind);
        using var contextDocument = JsonDocument.Parse(encoded);
        var context = contextDocument.RootElement;
        Shape(context, "protocol", "sourceCommit", "frameRoot", "nonce", "kind", "holderPid", "holderCreationTimeFileTimeUtc", "holderImageSha256", "readySha256");
        Match(context, "protocol", Protocol); Match(context, "sourceCommit", BuildBinding.SourceCommit);
        Match(context, "frameRoot", frame); Match(context, "nonce", nonce); Match(context, "kind", kind);
        var pid = Integer(context, "holderPid");
        var birth = Decimal(context, "holderCreationTimeFileTimeUtc");
        var imageHash = Hex(context, "holderImageSha256");
        var readyHash = Hex(context, "readySha256");
        var leaf = Path.Combine(frame, "reader-" + kind);
        Plain(leaf);
        var readyPath = Path.Combine(leaf, "ready.json");
        if ((File.GetAttributes(readyPath) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Holder ready file is linked.");
        byte[] readyBytes;
        using (var readyAccess = Native.CreateFile(readyPath, 0x80010000, 5, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero))
        {
            Check(!readyAccess.IsInvalid, "Open original ready access for shared read");
            readyBytes = FixtureFiles.ReadShared(readyPath);
        }
        if (Hash(readyBytes) != readyHash) throw new InvalidOperationException("Holder ready hash differs.");
        using var readyDocument = JsonDocument.Parse(readyBytes);
        var ready = readyDocument.RootElement;
        Shape(ready, "schemaVersion", "sourceCommit", "frameRoot", "nonce", "kind", "pid", "creationTimeFileTimeUtc", "imageSha256", "readyMarker");
        if (Integer(ready, "schemaVersion") != 1 || Integer(ready, "pid") != pid) throw new InvalidOperationException("Holder ready version/PID differs.");
        Match(ready, "sourceCommit", BuildBinding.SourceCommit); Match(ready, "frameRoot", frame);
        Match(ready, "nonce", nonce); Match(ready, "kind", kind); Match(ready, "readyMarker", ReadyMarker);
        Match(ready, "creationTimeFileTimeUtc", birth); Match(ready, "imageSha256", imageHash);
        using var target = Native.OpenProcess(0x1040, false, pid);
        Check(!target.IsInvalid, "Open original holder");
        if (Birth(target) != birth) throw new InvalidOperationException("Original holder birth differs.");
        Check(Native.GetExitCodeProcess(target, out var exit), "Read original holder state");
        if (exit != 259) throw new InvalidOperationException("Original holder is no longer live.");
        var imagePath = new StringBuilder(32768);
        var imageLength = imagePath.Capacity;
        Check(Native.QueryFullProcessImageName(target, 0, imagePath, ref imageLength), "Read original holder image");
        if (Hash(FixtureFiles.ReadShared(imagePath.ToString())) != imageHash) throw new InvalidOperationException("Original holder image hash differs.");
        var stdout = Writer(-11);
        var stderr = Writer(-12);
        Check(Native.DuplicateHandle(Native.GetCurrentProcess(), stdout, target, out var remoteStdout, 0, false, 2), "Duplicate stdout into original holder");
        Check(Native.DuplicateHandle(Native.GetCurrentProcess(), stderr, target, out var remoteStderr, 0, false, 2), "Duplicate stderr into original holder");
        using var parent = Process.GetCurrentProcess();
        var assembly = Assembly.GetExecutingAssembly().Location;
        FixtureFiles.WriteNew(Path.Combine(leaf, "attached.json"), new
        {
            protocol = Protocol, sourceCommit = BuildBinding.SourceCommit, frameRoot = frame, nonce, kind,
            holderPid = pid, holderCreationTimeFileTimeUtc = birth, holderImageSha256 = imageHash, readySha256 = readyHash,
            parentPid = parent.Id, parentCreationTimeFileTimeUtc = Birth(parent.SafeHandle), parentAssemblySha256 = Hash(FixtureFiles.ReadShared(assembly)),
            stdoutIsPipe = true, stderrIsPipe = true, stdoutDuplicated = true, stderrDuplicated = true, readyShareDeleteVerified = true,
            stdoutRemoteHandle = remoteStdout.ToInt64().ToString(CultureInfo.InvariantCulture), stderrRemoteHandle = remoteStderr.ToInt64().ToString(CultureInfo.InvariantCulture),
            utc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
        });
    }

    private static string Frame(string path, string nonce, string kind)
    {
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Windows reader fixture only.");
        if (kind is not ("applog" or "rendered") || !Regex.IsMatch(nonce, "\\A[a-f0-9]{32}\\z", RegexOptions.CultureInvariant))
            throw new ArgumentException("Invalid reader kind or original frame nonce.");
        var frame = Full(path);
        if (!frame.EndsWith("-" + nonce, StringComparison.Ordinal)) throw new ArgumentException("Reader frame suffix differs.");
        Plain(frame);
        return frame;
    }

    private static string Full(string path)
    {
        if (!Path.IsPathFullyQualified(path)) throw new ArgumentException("A full original frame path is required.");
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    }

    private static void Plain(string path)
    {
        for (DirectoryInfo? directory = new(path); directory is not null; directory = directory.Parent)
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Reader ancestors must exist and be plain.");
    }

    private static string Birth(SafeProcessHandle handle)
    {
        Check(Native.GetProcessTimes(handle, out var birth, out _, out _, out _), "Read retained process birth");
        return birth.ToString(CultureInfo.InvariantCulture);
    }

    private static IntPtr Writer(int id)
    {
        var handle = Native.GetStdHandle(id);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1) || Native.GetFileType(handle) != 3)
            throw new InvalidOperationException("Actual redirected writer must be a pipe.");
        return handle;
    }

    private static void Shape(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Reader identity must be an object.");
        var actual = value.EnumerateObject().Select(x => x.Name).ToArray();
        if (actual.Length != names.Length || actual.Distinct(StringComparer.Ordinal).Count() != names.Length || names.Any(x => !actual.Contains(x, StringComparer.Ordinal)))
            throw new InvalidDataException("Reader identity fields differ.");
    }

    private static string Text(JsonElement value, string name) => value.GetProperty(name).ValueKind == JsonValueKind.String
        ? value.GetProperty(name).GetString()! : throw new InvalidDataException("Reader field must be a string: " + name);
    private static void Match(JsonElement value, string name, string expected)
    {
        if (Text(value, name) != expected) throw new InvalidDataException("Reader field differs: " + name);
    }
    private static int Integer(JsonElement value, string name) => value.GetProperty(name).ValueKind == JsonValueKind.Number
        && value.GetProperty(name).TryGetInt32(out var number) && number > 0 ? number : throw new InvalidDataException("Reader field must be a positive integer: " + name);
    private static string Decimal(JsonElement value, string name)
    {
        var text = Text(value, name);
        if (!long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var birth) || birth <= 0) throw new InvalidDataException("Reader birth must be a decimal string.");
        return text;
    }
    private static string Hex(JsonElement value, string name)
    {
        var text = Text(value, name);
        if (!Regex.IsMatch(text, "\\A[a-f0-9]{64}\\z", RegexOptions.CultureInvariant)) throw new InvalidDataException("Reader hash must be lowercase SHA256.");
        return text;
    }
    private static string Hash(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    private static void Check(bool success, string operation)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    private static class Native
    {
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetProcessTimes(SafeProcessHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint code);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder name, ref int size);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int id);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern uint GetFileType(IntPtr handle);
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool DuplicateHandle(IntPtr source, IntPtr writer, SafeProcessHandle target, out IntPtr remote, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
    }
}
