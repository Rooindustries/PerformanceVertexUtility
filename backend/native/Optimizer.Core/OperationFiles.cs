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
        using var guard = ReplaceLock(path);
        RecoverOrphan(path);
        RemoveLeftovers(path);
        var operation = path + "." + Guid.NewGuid().ToString("N");
        var temporary = operation + ".tmp";
        var backup = operation + ".bak";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, value, Json);
                output.Flush(flushToDisk: true);
            }
            if (File.Exists(path))
            {
                try
                {
                    SimulateReplaceFailure?.Invoke(path, backup);
                    File.Replace(temporary, path, backup, ignoreMetadataErrors: true);
                }
                catch when (!File.Exists(path) && File.Exists(backup))
                {
                    File.Move(backup, path);
                    throw;
                }
                TryDelete(backup);
            }
            else File.Move(temporary, path);
        }
        finally { TryDelete(temporary); }
    }

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    public static string HashFile(string path)
    {
        using var file = OpenShared(path);
        return Convert.ToHexString(SHA256.HashData(file));
    }

    internal static Action<string, string>? SimulateReplaceFailure;

    public static bool Exists(string path)
    {
        var full = Path.GetFullPath(path);
        if (File.Exists(full)) return true;
        if (!Directory.Exists(Path.GetDirectoryName(full))) return false;
        using var guard = ReplaceLock(full);
        RecoverOrphan(full);
        return File.Exists(full);
    }

    public static bool Absent(string path) => !Directory.Exists(path) && !Exists(path);

    public static void Delete(string path)
    {
        var full = Path.GetFullPath(path);
        if (!Directory.Exists(Path.GetDirectoryName(full))) return;
        using var guard = ReplaceLock(full);
        File.Delete(full);
        foreach (var leftover in Leftovers(full)) File.Delete(leftover);
    }

    private static FileStream OpenShared(string path)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete); }
            catch (FileNotFoundException) when (attempt < 40 && Exists(path)) { }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020) && attempt < 40) { Thread.Sleep(25); }
        }
    }

    private static FileStream? ReplaceLock(string path)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            try { return new FileStream(path + ".replace.lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose); }
            catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33 && clock.Elapsed < TimeSpan.FromSeconds(30)) { Thread.Sleep(2); }
            catch (UnauthorizedAccessException) { return null; }
        }
    }

    private static void RecoverOrphan(string path)
    {
        if (File.Exists(path)) return;
        var backups = Leftovers(path).Where(file => file.EndsWith(".bak", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (backups.Length == 1) File.Move(backups[0], path);
        else if (backups.Length > 1) throw new InvalidDataException("Several interrupted saves left backups of " + Path.GetFileName(path) + ". Review them before continuing.");
    }

    private static void RemoveLeftovers(string path)
    {
        if (!File.Exists(path)) return;
        foreach (var leftover in Leftovers(path)) TryDelete(leftover);
    }

    private static IEnumerable<string> Leftovers(string path)
    {
        var name = Path.GetFileName(path);
        return Directory.EnumerateFiles(Path.GetDirectoryName(path)!, name + ".*").Where(file =>
        {
            var candidate = Path.GetFileName(file);
            if (candidate.Length < name.Length + 36) return false;
            var suffix = candidate[(name.Length + 1)..];
            return Guid.TryParseExact(suffix[..32], "N", out _) && suffix[32..] is ".tmp" or ".bak" or ".writing";
        });
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
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
        return new FileStream(full + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.DeleteOnClose);
    }
}
