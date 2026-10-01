#nullable enable
using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace RooIndustries.Optimizer;

internal sealed record ScewinDownload(string Url, string Hash, long Length);

public sealed class ScewinSetup
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(30) };
    private static readonly ScewinDownload Extractor = new("https://constexpr.org/innoextract/files/innoextract-1.9-windows.zip",
        "6989342C9B026A00A72A38F23B62A8E6A22CC5DE69805CF47D68AC2FEC993065", 520705);
    private static readonly ScewinDownload Package = new("https://download.msi.com/uti_exe/desktop/MSI-Center.zip",
        "FBFA35A0CD8B4A71F6F0CAC5090C50A97D082E1F5F93D5B95493526A34032E96", 584849764);
    private readonly HttpClient _client;
    private readonly ScewinDownload _extractor;
    private readonly ScewinDownload _package;
    private readonly Func<string, string, string, string, CancellationToken, Task> _extract;

    public ScewinSetup() : this(Client, Extractor, Package, ExtractInstallerAsync) { }
    internal ScewinSetup(HttpClient client, ScewinDownload extractor, ScewinDownload package,
        Func<string, string, string, string, CancellationToken, Task> extract)
    {
        _client = client; _extractor = extractor; _package = package; _extract = extract;
    }

    public async Task<string> InstallAsync(string packagesRoot, IProgress<string>? progress = null, CancellationToken cancellation = default)
    {
        if (!OperatingSystem.IsWindows() || RuntimeInformation.OSArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("Automatic SCEWIN setup requires Windows on an x64 PC.");
        packagesRoot = Path.GetFullPath(packagesRoot);
        using var operation = OperationFiles.Lock(Path.Combine(packagesRoot, "setup"));
        var staging = Path.Combine(packagesRoot, ".setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            var extractorZip = Path.Combine(staging, "extractor.zip");
            await DownloadAsync(_extractor, extractorZip, "Preparing SCEWIN setup", progress, cancellation).ConfigureAwait(false);
            var extractor = Path.Combine(staging, "innoextract.exe");
            ExtractZip(extractorZip, e => e.FullName == "innoextract.exe", extractor);
            var source = Path.Combine(staging, "source.zip");
            await DownloadAsync(_package, source, "Downloading SCEWIN package", progress, cancellation).ConfigureAwait(false);
            progress?.Report("Extracting SCEWIN and its matching driver…");
            var installer = Path.Combine(staging, "center.exe");
            ExtractZip(source, e => e.Name.StartsWith("MSI Center_", StringComparison.Ordinal) && e.Name.EndsWith(".exe", StringComparison.Ordinal), installer);
            var center = Path.Combine(staging, "center");
            await _extract(extractor, installer, center, "app", cancellation).ConfigureAwait(false);
            var bundle = SingleFile(Path.Combine(center, "app"), "*.appxbundle");
            var appx = Path.Combine(staging, "center.appx");
            ExtractZip(bundle, e => e.Name.StartsWith("MSI%20Center_", StringComparison.Ordinal) && e.Name.EndsWith("_x64.appx", StringComparison.Ordinal), appx);
            var sdk = Path.Combine(staging, "sdk.exe");
            ExtractZip(appx, e => e.FullName == "DCv2/Package/MSI%20Center%20SDK.exe", sdk);
            var sdkDirectory = Path.Combine(staging, "sdk");
            await _extract(extractor, sdk, sdkDirectory, "tmp/PrePackage/Engine Lib_3.0.0.74.exe", cancellation).ConfigureAwait(false);
            var engine = SingleFile(Path.Combine(sdkDirectory, "tmp", "PrePackage"), "Engine Lib_*.exe");
            var engineDirectory = Path.Combine(staging, "engine");
            await _extract(extractor, engine, engineDirectory, "app/Lib/SCEWIN", cancellation).ConfigureAwait(false);
            var scewinRoot = Path.Combine(engineDirectory, "app", "Lib", "SCEWIN");
            var versions = Directory.GetDirectories(scewinRoot);
            if (versions.Length != 1) throw new InvalidDataException("The downloaded SCEWIN package has an unexpected layout. Update Roo Industries and try again.");
            cancellation.ThrowIfCancellationRequested();
            progress?.Report("Verifying SCEWIN and driver signatures…");
            var package = await Task.Run(() => ScewinProvider.Inspect(versions[0]), cancellation).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            var destination = ScewinProvider.SetUp(versions[0], package, packagesRoot);
            try
            {
                OperationFiles.Write(Path.Combine(destination, "source.json"), new { url = _package.Url, sha256 = _package.Hash, acquiredAt = DateTimeOffset.UtcNow });
                return destination;
            }
            catch { Directory.Delete(destination, true); throw; }
        }
        finally { Directory.Delete(staging, true); }
    }

    internal async Task DownloadAsync(ScewinDownload source, string destination, string label, IProgress<string>? progress, CancellationToken cancellation)
    {
        if (!Uri.TryCreate(source.Url, UriKind.Absolute, out var uri) || uri.Scheme != "https")
            throw new InvalidDataException("SCEWIN setup requires an HTTPS download source.");
        progress?.Report(label + "…");
        using var response = await _client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        if (response.RequestMessage?.RequestUri?.Scheme is { } scheme && scheme != "https")
            throw new InvalidDataException("The SCEWIN download redirected to an insecure connection.");
        if (response.Content.Headers.ContentLength is { } length && length != source.Length)
            throw new InvalidDataException("The SCEWIN download changed. Update Roo Industries to use the new package.");
        try
        {
            await using var input = await response.Content.ReadAsStreamAsync(cancellation);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, true);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[131072];
            long received = 0;
            var reported = Stopwatch.StartNew();
            int read;
            while ((read = await input.ReadAsync(buffer, cancellation)) != 0)
            {
                received += read;
                if (received > source.Length) throw new InvalidDataException("The SCEWIN download exceeded its verified size.");
                hash.AppendData(buffer, 0, read);
                await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
                if (reported.ElapsedMilliseconds >= 500)
                {
                    var size = source.Length < 1048576 ? "" : $" ({received / 1048576} / {source.Length / 1048576} MB)";
                    progress?.Report($"{label} · {received * 100 / source.Length}%{size}");
                    reported.Restart();
                }
            }
            if (received != source.Length || !Convert.ToHexString(hash.GetHashAndReset()).Equals(source.Hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The SCEWIN download is incomplete or differs from the verified package. No helper was installed. Try again.");
        }
        catch { File.Delete(destination); throw; }
    }

    internal static void ExtractZip(string archive, Func<ZipArchiveEntry, bool> select, string destination)
    {
        using var zip = ZipFile.OpenRead(archive);
        var entries = zip.Entries.Where(select).ToArray();
        if (entries.Length != 1 || entries[0].Length <= 0 || entries[0].Length > 1073741824)
            throw new InvalidDataException("The SCEWIN archive has missing, duplicate or oversized components. Update Roo Industries and try again.");
        entries[0].ExtractToFile(destination);
    }

    private static string SingleFile(string directory, string pattern)
    {
        var files = Directory.GetFiles(directory, pattern);
        return files.Length == 1 ? files[0] : throw new InvalidDataException("The SCEWIN archive has an unexpected layout. Update Roo Industries and try again.");
    }

    private static async Task ExtractInstallerAsync(string extractor, string installer, string directory, string include, CancellationToken cancellation)
    {
        var start = new ProcessStartInfo(extractor) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(extractor)! };
        RuntimeEnvironment.Apply(start);
        foreach (var argument in new[] { "--silent", "--extract", "--test", "--include", include.Replace('/', Path.DirectorySeparatorChar), "--output-dir", directory, installer }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The package extractor did not start.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromMinutes(5));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            cancellation.ThrowIfCancellationRequested();
            throw new TimeoutException("SCEWIN package extraction timed out. Try loading settings again.");
        }
        var stdout = await output; var stderr = await error;
        if (process.ExitCode != 0) throw new InvalidOperationException("SCEWIN package extraction exited " + process.ExitCode + ": " + stdout.Trim() + " " + stderr.Trim());
    }
}
