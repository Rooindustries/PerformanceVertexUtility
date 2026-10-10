#nullable enable
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record OperationOwner([property: JsonRequired] string Machine, [property: JsonRequired] string UserSid)
{
    public static OperationOwner Current()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new(Environment.MachineName, identity.User?.Value
            ?? throw new InvalidOperationException("The current Windows user SID is unavailable."));
    }

    public void Verify()
    {
        var current = Current();
        if (!string.Equals(Machine, current.Machine, StringComparison.OrdinalIgnoreCase) || UserSid != current.UserSid)
            throw new InvalidDataException("This operation belongs to another PC or Windows user.");
    }
}

public static class OperationFiles
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
    };

    public static T Read<T>(string path, string? expectedHash = null)
    {
        using var file = OpenShared(path);
        var bytes = new byte[checked((int)file.Length)];
        file.ReadExactly(bytes);
        if (expectedHash is not null && !string.Equals(Hash(bytes), expectedHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Reviewed operation bytes changed. Create a new preview.");
        return Deserialize<T>(bytes);
    }

    public static (T Value, string Hash) ReadHashed<T>(string path)
    {
        using var file = OpenShared(path);
        var bytes = new byte[checked((int)file.Length)];
        file.ReadExactly(bytes);
        return (Deserialize<T>(bytes), Hash(bytes));
    }

    public static T Deserialize<T>(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes);
        CheckProperties(document.RootElement);
        return document.RootElement.Deserialize<T>(Json) ?? throw new InvalidDataException("Operation data is empty.");
    }

    public static void Write<T>(string path, T value)
    {
        path = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var settled = false;
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, value, Json);
                output.Flush(flushToDisk: true);
            }
            try
            {
#if GOVERNOR_TEST_HOOKS
                if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_REPLACE_FAULT") == "1177" && File.Exists(path)) { File.Delete(path); throw new IOException("The replacement file could not be moved into place.", unchecked((int)0x80070499)); }
#endif
                if (File.Exists(path)) File.Replace(temporary, path, null, ignoreMetadataErrors: true);
                else File.Move(temporary, path);
            }
            catch (IOException error) when ((error.HResult & 0xffff) is 1176 or 1177)
            {
                if (File.Exists(path) || !File.Exists(temporary)) throw;
                File.Move(temporary, path);
            }
            settled = true;
        }
        finally { if (settled || File.Exists(path)) File.Delete(temporary); }
    }

    public static string? ExternalPathProblem(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "no path was given";
        if (path.Length > 1024) return "the path is longer than 1024 characters";
        if (path.IndexOfAny(Path.GetInvalidPathChars()) >= 0 || path.IndexOfAny(['*', '?']) >= 0) return "the path has characters Windows does not allow";
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\') return "it is not a full path on a local drive";
        if (path.IndexOf(':', 2) >= 0) return "it names an alternate data stream";
        var full = Path.GetFullPath(path);
        if (!string.Equals(full.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return "it is not written as a plain full path";
        if (!File.Exists(full) && !Directory.Exists(full)) return "it does not exist";
        try { if (new DriveInfo(full[..1]).DriveType is not (DriveType.Fixed or DriveType.Removable)) return "it is not on a local drive"; }
        catch (Exception error) when (error is ArgumentException or IOException) { return "its drive could not be checked"; }
        return null;
    }

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    public static string HashFile(string path) => HashFile(path, null);

    public static string HashFile(string path, Action? progress)
    {
        using var file = OpenShared(path);
        using var sha = SHA256.Create();
        var buffer = new byte[1 << 20];
        for (var chunks = 1; ; chunks++)
        {
            var read = file.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            sha.TransformBlock(buffer, 0, read, null, 0);
            if (chunks % 64 == 0) progress?.Invoke();
        }
        sha.TransformFinalBlock([], 0, 0);
        return Convert.ToHexString(sha.Hash!);
    }

    private static FileStream OpenShared(string path)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); }
            catch (FileNotFoundException) when (attempt < 40 && (attempt < 2 || WriteInProgress(path))) { Thread.Sleep(5); }
            catch (FileNotFoundException) when (attempt < 41 && RecoverOrphan(path)) { }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020) && attempt < 40) { Thread.Sleep(25); }
        }
    }

    private static bool RecoverOrphan(string path)
    {
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full);
        if (directory is null || !Directory.Exists(directory) || File.Exists(full)) return false;
        foreach (var candidate in Directory.EnumerateFiles(directory, Path.GetFileName(full) + ".*.tmp").Where(file => DateTime.UtcNow - File.GetLastWriteTimeUtc(file) >= TimeSpan.FromSeconds(5)).OrderByDescending(File.GetLastWriteTimeUtc))
        {
            try
            {
                byte[] bytes;
                using (var stream = new FileStream(candidate, FileMode.Open, FileAccess.Read, FileShare.None)) { bytes = new byte[stream.Length]; stream.ReadExactly(bytes); }
                using var document = JsonDocument.Parse(bytes);
                File.Move(candidate, full);
                return true;
            }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { }
        }
        return false;
    }

    private static bool WriteInProgress(string path)
    {
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full);
        return directory is not null && Directory.Exists(directory) && Directory.EnumerateFiles(directory, Path.GetFileName(full) + ".*.tmp").Any(file => DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromSeconds(5));
    }

    private static void CheckProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate JSON property: " + property.Name);
                CheckProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var child in element.EnumerateArray()) CheckProperties(child);
    }

    public static FileStream Lock(string path)
    {
        var full = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        return NativeFiles.OpenLock(full + ".lock");
    }
}
