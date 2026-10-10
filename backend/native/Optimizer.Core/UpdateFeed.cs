#nullable enable
using System.Collections.ObjectModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public sealed class SemanticVersion : IComparable<SemanticVersion>
{
    private static readonly Regex Pattern = new(@"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
    private readonly string[] _numbers;
    private readonly string[] _prerelease;
    public string Text { get; }

    private SemanticVersion(string text, string[] numbers, string[] prerelease) { Text = text; _numbers = numbers; _prerelease = prerelease; }

    public static bool TryParse(string? text, out SemanticVersion? version)
    {
        version = null;
        if (text is null) return false;
        Match match;
        try { match = Pattern.Match(text); }
        catch (RegexMatchTimeoutException) { return false; }
        if (!match.Success) return false;
        var prerelease = match.Groups[4].Success ? match.Groups[4].Value.Split('.') : [];
        if (prerelease.Any(part => Numeric(part) && part.Length > 1 && part[0] == '0')) return false;
        version = new(text, [match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value], prerelease);
        return true;
    }

    private static bool Numeric(string text) => text.All(char.IsAsciiDigit);
    private static int Number(string left, string right) => left.Length != right.Length ? left.Length.CompareTo(right.Length) : string.CompareOrdinal(left, right);

    public int CompareTo(SemanticVersion? other)
    {
        if (other is null) return 1;
        for (var index = 0; index < 3; index++)
        {
            var result = Number(_numbers[index], other._numbers[index]);
            if (result != 0) return result;
        }
        if (_prerelease.Length == 0 || other._prerelease.Length == 0)
            return (_prerelease.Length == 0).CompareTo(other._prerelease.Length == 0);
        for (var index = 0; index < Math.Min(_prerelease.Length, other._prerelease.Length); index++)
        {
            var left = _prerelease[index]; var right = other._prerelease[index];
            var a = Numeric(left); var b = Numeric(right);
            var result = a && b ? Number(left, right) : a != b ? (a ? -1 : 1) : string.CompareOrdinal(left, right);
            if (result != 0) return result;
        }
        return _prerelease.Length.CompareTo(other._prerelease.Length);
    }
}

public enum UpdateFeedKind { Refused, Current, Available }
public sealed record UpdateRelease(string Version, DateTimeOffset PublishedAtUtc, Uri InstallerUrl, long Size, string Sha256, string Notes);
public sealed record UpdateFeedResult(UpdateFeedKind Kind, string Reason, UpdateRelease? Release = null);
public sealed record UpdateFileResult(bool Verified, string Reason, long Bytes, string? Sha256 = null);

public static class UpdateFeed
{
    public const int MaximumBodyBytes = 64 * 1024;
    public const long MinimumInstallerBytes = 1 << 20;
    public const long MaximumInstallerBytes = 1L << 30;
    public static string? InstallDriveSpaceReason(string drive, long availableBytes) => availableBytes < (1L << 30)
        ? "Free at least 1 GB on drive " + drive.TrimEnd('\\', '/') + " and try again." : null;
    private static readonly Lazy<IReadOnlyDictionary<string, string>> Keys = new(() =>
    {
        using var stream = typeof(UpdateFeed).Assembly.GetManifestResourceStream("Optimizer.Core.UpdateKeys.json")
            ?? throw new InvalidDataException("This build's trusted update keys are missing.");
        return new ReadOnlyDictionary<string, string>(JsonSerializer.Deserialize<Dictionary<string, string>>(stream)
            ?? throw new InvalidDataException("This build's trusted update keys are empty."));
    });
    public static IReadOnlyDictionary<string, string> TrustedKeys => Keys.Value;

    public static UpdateFeedResult Verify(byte[] body, int httpStatus, Uri feedUrl, string currentVersion)
    {
        static UpdateFeedResult Refuse(string reason) => new(UpdateFeedKind.Refused, reason);
        try
        {
            if (httpStatus != 200) return Refuse("The update server returned HTTP " + httpStatus + " instead of 200.");
            if (body.Length > MaximumBodyBytes) return Refuse("The update feed is larger than 64 KiB.");
            if (!feedUrl.IsAbsoluteUri || feedUrl.Scheme != Uri.UriSchemeHttps) return Refuse("This build's update feed is not an HTTPS URL.");
            using var envelope = JsonDocument.Parse(body);
            Unique(envelope.RootElement);
            var root = envelope.RootElement;
            if (Integer(root, "schemaVersion") != 1) return Refuse("The update envelope schema version is not supported.");
            var keyId = Text(root, "keyId");
            if (!TrustedKeys.TryGetValue(keyId, out var key)) return Refuse("The update feed uses an unknown signing key.");
            byte[] payload, signature;
            try { payload = Convert.FromBase64String(Text(root, "payload")); signature = Convert.FromBase64String(Text(root, "signature")); }
            catch (FormatException) { return Refuse("The update payload or signature is not valid base64."); }
            using var verifier = ECDsa.Create();
            var publicKey = Convert.FromBase64String(key);
            verifier.ImportSubjectPublicKeyInfo(publicKey, out var consumed);
            if (consumed != publicKey.Length || !verifier.VerifyData(payload, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))
                return Refuse("The update signature is invalid. Couldn't verify this release.");
            using var document = JsonDocument.Parse(payload);
            Unique(document.RootElement);
            var data = document.RootElement;
            if (Integer(data, "schemaVersion") != 1) return Refuse("The update payload schema version is not supported.");
            if (Text(data, "product") != "RooIndustries.OptimizationSuite") return Refuse("This release is for another product.");
            if (Text(data, "channel") != "beta") return Refuse("This release is for another update channel.");
            var version = Text(data, "version");
            if (!SemanticVersion.TryParse(version, out var next)) return Refuse("The release version is not a valid SemVer version.");
            if (!SemanticVersion.TryParse(currentVersion, out var current)) return Refuse("This build's installed version is not a valid SemVer version.");
            var published = Text(data, "publishedAtUtc");
            if (!published.EndsWith('Z') || !DateTimeOffset.TryParse(published, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) || date.Offset != TimeSpan.Zero)
                return Refuse("The release publication time is not a UTC timestamp.");
            var installer = Object(data, "installer");
            if (!Uri.TryCreate(Text(installer, "url"), UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps ||
                !string.Equals(url.IdnHost, feedUrl.IdnHost, StringComparison.OrdinalIgnoreCase))
                return Refuse("The installer must use HTTPS on the same host as the update feed.");
            var size = Integer(installer, "size");
            if (size < MinimumInstallerBytes || size > MaximumInstallerBytes) return Refuse("The installer size must be between 1 MiB and 1 GiB.");
            var hash = Text(installer, "sha256");
            if (hash.Length != 64 || !hash.All(char.IsAsciiHexDigit)) return Refuse("The installer SHA-256 must contain exactly 64 hexadecimal characters.");
            var notes = data.TryGetProperty("notes", out var note) ? note.GetString() ?? "" : "";
            if (notes.Length > 2000) notes = notes[..(char.IsHighSurrogate(notes[1999]) ? 1999 : 2000)];
            var release = new UpdateRelease(version, date, url, size, hash.ToLowerInvariant(), notes);
            return next!.CompareTo(current) > 0 ? new(UpdateFeedKind.Available, "Version " + version + " is available", release)
                : new(UpdateFeedKind.Current, "You have the latest version", release);
        }
        catch (CryptographicException) { return Refuse("The update signature is invalid. Couldn't verify this release."); }
        catch (Exception error) when (error is JsonException or InvalidOperationException or InvalidDataException or FormatException or ArgumentException)
        { return Refuse("The update feed is invalid: " + error.Message); }
    }

    private static JsonElement Object(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Missing or invalid " + name + ".");
        return value;
    }
    private static string Text(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("Missing or invalid " + name + ".");
        return value.GetString()!;
    }
    private static long Integer(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(name, out var value) || !value.TryGetInt64(out var number))
            throw new InvalidDataException("Missing or invalid " + name + ".");
        return number;
    }
    private static void Unique(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate JSON property: " + property.Name + ".");
                Unique(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var child in element.EnumerateArray()) Unique(child);
    }

    public static async Task<UpdateFileResult> VerifyInstallerAsync(Stream input, UpdateRelease release, CancellationToken cancellation = default, Stream? output = null)
    {
        long total = 0;
        try
        {
            if (input.CanSeek) input.Position = 0;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[128 * 1024];
            while (total <= release.Size)
            {
                var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, release.Size + 1 - total)), cancellation).ConfigureAwait(false);
                if (read == 0) break;
                total += read;
                hash.AppendData(buffer, 0, read);
                if (output is not null) await output.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
            }
            var actual = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            if (total != release.Size) return new(false, "The installer size does not match the signed release.", total, actual);
            if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(actual), Convert.FromHexString(release.Sha256)))
                return new(false, "The installer SHA-256 does not match the signed release.", total, actual);
            return new(true, "The installer matches the signed release.", total, actual);
        }
        catch (OperationCanceledException) { return new(false, "Installer verification was canceled.", total); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or ArgumentException or NotSupportedException)
        { return new(false, "The installer could not be verified: " + error.Message, total); }
    }
}
