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
        RemoveStaleMarkers(path);
        var operation = path + "." + Guid.NewGuid().ToString("N");
        var temporary = operation + ".tmp";
        var marker = operation + ".writing";
        try
        {
            using (new FileStream(marker, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, value, Json);
                output.Flush(flushToDisk: true);
            }
            if (File.Exists(path)) File.Replace(temporary, path, null, ignoreMetadataErrors: true);
            else File.Move(temporary, path);
        }
        finally { File.Delete(temporary); File.Delete(marker); }
    }

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    public static string HashFile(string path)
    {
        using var file = OpenShared(path);
        return Convert.ToHexString(SHA256.HashData(file));
    }

    private static FileStream OpenShared(string path)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete); }
            catch (FileNotFoundException) when (attempt < 40 && (attempt < 10 || File.Exists(path) || WriteInProgress(path))) { Thread.Sleep(5); }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020) && attempt < 40) { Thread.Sleep(25); }
        }
    }

    public static bool Absent(string path) => !File.Exists(path) && !Directory.Exists(path) && !WriteInProgress(path) && !File.Exists(path);

    private static void RemoveStaleMarkers(string path)
    {
        foreach (var file in Directory.EnumerateFiles(Path.GetDirectoryName(path)!, Path.GetFileName(path) + ".*"))
        {
            var name = Path.GetFileName(file);
            if (name.Length <= Path.GetFileName(path).Length + 1) continue;
            var suffix = name[(Path.GetFileName(path).Length + 1)..];
            if (suffix.Length != 32 + 4 && suffix.Length != 32 + 8 || !Guid.TryParseExact(suffix[..32], "N", out _) || suffix[32..] is not (".tmp" or ".writing")) continue;
            if (DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromMinutes(1)) continue;
            try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static bool WriteInProgress(string path)
    {
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full);
        return directory is not null && Directory.Exists(directory) && Directory.EnumerateFiles(directory, Path.GetFileName(full) + ".*")
            .Any(file => (file.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase) || file.EndsWith(".writing", StringComparison.OrdinalIgnoreCase)) && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromSeconds(5));
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
