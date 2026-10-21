using System.Security.Cryptography;
using System.Text.Json;

namespace Roo70Fixture;

internal static class FixtureFiles
{
    internal static byte[] ReadShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    internal static string WriteNew(string path, object value)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Write(bytes);
            stream.Flush(true);
        }
        File.Move(temporary, path);
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }
}
